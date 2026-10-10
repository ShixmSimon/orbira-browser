/*
 * 手机自绘书签页 v3（2026-10-10）：完整书签树 + 文件夹管理。
 *
 * 数据流：getBookmarksForSync -> bookmarksForSync 事件（AuraShell 转存到
 * 'auraPanelBookmarkSync'，全树 by UUID）——本页在树里做文件夹导航（点文件夹
 * 进入、返回钮逐级上退）、行菜单（书签：打开/编辑/复制链接/删除；文件夹：
 * 重命名/删除）、新建文件夹与编辑书签都走 applyBookmarks（upsert/remove 批量
 * 写回，引擎回 bookmarksChanged 后本页重拉树）。
 * 标题栏 + = 新建文件夹（原「收藏当前网页」与手动添加重复，撤）；⋯ 菜单 =
 * 手动添加书签（预填当前页）/ 导入 / 导出（HTML，文件选择与沙箱复制由外壳负责）。
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { display, promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import {
  BrowserCommandPayload,
  SyncBookmarkNode,
  SyncBookmarkOp,
  SyncBookmarkRemove,
  SyncBookmarkUpsert
} from 'engine';
import { displayUrl, pickAndStageImportFile, saveExportedFile, deleteStagedFile } from './PanelBridge';
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

type FormMode = '' | 'addBookmark' | 'editBookmark' | 'addFolder' | 'renameFolder';

@Component
export struct BookmarksPanel {
  @Prop currentUrl: string = '';
  @Prop currentTitle: string = '';
  @StorageLink('auraPanelBookmarkSync') @Watch('onSyncChanged') syncJson: string = '';
  @StorageLink('auraPanelBookmarkIo') @Watch('onIoPayload') bookmarkIoJson: string = '';
  @StorageLink('auraPanelEvent') @Watch('onPanelEvent') panelEventJson: string = '';
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  onBack: () => void = (): void => {};
  onClose: () => void = (): void => {};

  // 全树（bookmarksForSync，parents 在前、同级按 index）。
  @State private syncNodes: SyncBookmarkNode[] = [];
  // 当前所在文件夹的 uuid（'' = 树还没到，到货后设为 mobile 根）。
  @State private currentFolderUuid: string = '';
  // 当前文件夹的直接子节点（落 @State：方法间接读状态不建立更新依赖）。
  @State private visibleNodes: SyncBookmarkNode[] = [];
  @State private loading: boolean = true;
  private requestSeq: number = 0;
  private retryTimer: number = -1;
  private pendingImportPath: string = '';
  private pendingExportPath: string = '';
  private pendingExportRequestId: number = 0;

  // 表单弹窗（添加/编辑书签、新建/重命名文件夹共用）。
  @State private dialogMode: FormMode = '';
  @State private formTitle: string = '';
  @State private formUrl: string = '';
  private editUuid: string = '';

  // 搜索（全树 url 节点，标题/网址命中）。
  @State private searchText: string = '';
  @State private searchResults: SyncBookmarkNode[] = [];

  // 行菜单（自绘卡，首页同款）：目标节点 + 落点。
  @State private rowMenuUuid: string = '';
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
    this.onSyncChanged();
    this.reload();
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1;
      if (this.loading) {
        this.reload();
      }
    }, 1500);
  }

  aboutToDisappear(): void {
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    this.cleanupPendingImport();
  }

  // -- 数据层 -----------------------------------------------------------------

  private reload(): void {
    this.loading = true;
    this.requestSeq += 1;
    this.onCommand({ command: 'getBookmarksForSync', requestId: this.requestSeq });
  }

  private onSyncChanged(): void {
    if (this.syncJson.length === 0) {
      return;
    }
    try {
      this.syncNodes = JSON.parse(this.syncJson) as SyncBookmarkNode[];
      if (this.currentFolderUuid.length === 0) {
        this.currentFolderUuid = this.mobileRootUuid();
      }
      this.recomputeVisible();
      this.recomputeSearch();
      this.loading = false;
    } catch (error) {
      this.loading = false;
    }
  }

  private onPanelEvent(): void {
    // bookmarkCreated / bookmarkOpResult / bookmarksChanged: reload.
    this.reload();
  }

  /** 移动设备根（新文件夹/书签的默认落点；树里没找到返回 ''）。 */
  private mobileRootUuid(): string {
    for (const node of this.syncNodes) {
      if (node.rootType === 'mobile') {
        return node.uuid;
      }
    }
    return '';
  }

  private recomputeVisible(): void {
    if (this.currentFolderUuid.length === 0) {
      this.visibleNodes = [];
      return;
    }
    const out: SyncBookmarkNode[] = [];
    for (const node of this.syncNodes) {
      if (node.parentUuid === this.currentFolderUuid) {
        out.push(node);
      }
    }
    out.sort((a: SyncBookmarkNode, b: SyncBookmarkNode): number => a.index - b.index);
    this.visibleNodes = out;
  }

  private recomputeSearch(): void {
    const q = this.searchText.trim().toLowerCase();
    if (q.length === 0) {
      this.searchResults = [];
      return;
    }
    const out: SyncBookmarkNode[] = [];
    for (const node of this.syncNodes) {
      if (!node.isFolder &&
        (node.title.toLowerCase().includes(q) || node.url.toLowerCase().includes(q))) {
        out.push(node);
      }
    }
    this.searchResults = out;
  }

  /** 返回钮：在子文件夹里先逐级上退，到根再关面板。 */
  private handleBack(): void {
    if (this.currentFolderUuid.length > 0) {
      const current = this.findNode(this.currentFolderUuid);
      if (current !== undefined && current.rootType === undefined) {
        this.currentFolderUuid = current.parentUuid;
        this.recomputeVisible();
        return;
      }
    }
    this.onBack();
  }

  private findNode(uuid: string): SyncBookmarkNode | undefined {
    for (const node of this.syncNodes) {
      if (node.uuid === uuid) {
        return node;
      }
    }
    return undefined;
  }

  private openNode(node: SyncBookmarkNode): void {
    if (node.isFolder) {
      this.currentFolderUuid = node.uuid;
      this.recomputeVisible();
      return;
    }
    if (node.url.length === 0) {
      return;
    }
    this.onCommand({ command: 'navigate', url: node.url });
    this.onClose();
  }

  private applyOps(ops: SyncBookmarkOp[]): void {
    this.requestSeq += 1;
    this.onCommand({
      command: 'applyBookmarks',
      requestId: this.requestSeq,
      origin: 'sync',
      ops: ops
    });
  }

  private genUuid(): string {
    return util.generateRandomUUID(false);
  }

  /** 当前文件夹的直接子节点数（新建节点排在末尾）。 */
  private childCountOf(folderUuid: string): number {
    let n = 0;
    for (const node of this.syncNodes) {
      if (node.parentUuid === folderUuid) {
        n += 1;
      }
    }
    return n;
  }

  // -- 行菜单 -----------------------------------------------------------------

  private openRowMenu(node: SyncBookmarkNode): void {
    const cardW = 190;
    const cardH = node.isFolder ? 108 : 204;
    this.rowMenuX = Math.min(Math.max(this.menuPressX - cardW / 2, 12),
      Math.max(12, this.windowW - cardW - 12));
    this.rowMenuY = Math.min(this.menuPressY + 8, Math.max(12, this.windowH - cardH - 96));
    this.rowMenuIsFolder = node.isFolder;
    this.rowMenuUuid = node.uuid;
  }

  private copyLink(url: string): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
    pasteboard.getSystemPasteboard().setData(data).catch((): void => {
    });
    this.getUIContext().getPromptAction().showToast({ message: '链接已复制', duration: 1500 });
  }

  private removeWithConfirm(node: SyncBookmarkNode): void {
    this.getUIContext().getPromptAction().showDialog({
      title: node.isFolder ? '删除文件夹' : '删除书签',
      message: node.title.length > 0 ? node.title : node.url,
      buttons: [
        { text: '取消', color: '#5F6368' },
        { text: '删除', color: '#E24B4A' }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (result.index !== 1) {
        return;
      }
      const op: SyncBookmarkRemove = { op: 'remove', uuid: node.uuid };
      this.applyOps([op]);
      if (node.isFolder && this.currentFolderUuid === node.uuid) {
        // 删除的是正浏览的文件夹：退到其父级（remove 级联，本页立即上退）。
        const parent = this.findNode(node.parentUuid);
        this.currentFolderUuid = parent !== undefined ? parent.uuid : this.mobileRootUuid();
        this.recomputeVisible();
      }
    }).catch((error: Error): void => {
    });
  }

  // -- 表单弹窗（添加/编辑书签、新建/重命名文件夹） -----------------------------

  private openForm(mode: FormMode, node?: SyncBookmarkNode): void {
    this.editUuid = node !== undefined ? node.uuid : '';
    this.formTitle = node !== undefined ? node.title : '';
    this.formUrl = node !== undefined ? node.url : '';
    if (mode === 'addBookmark') {
      // 手动添加：预填当前页（等价原「收藏当前网页」，+ 撤掉后这里是唯一入口）。
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
      const op: SyncBookmarkUpsert = {
        op: 'upsert',
        uuid: this.genUuid(),
        parentUuid: this.currentFolderUuid,
        isFolder: false,
        title: title.length > 0 ? title : url,
        url: url,
        index: this.childCountOf(this.currentFolderUuid)
      };
      this.applyOps([op]);
    } else if (this.dialogMode === 'addFolder') {
      const name = title.length > 0 ? title : '新建文件夹';
      const op: SyncBookmarkUpsert = {
        op: 'upsert',
        uuid: this.genUuid(),
        parentUuid: this.currentFolderUuid,
        isFolder: true,
        title: name,
        url: '',
        index: this.childCountOf(this.currentFolderUuid)
      };
      this.applyOps([op]);
    } else if (this.dialogMode === 'editBookmark' || this.dialogMode === 'renameFolder') {
      const node = this.findNode(this.editUuid);
      if (node === undefined) {
        this.cancelForm();
        return;
      }
      const op: SyncBookmarkUpsert = {
        op: 'upsert',
        uuid: node.uuid,
        parentUuid: node.parentUuid,
        isFolder: node.isFolder,
        title: title.length > 0 ? title : node.title,
        url: node.url,
        index: node.index
      };
      this.applyOps([op]);
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
          this.reload();
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
  private FolderRow(node: SyncBookmarkNode) {
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
          Text(`${this.childCountOf(node.uuid)} 项`)
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
  private BookmarkRow(node: SyncBookmarkNode, index: number, total: number) {
    Column() {
      Row({ space: 12 }) {
        Image($r('app.media.aura_bookmark'))
          .width(22)
          .height(22)
          .fillColor($r('app.color.icon_primary'))

        Column({ space: 2 }) {
          Text(node.title.length > 0 ? node.title : displayUrl(node.url))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text(displayUrl(node.url))
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
    if (this.rowMenuUuid.length > 0) {
      Stack({ alignContent: Alignment.TopStart }) {
        Column()
          .width('100%')
          .height('100%')
          .onClick(() => {
            this.rowMenuUuid = '';
          })

        Column() {
          if (this.rowMenuIsFolder) {
            this.RowMenuRow($r('app.media.aura_edit'), '重命名', (): void => {
              const node = this.findNode(this.rowMenuUuid);
              this.rowMenuUuid = '';
              if (node !== undefined) {
                this.openForm('renameFolder', node);
              }
            }, 0)
            this.RowMenuRow($r('app.media.aura_trash'), '删除', (): void => {
              const node = this.findNode(this.rowMenuUuid);
              this.rowMenuUuid = '';
              if (node !== undefined) {
                this.removeWithConfirm(node);
              }
            }, 0)
          } else {
            this.RowMenuRow($r('app.media.aura_window'), '在新标签页打开', (): void => {
              const node = this.findNode(this.rowMenuUuid);
              this.rowMenuUuid = '';
              if (node !== undefined) {
                this.openNode(node);
              }
            }, 0)
            this.RowMenuRow($r('app.media.aura_edit'), '编辑', (): void => {
              const node = this.findNode(this.rowMenuUuid);
              this.rowMenuUuid = '';
              if (node !== undefined) {
                this.openForm('editBookmark', node);
              }
            }, 0)
            this.RowMenuRow($r('app.media.aura_copy'), '复制链接', (): void => {
              const node = this.findNode(this.rowMenuUuid);
              this.rowMenuUuid = '';
              if (node !== undefined) {
                this.copyLink(node.url);
              }
            }, 0)
            this.RowMenuRow($r('app.media.aura_trash'), '删除', (): void => {
              const node = this.findNode(this.rowMenuUuid);
              this.rowMenuUuid = '';
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
            Text(this.dialogMode === 'addFolder' || this.dialogMode === 'renameFolder' ? '名称' : '名称')
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
            this.recomputeSearch();
          })
      }
      .width('100%')
      .height(40)
      .borderRadius(20)
      .backgroundColor($r('app.color.surface_secondary'))
      .padding({ left: 12, right: 12 })
      .margin({ bottom: 10 })

      if (this.searchText.trim().length > 0) {
        // 搜索：全树平铺命中项（点击打开）。Scroll 单子组件：内容包一个 Column。
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
          ForEach(this.searchResults, (node: SyncBookmarkNode, index: number) => {
            this.BookmarkRow(node, index, this.searchResults.length)
          }, (node: SyncBookmarkNode): string => node.uuid)
        }
        .width('100%')
        .borderRadius(16)
        .backgroundColor($r('app.color.card_background'))
        .clip(true)
        }
        .width('100%')
        }
        .width('100%')
        .padding({ top: glassHeaderInsetVp() })
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
      } else if (this.loading) {
        Text('加载中…')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 40 })
      } else if (this.visibleNodes.length === 0) {
        Column({ space: 6 }) {
          Text('这个文件夹是空的')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
          if (this.currentFolderUuid === this.mobileRootUuid()) {
            Text('右上角 + 新建文件夹，⋯ 手动添加书签')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
          }
        }
        .width('100%')
        .margin({ top: 60 })
      } else {
        Scroll(this.listScroller) {
          Column() {
            // 文件夹在前、书签在后（对齐 Lumie 的树视图）。
            // 键带子节点数：往文件夹里加/删书签后条数变化 → 键变 → "N 项"刷新。
            ForEach(this.visibleNodes, (node: SyncBookmarkNode, index: number) => {
              if (node.isFolder) {
                this.FolderRow(node)
              }
            }, (node: SyncBookmarkNode): string => `f|${node.uuid}#${this.childCountOf(node.uuid)}`)
            Column() {
              ForEach(this.visibleNodes, (node: SyncBookmarkNode, index: number) => {
                if (!node.isFolder) {
                  this.BookmarkRow(node, index, this.visibleNodes.length)
                }
              }, (node: SyncBookmarkNode): string => `u|${node.uuid}`)
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor($r('app.color.card_background'))
            .clip(true)
          }
          .width('100%')
          .padding({ top: glassHeaderInsetVp() })
        }
        .layoutWeight(1)
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
