/*
 * 手机自绘书签页 v3.1（2026-10-10）：分层书签树 + 文件夹管理。
 *
 * 数据流：getBookmarks（parentId 省略 = 三个根文件夹；带 = 该文件夹子节点）
 * -> bookmarkList 事件（AuraShell 转存 'auraPanelBookmarkList'）——点文件夹
 * 进入（navStack 记路径）、返回钮逐级上退；搜索走 searchBookmarks（引擎
 * 按标题/网址匹配，命中带 path）。写入走版本 1-3 稳定命令：addBookmark /
 * createBookmarkFolder / updateBookmark（改名/编辑）/ removeBookmark（文件夹
 * 级联删）。引擎回 bookmarkCreated / bookmarksChanged / bookmarkOpResult
 * （转存 'auraPanelEvent'）后重拉当前层。
 * ⚠️ 不要用 getBookmarksForSync/applyBookmarks（版本 4）：当前引擎 HAR 的
 * bookmarkApiVersion 还没实现它们，命令会被吞、页面永远"加载中"（实测）。
 * 标题栏 + = 新建文件夹；⋯ 菜单 = 手动添加书签（预填当前页）/导入/导出。
 */
import { common } from '@kit.AbilityKit';
import { display, promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { BookmarkNode, BrowserCommandPayload } from 'engine';
import { displayUrl, pickAndStageImportFile, saveExportedFile, deleteStagedFile } from './PanelBridge';
import { AuraSectionLabel } from './LumieKit';
import { GlassPage, glassHeaderInsetVp, glassTopSafeVp } from './GlassPage';
import { MoreMenuDialog, MoreMenuItemSpec } from './MoreMenuDialog';

interface BookmarkIoPayload {
  kind?: string;
  requestId?: number;
  ok?: boolean;
  bookmarkCount?: number;
  folderCount?: number;
  skippedCount?: number;
  error?: string;
}

interface BookmarkListPayload {
  requestId?: number;
  parentId?: string;
  nodes?: BookmarkNode[];
}

type FormMode = '' | 'addBookmark' | 'editBookmark' | 'addFolder' | 'renameFolder';

const MAX_LOAD_RETRIES: number = 3;
const LOAD_RETRY_MS: number = 1500;

@Component
export struct BookmarksPanel {
  @Prop currentUrl: string = '';
  @Prop currentTitle: string = '';
  // 当前层节点（getBookmarks 回包；根级 = 三个根文件夹）。
  @StorageLink('auraPanelBookmarkList') @Watch('onListChanged') listJson: string = '';
  // 最近添加（根级下方平铺；getRecentBookmarks 通道）。
  @StorageLink('auraPanelBookmarks') @Watch('onRecentChanged') bookmarksJson: string = '';
  @StorageLink('auraPanelBookmarkIo') @Watch('onIoPayload') bookmarkIoJson: string = '';
  @StorageLink('auraPanelEvent') @Watch('onPanelEvent') panelEventJson: string = '';
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  onBack: () => void = (): void => {};
  onClose: () => void = (): void => {};

  @State private currentNodes: BookmarkNode[] = [];
  @State private recentNodes: BookmarkNode[] = [];
  // 当前所在文件夹 id（'' = 根级）。
  @State private currentFolderId: string = '';
  // 移动设备根（根级回包里 rootType==='mobile'；根级新建的默认落点）。
  @State private mobileFolderId: string = '';
  @State private loading: boolean = true;
  private navStack: string[] = [];
  // 回包匹配：只采用最新一次请求的回包（layer = 目录层，search = 搜索）。
  private pendingKind: 'layer' | 'search' = 'layer';
  private pendingSeq: number = 0;
  private requestSeq: number = 0;
  private retryTimer: number = -1;
  private retryCount: number = 0;
  private pendingImportPath: string = '';
  private pendingExportPath: string = '';
  private pendingExportRequestId: number = 0;

  // 表单弹窗（添加/编辑书签、新建/重命名文件夹共用）。
  @State private dialogMode: FormMode = '';
  @State private formTitle: string = '';
  @State private formUrl: string = '';
  private editUuid: string = '';

  // 搜索（searchBookmarks 命令，命中带 path）。
  @State private searchText: string = '';
  @State private searchResults: BookmarkNode[] = [];

  // 行菜单（自绘卡，首页同款）：目标节点 + 落点。
  @State private rowMenuId: string = '';
  @State private rowMenuIsFolder: boolean = false;
  @State private rowMenuX: number = 0;
  @State private rowMenuY: number = 0;
  private menuPressX: number = 0;
  private menuPressY: number = 0;
  private windowW: number = 360;
  private windowH: number = 780;

  private listScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const dsp = display.getDefaultDisplaySync();
    this.windowW = dsp.width / dsp.densityPixels;
    this.windowH = dsp.height / dsp.densityPixels;
    this.onListChanged();
    this.onRecentChanged();
    this.loadLayer('');
  }

  aboutToDisappear(): void {
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    this.cleanupPendingImport();
  }

  // -- 数据层 -----------------------------------------------------------------

  /** 拉取某层：parentId 空 = 三个根文件夹，否则该文件夹的直接子节点。 */
  private loadLayer(parentId: string): void {
    this.loading = true;
    this.retryCount = 0;
    this.pendingKind = 'layer';
    this.requestSeq += 1;
    this.pendingSeq = this.requestSeq;
    if (parentId.length === 0) {
      this.onCommand({ command: 'getBookmarks', requestId: this.requestSeq });
    } else {
      this.onCommand({ command: 'getBookmarks', requestId: this.requestSeq, parentId: parentId });
    }
    this.scheduleRetry();
  }

  private scheduleRetry(): void {
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    if (this.retryCount >= MAX_LOAD_RETRIES) {
      return;
    }
    this.retryCount += 1;
    const seq = this.pendingSeq;
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1;
      if (this.loading && this.pendingSeq === seq) {
        // 引擎没回：重发同一层。
        if (this.pendingKind === 'layer') {
          const parentId = this.currentFolderId;
          this.requestSeq += 1;
          this.pendingSeq = this.requestSeq;
          if (parentId.length === 0) {
            this.onCommand({ command: 'getBookmarks', requestId: this.requestSeq });
          } else {
            this.onCommand({ command: 'getBookmarks', requestId: this.requestSeq, parentId: parentId });
          }
          this.scheduleRetry();
        }
      }
    }, LOAD_RETRY_MS);
  }

  private onListChanged(): void {
    if (this.listJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.listJson) as BookmarkListPayload;
      if ((payload.requestId ?? -1) !== this.pendingSeq) {
        return;
      }
      const nodes = payload.nodes ?? [];
      if (this.pendingKind === 'layer') {
        this.currentNodes = nodes;
        if (this.currentFolderId.length === 0) {
          for (const node of nodes) {
            if (node.rootType === 'mobile') {
              this.mobileFolderId = node.id;
              break;
            }
          }
        }
      } else {
        this.searchResults = nodes;
      }
      this.loading = false;
      if (this.retryTimer !== -1) {
        clearTimeout(this.retryTimer);
        this.retryTimer = -1;
      }
    } catch (error) {
      this.loading = false;
    }
  }

  private onRecentChanged(): void {
    if (this.bookmarksJson.length === 0) {
      return;
    }
    try {
      this.recentNodes = JSON.parse(this.bookmarksJson) as BookmarkNode[];
    } catch (error) {
    }
  }

  private onPanelEvent(): void {
    // bookmarkCreated / bookmarkOpResult / bookmarksChanged: 重拉当前层。
    if (this.searchText.trim().length > 0) {
      this.runSearch(this.searchText);
      return;
    }
    this.loadLayer(this.currentFolderId);
  }

  /** 搜索走引擎（searchBookmarks，按标题/网址匹配，命中带 path）。 */
  private runSearch(query: string): void {
    const q = query.trim();
    if (q.length === 0) {
      this.searchResults = [];
      return;
    }
    this.pendingKind = 'search';
    this.requestSeq += 1;
    this.pendingSeq = this.requestSeq;
    this.onCommand({ command: 'searchBookmarks', requestId: this.requestSeq, query: q, maxCount: 50 });
  }

  /** 返回钮：子文件夹先逐级上退，到根再关面板。 */
  private handleBack(): void {
    if (this.navStack.length > 0) {
      const parent = this.navStack.pop();
      this.currentFolderId = parent !== undefined ? parent : '';
      this.loadLayer(this.currentFolderId);
      return;
    }
    this.onBack();
  }

  private openNode(node: BookmarkNode): void {
    if (node.type === 'folder') {
      this.navStack.push(this.currentFolderId);
      this.currentFolderId = node.id;
      this.loadLayer(node.id);
      return;
    }
    if (node.url === undefined || node.url.length === 0) {
      return;
    }
    this.onCommand({ command: 'navigate', url: node.url });
    this.onClose();
  }

  /** 新建书签/文件夹的父层：根级落到移动设备根，子层落到当前文件夹。 */
  private targetParentId(): string {
    if (this.currentFolderId.length > 0) {
      return this.currentFolderId;
    }
    return this.mobileFolderId;
  }

  // -- 行菜单 -----------------------------------------------------------------

  private openRowMenu(node: BookmarkNode): void {
    const cardW = 190;
    const cardH = node.type === 'folder' ? 108 : 204;
    this.rowMenuX = Math.min(Math.max(this.menuPressX - cardW / 2, 12),
      Math.max(12, this.windowW - cardW - 12));
    this.rowMenuY = Math.min(this.menuPressY + 8, Math.max(12, this.windowH - cardH - 96));
    this.rowMenuIsFolder = node.type === 'folder';
    this.rowMenuId = node.id;
  }

  private copyLink(url: string): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
    pasteboard.getSystemPasteboard().setData(data).catch((): void => {
    });
    this.getUIContext().getPromptAction().showToast({ message: '链接已复制', duration: 1500 });
  }

  private removeWithConfirm(node: BookmarkNode): void {
    this.getUIContext().getPromptAction().showDialog({
      title: node.type === 'folder' ? '删除文件夹' : '删除书签',
      message: node.title.length > 0 ? node.title : (node.url ?? ''),
      buttons: [
        { text: '取消', color: '#5F6368' },
        { text: '删除', color: '#E24B4A' }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (result.index !== 1) {
        return;
      }
      this.requestSeq += 1;
      this.onCommand({ command: 'removeBookmark', id: node.id, requestId: this.requestSeq });
      if (node.type === 'folder' && this.currentFolderId === node.id) {
        // 删除的是正浏览的文件夹：立即退回上一层。
        const parent = this.navStack.length > 0 ? this.navStack.pop() : undefined;
        this.currentFolderId = parent !== undefined ? parent : '';
        this.loadLayer(this.currentFolderId);
      }
    }).catch((error: Error): void => {
    });
  }

  // -- 表单弹窗（添加/编辑书签、新建/重命名文件夹） -----------------------------

  private openForm(mode: FormMode, node?: BookmarkNode): void {
    this.editUuid = node !== undefined ? node.id : '';
    this.formTitle = node !== undefined ? node.title : '';
    this.formUrl = node !== undefined && node.url !== undefined ? node.url : '';
    if (mode === 'addBookmark') {
      // 手动添加：预填当前页（承接原「收藏当前网页」，+ 撤掉后这里是唯一入口）。
      if (this.formTitle.length === 0 && this.formUrl.length === 0) {
        this.formUrl = this.currentUrl;
        this.formTitle = this.currentTitle;
      }
    }
    this.dialogMode = mode;
  }

  private cancelForm(): void {
    this.dialogMode = '';
    this.editUuid = '';
    this.formTitle = '';
    this.formUrl = '';
  }

  private confirmForm(): void {
    const title = this.formTitle.trim();
    if (this.dialogMode === 'addBookmark') {
      const url = this.formUrl.trim();
      if (url.length === 0) {
        return;
      }
      this.requestSeq += 1;
      const parent = this.targetParentId();
      if (parent.length === 0) {
        this.onCommand({ command: 'addBookmark', url: url, title: title, requestId: this.requestSeq });
      } else {
        this.onCommand({
          command: 'addBookmark',
          url: url,
          title: title,
          parentId: parent,
          requestId: this.requestSeq
        });
      }
    } else if (this.dialogMode === 'addFolder') {
      const name = title.length > 0 ? title : '新建文件夹';
      this.requestSeq += 1;
      this.onCommand({
        command: 'createBookmarkFolder',
        requestId: this.requestSeq,
        parentId: this.targetParentId(),
        title: name
      });
    } else if (this.dialogMode === 'editBookmark' || this.dialogMode === 'renameFolder') {
      if (this.editUuid.length === 0) {
        this.cancelForm();
        return;
      }
      this.requestSeq += 1;
      this.onCommand({
        command: 'updateBookmark',
        id: this.editUuid,
        title: title.length > 0 ? title : undefined,
        url: this.dialogMode === 'editBookmark' ? this.formUrl.trim() : undefined,
        requestId: this.requestSeq
      });
    }
    this.cancelForm();
  }

  private formHeadline(): string {
    if (this.dialogMode === 'addBookmark') {
      return '添加书签';
    }
    if (this.dialogMode === 'editBookmark') {
      return '编辑书签';
    }
    if (this.dialogMode === 'addFolder') {
      return '新建文件夹';
    }
    return '重命名文件夹';
  }

  // -- 导入 / 导出（对齐 Lumie v2，原样保留） ----------------------------------

  private cleanupPendingImport(): void {
    if (this.pendingImportPath.length > 0) {
      deleteStagedFile(this.pendingImportPath);
      this.pendingImportPath = '';
    }
  }

  private onIoPayload(): void {
    if (this.bookmarkIoJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.bookmarkIoJson) as BookmarkIoPayload;
      const kind = String(payload.kind ?? '');
      if (kind === 'import') {
        this.cleanupPendingImport();
        if (payload.ok === true) {
          const count = Number(payload.bookmarkCount ?? 0);
          const skipped = Number(payload.skippedCount ?? 0);
          let message = `已导入 ${count} 个书签`;
          if (skipped > 0) {
            message = `${message}（跳过 ${skipped} 条）`;
          }
          AlertDialog.show({
            title: '导入完成',
            message: message,
            confirm: {
              value: '好的',
              action: (): void => {
              }
            }
          });
          this.loadLayer(this.currentFolderId);
        } else {
          AlertDialog.show({
            title: '导入没有成功',
            message: this.importFailureText(String(payload.error ?? '')),
            confirm: {
              value: '好的',
              action: (): void => {
              }
            }
          });
        }
        return;
      }
      if (kind === 'export') {
        if ((payload.requestId ?? 0) !== this.pendingExportRequestId ||
          this.pendingExportPath.length === 0) {
          return;
        }
        const stagedPath = this.pendingExportPath;
        this.pendingExportPath = '';
        if (payload.ok === true) {
          this.handExportToSaveDialog(stagedPath, Number(payload.bookmarkCount ?? 0));
        } else {
          deleteStagedFile(stagedPath);
          AlertDialog.show({
            title: '导出没有成功',
            message: '没能写出书签文件，请再试一次。',
            confirm: {
              value: '好的',
              action: (): void => {
              }
            }
          });
        }
        return;
      }
    } catch (error) {
    }
  }

  private importFailureText(error: string): string {
    if (error === 'tooLarge') {
      return '文件太大（超过 20 MB），没有导入。';
    }
    if (error === 'notBookmarkFile') {
      return '这个文件里没有找到书签数据，没有导入。';
    }
    if (error === 'fileNotFound') {
      return '读不了这个文件，请再试一次。';
    }
    return '没能导入书签，请再试一次。';
  }

  private async handExportToSaveDialog(stagedPath: string, count: number): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      deleteStagedFile(stagedPath);
      return;
    }
    const saved = await saveExportedFile(context, stagedPath, 'Aura 书签.html');
    if (saved) {
      AlertDialog.show({
        title: '导出完成',
        message: `已导出 ${count} 个书签`,
        confirm: {
          value: '好的',
          action: (): void => {
          }
        }
      });
    }
  }

  private async startImport(): Promise<void> {
    this.cleanupPendingImport();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    const path = await pickAndStageImportFile(context, ['书签文件|.html']);
    if (path.length === 0) {
      return;
    }
    this.pendingImportPath = path;
    this.requestSeq += 1;
    this.onCommand({
      command: 'importBookmarks',
      requestId: this.requestSeq,
      path: path,
      title: '导入的书签'
    });
  }

  private startExport(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    this.requestSeq += 1;
    this.pendingExportRequestId = this.requestSeq;
    this.pendingExportPath = `${context.filesDir}/aura-export-bookmarks.html`;
    this.onCommand({
      command: 'exportBookmarks',
      requestId: this.pendingExportRequestId,
      path: this.pendingExportPath
    });
  }

  // -- ⋯ 子菜单（CustomDialog）------------------------------------------------

  private showMoreSheet(): void {
    this.moreMenuDialog.open();
  }

  private moreMenuDialog: CustomDialogController = new CustomDialogController({
    builder: MoreMenuDialog({
      items: [
        {
          icon: $r('app.media.aura_plus'),
          label: '手动添加书签',
          action: (): void => {
            this.openForm('addBookmark');
          }
        },
        {
          icon: $r('app.media.aura_import'),
          label: '导入书签',
          action: (): void => {
            this.startImport();
          }
        },
        {
          icon: $r('app.media.aura_export'),
          label: '导出书签',
          action: (): void => {
            this.startExport();
          }
        }
      ] as MoreMenuItemSpec[]
    }),
    autoCancel: true,
    customStyle: true,
    maskColor: Color.Transparent,
    alignment: DialogAlignment.TopEnd,
    offset: { dx: -12, dy: glassTopSafeVp() + 62 }
  });

  // -- UI ---------------------------------------------------------------------

  @Builder
  private FolderRow(node: BookmarkNode) {
    Column() {
      Row({ space: 12 }) {
        Column() {
          Image($r('app.media.aura_folder'))
            .width(20)
            .height(20)
            .fillColor($r('app.color.text_primary'))
        }
        .width(38)
        .height(38)
        .borderRadius(10)
        .backgroundColor($r('app.color.surface_secondary'))
        .justifyContent(FlexAlign.Center)

        Column({ space: 2 }) {
          Text(node.title.length > 0 ? node.title : '未命名文件夹')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text(`${node.childCount ?? 0} 项`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button({ type: ButtonType.Circle }) {
          Image($r('app.media.aura_more'))
            .width(18)
            .height(18)
            .fillColor($r('app.color.icon_secondary'))
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .accessibilityText('文件夹操作')
        .onClick(() => {
          this.openRowMenu(node);
        })

        Image($r('app.media.aura_chevron'))
          .width(16)
          .height(16)
          .fillColor($r('app.color.icon_secondary'))
      }
      .width('100%')
      .constraintSize({ minHeight: 60 })
      .padding({ left: 16, right: 12, top: 8, bottom: 8 })
      .onClick(() => {
        this.openNode(node);
      })
    }
    .width('100%')
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down && event.touches.length > 0) {
        this.menuPressX = event.touches[0].windowX;
        this.menuPressY = event.touches[0].windowY;
      }
    })
  }

  @Builder
  private BookmarkRow(node: BookmarkNode, index: number, total: number) {
    Column() {
      Row({ space: 12 }) {
        Image($r('app.media.aura_bookmark'))
          .width(22)
          .height(22)
          .fillColor($r('app.color.icon_primary'))

        Column({ space: 2 }) {
          Text(node.title.length > 0 ? node.title : displayUrl(node.url ?? ''))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text(displayUrl(node.url ?? ''))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button({ type: ButtonType.Circle }) {
          Image($r('app.media.aura_more'))
            .width(18)
            .height(18)
            .fillColor($r('app.color.icon_secondary'))
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .accessibilityText('书签操作')
        .onClick(() => {
          this.openRowMenu(node);
        })
      }
      .width('100%')
      .constraintSize({ minHeight: 60 })
      .padding({ left: 16, right: 6, top: 8, bottom: 8 })
      .onClick(() => {
        this.openNode(node);
      })

      if (index < total - 1) {
        Divider()
          .color($r('app.color.divider'))
          .margin({ left: 50 })
      }
    }
    .width('100%')
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down && event.touches.length > 0) {
        this.menuPressX = event.touches[0].windowX;
        this.menuPressY = event.touches[0].windowY;
      }
    })
  }

  @Builder
  private RowMenuRow(icon: Resource, label: string, action: () => void, iconAngle: number) {
    Row({ space: 14 }) {
      Image(icon)
        .width(21)
        .height(21)
        .fillColor($r('app.color.icon_primary'))
        .rotate({ angle: iconAngle })
      Text(label)
        .fontSize(15)
        .fontColor(label === '删除' ? $r('app.color.danger') : $r('app.color.text_primary'))
      Blank()
    }
    .width('100%')
    .height(48)
    .padding({ left: 18, right: 16 })
    .onClick(action)
  }

  // 行菜单：自绘悬浮卡挂 body Stack（viewport 固定；首页同款机制）。
  @Builder
  private RowMenuOverlay() {
    if (this.rowMenuId.length > 0) {
      Stack({ alignContent: Alignment.TopStart }) {
        Column()
          .width('100%')
          .height('100%')
          .onClick(() => {
            this.rowMenuId = '';
          })

        Column() {
          if (this.rowMenuIsFolder) {
            this.RowMenuRow($r('app.media.aura_edit'), '重命名', (): void => {
              const id = this.rowMenuId;
              const node = this.currentNodes.find((candidate: BookmarkNode): boolean =>
                candidate.id === id) ??
                this.recentNodes.find((candidate: BookmarkNode): boolean =>
                  candidate.id === id);
              this.rowMenuId = '';
              if (node !== undefined) {
                this.openForm('renameFolder', node);
              }
            }, 0)
            this.RowMenuRow($r('app.media.aura_trash'), '删除', (): void => {
              const id = this.rowMenuId;
              const node = this.currentNodes.find((candidate: BookmarkNode): boolean =>
                candidate.id === id) ??
                this.recentNodes.find((candidate: BookmarkNode): boolean =>
                  candidate.id === id);
              this.rowMenuId = '';
              if (node !== undefined) {
                this.removeWithConfirm(node);
              }
            }, 0)
          } else {
            this.RowMenuRow($r('app.media.aura_window'), '在新标签页打开', (): void => {
              const id = this.rowMenuId;
              const node = this.currentNodes.find((candidate: BookmarkNode): boolean =>
                candidate.id === id) ??
                this.recentNodes.find((candidate: BookmarkNode): boolean =>
                  candidate.id === id);
              this.rowMenuId = '';
              if (node !== undefined) {
                this.openNode(node);
              }
            }, 0)
            this.RowMenuRow($r('app.media.aura_edit'), '编辑', (): void => {
              const id = this.rowMenuId;
              const node = this.currentNodes.find((candidate: BookmarkNode): boolean =>
                candidate.id === id) ??
                this.recentNodes.find((candidate: BookmarkNode): boolean =>
                  candidate.id === id);
              this.rowMenuId = '';
              if (node !== undefined) {
                this.openForm('editBookmark', node);
              }
            }, 0)
            this.RowMenuRow($r('app.media.aura_copy'), '复制链接', (): void => {
              const id = this.rowMenuId;
              const node = this.currentNodes.find((candidate: BookmarkNode): boolean =>
                candidate.id === id) ??
                this.recentNodes.find((candidate: BookmarkNode): boolean =>
                  candidate.id === id);
              this.rowMenuId = '';
              if (node !== undefined && node.url !== undefined) {
                this.copyLink(node.url);
              }
            }, 0)
            this.RowMenuRow($r('app.media.aura_trash'), '删除', (): void => {
              const id = this.rowMenuId;
              const node = this.currentNodes.find((candidate: BookmarkNode): boolean =>
                candidate.id === id) ??
                this.recentNodes.find((candidate: BookmarkNode): boolean =>
                  candidate.id === id);
              this.rowMenuId = '';
              if (node !== undefined) {
                this.removeWithConfirm(node);
              }
            }, 0)
          }
        }
        .width(190)
        .padding({ top: 6, bottom: 6 })
        .borderRadius(22)
        .backgroundColor($r('app.color.menu_glass'))
        .shadow({ radius: 26, color: $r('app.color.shadow'), offsetY: 8 })
        .position({ x: this.rowMenuX, y: this.rowMenuY })
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.opacity(0)
            .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 })),
          TransitionEffect.opacity(0)
        ).animation({ duration: 180, curve: Curve.Friction }))
      }
      .width('100%')
      .height('100%')
    }
  }

  // 添加/编辑表单（页内自绘，弹层挂 body Stack = 遮罩盖满全屏、卡片居中）。
  @Builder
  private FormDialog() {
    if (this.dialogMode !== '') {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.modal_scrim'))
          .onClick(() => {
            this.cancelForm();
          })

        Column({ space: 14 }) {
          Text(this.formHeadline())
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          Column({ space: 6 }) {
            Text('名称')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            TextInput({ text: this.formTitle, placeholder: '名称' })
              .height(46)
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.surface_secondary'))
              .borderRadius(12)
              .onChange((value: string): void => {
                this.formTitle = value;
              })
          }
          .width('100%')

          if (this.dialogMode === 'addBookmark' || this.dialogMode === 'editBookmark') {
            Column({ space: 6 }) {
              Text('网址')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
              TextInput({ text: this.formUrl, placeholder: 'https://…' })
                .height(46)
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
                .backgroundColor($r('app.color.surface_secondary'))
                .borderRadius(12)
                .onChange((value: string): void => {
                  this.formUrl = value;
                })
            }
            .width('100%')
          }

          Row({ space: 12 }) {
            Row() {
              Text('取消')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
            }
            .justifyContent(FlexAlign.Center)
            .layoutWeight(1)
            .height(44)
            .borderRadius(12)
            .backgroundColor($r('app.color.surface_secondary'))
            .onClick(() => {
              this.cancelForm();
            })

            Row() {
              Text('保存')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.on_accent'))
            }
            .justifyContent(FlexAlign.Center)
            .layoutWeight(1)
            .height(44)
            .borderRadius(12)
            .backgroundColor($r('app.color.accent_primary'))
            .onClick(() => {
              this.confirmForm();
            })
          }
          .width('100%')
        }
        .width('100%')
        .padding(20)
        .borderRadius(22)
        .backgroundColor($r('app.color.menu_glass'))
        .shadow({ radius: 26, color: $r('app.color.shadow'), offsetY: 8 })
        .margin({ left: 28, right: 28 })
      }
      .width('100%')
      .height('100%')
    }
  }

  build() {
    GlassPage({
      title: '书签',
      scrollers: [this.listScroller],
      menus: {
        value: [
          {
            content: {
              icon: $r('app.media.aura_plus'),
              label: '新建文件夹',
              isEnabled: true,
              action: (): void => {
                this.openForm('addFolder');
              }
            }
          },
          {
            content: {
              icon: $r('app.media.aura_more'),
              label: '更多操作',
              action: (): void => {
                this.showMoreSheet();
              }
            }
          }
        ]
      },
      onBack: (): void => {
        this.handleBack();
      }
    }) {
    // body 包 Stack：行菜单/表单弹窗挂这里（viewport 固定，遮罩盖满全屏）。
    Stack({ alignContent: Alignment.TopStart }) {
    Column() {
      Row({ space: 8 }) {
        Image($r('app.media.chromium_search'))
          .width(16)
          .height(16)
          .fillColor($r('app.color.icon_secondary'))
        TextInput({ text: this.searchText, placeholder: '搜索书签' })
          .layoutWeight(1)
          .height(38)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_secondary'))
          .backgroundColor(Color.Transparent)
          .onChange((value: string) => {
            this.searchText = value;
            this.runSearch(value);
          })
      }
      .width('100%')
      .height(40)
      .borderRadius(20)
      .backgroundColor($r('app.color.surface_secondary'))
      .padding({ left: 12, right: 12 })

      if (this.searchText.trim().length > 0) {
        // 搜索：引擎全树匹配（searchBookmarks，命中带 path）。
        Scroll(this.listScroller) {
        Column() {
        if (this.searchResults.length === 0) {
          Text('没有匹配的书签')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 40 })
        }
        Column() {
          ForEach(this.searchResults, (node: BookmarkNode, index: number) => {
            this.BookmarkRow(node, index, this.searchResults.length)
          }, (node: BookmarkNode): string => node.id)
        }
        .width('100%')
        .borderRadius(16)
        .backgroundColor($r('app.color.card_background'))
        .clip(true)
        }
        .width('100%')
        }
        .layoutWeight(1)
        .padding({ top: 12 })
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
      } else if (this.loading) {
        Text('加载中…')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 40 })
      } else {
        Scroll(this.listScroller) {
        Column() {
          // 当前层：根级 = 三个根文件夹；子层 = 该文件夹内容（文件夹在前）。
          ForEach(this.currentNodes, (node: BookmarkNode, index: number) => {
            if (node.type === 'folder') {
              this.FolderRow(node)
            }
          }, (node: BookmarkNode): string => `f|${node.id}#${node.childCount ?? 0}`)

          if (this.currentFolderId.length === 0 && this.recentNodes.length > 0) {
            AuraSectionLabel({ text: '最近添加' })
            Column() {
              ForEach(this.recentNodes, (node: BookmarkNode, index: number) => {
                this.BookmarkRow(node, index, this.recentNodes.length)
              }, (node: BookmarkNode): string => `r|${node.id}`)
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor($r('app.color.card_background'))
            .clip(true)
          } else if (this.currentFolderId.length > 0) {
            Column() {
              ForEach(this.currentNodes, (node: BookmarkNode, index: number) => {
                if (node.type !== 'folder') {
                  this.BookmarkRow(node, index, this.currentNodes.length)
                }
              }, (node: BookmarkNode): string => `u|${node.id}`)
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor($r('app.color.card_background'))
            .clip(true)
          }
        }
        .width('100%')
        }
        .layoutWeight(1)
        .padding({ top: 12 })
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: glassHeaderInsetVp() })

    this.RowMenuOverlay()
    this.FormDialog()
    }
    .width('100%')
    .height('100%')
    }
  }
}
