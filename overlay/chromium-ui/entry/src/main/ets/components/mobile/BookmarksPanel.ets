/*
 * 手机自绘书签页（对齐 Lumie v2）。
 * 数据流：getRecentBookmarks -> recentBookmarks 事件（AuraShell 转存到
 * 'auraPanelBookmarks'）；添加/删除后引擎推 bookmarkCreated /
 * bookmarkOpResult / bookmarksChanged（转存到 'auraPanelEvent'），本页据此重拉。
 * 功能：收藏当前页（+）、手动添加、删除、打开；⋯ 菜单：导入书签（HTML）/
 * 导出书签，文件选择与沙箱复制由外壳负责（见 PanelBridge）。
 */
import { common } from '@kit.AbilityKit';
import { BookmarkNode, BrowserCommandPayload } from 'engine';
import { displayUrl, pickAndStageImportFile, saveExportedFile, deleteStagedFile } from './PanelBridge';
import { AuraSectionLabel } from './LumieKit';
import { GlassPage, glassHeaderInsetVp } from './GlassPage';

interface BookmarkIoPayload {
  kind?: string;
  requestId?: number;
  ok?: boolean;
  bookmarkCount?: number;
  folderCount?: number;
  skippedCount?: number;
  error?: string;
}

@Component
export struct BookmarksPanel {
  @Prop currentUrl: string = '';
  @Prop currentTitle: string = '';
  @StorageLink('auraPanelBookmarks') @Watch('onBookmarksChanged') bookmarksJson: string = '';
  @StorageLink('auraPanelBookmarkIo') @Watch('onIoPayload') bookmarkIoJson: string = '';
  @StorageLink('auraPanelEvent') @Watch('onPanelEvent') panelEventJson: string = '';
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  onBack: () => void = (): void => {};
  onClose: () => void = (): void => {};

  @State private nodes: BookmarkNode[] = [];
  @State private loading: boolean = true;
  @State private adding: boolean = false;
  @State private addTitle: string = '';
  @State private addUrl: string = '';
  private requestSeq: number = 0;
  private retryTimer: number = -1;
  private pendingImportPath: string = '';
  private pendingExportPath: string = '';
  private pendingExportRequestId: number = 0;

  aboutToAppear(): void {
    // Seed from storage first: a @StorageLink does not fire @Watch for its
    // initial value, and a byte-identical engine reply raises no change
    // either, so a re-opened panel would otherwise stay on "loading".
    this.onBookmarksChanged();
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

  private cleanupPendingImport(): void {
    if (this.pendingImportPath.length > 0) {
      deleteStagedFile(this.pendingImportPath);
      this.pendingImportPath = '';
    }
  }

  private reload(): void {
    this.loading = true;
    this.requestSeq += 1;
    this.onCommand({ command: 'getRecentBookmarks', requestId: this.requestSeq, maxCount: 300 });
  }

  private onBookmarksChanged(): void {
    if (this.bookmarksJson.length === 0) {
      return;
    }
    try {
      this.nodes = JSON.parse(this.bookmarksJson) as BookmarkNode[];
      this.loading = false;
    } catch (error) {
      this.loading = false;
    }
  }

  private onPanelEvent(): void {
    // bookmarkCreated / bookmarkOpResult / bookmarksChanged: reload.
    this.reload();
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

  private openNode(node: BookmarkNode): void {
    const url = node.url ?? '';
    if (url.length === 0) {
      return;
    }
    this.onCommand({ command: 'navigate', url: url });
    this.onClose();
  }

  private removeNode(node: BookmarkNode): void {
    const url = node.url ?? '';
    if (url.length === 0) {
      return;
    }
    this.requestSeq += 1;
    this.onCommand({ command: 'removeBookmarkByUrl', url: url, requestId: this.requestSeq });
  }

  private addCurrentPage(): void {
    if (this.currentUrl.length === 0) {
      return;
    }
    this.requestSeq += 1;
    this.onCommand({
      command: 'addBookmark',
      url: this.currentUrl,
      title: this.currentTitle.length > 0 ? this.currentTitle : this.currentUrl,
      requestId: this.requestSeq
    });
  }

  // -- 手动添加 ---------------------------------------------------------------

  private openAddDialog(): void {
    this.addUrl = this.currentUrl;
    this.addTitle = this.currentTitle;
    this.adding = true;
  }

  private cancelAdd(): void {
    this.adding = false;
    this.addTitle = '';
    this.addUrl = '';
  }

  private confirmAdd(): void {
    const url = this.addUrl.trim();
    if (url.length === 0) {
      return;
    }
    this.requestSeq += 1;
    this.onCommand({
      command: 'addBookmark',
      url: url,
      title: this.addTitle.trim().length > 0 ? this.addTitle.trim() : url,
      requestId: this.requestSeq
    });
    this.cancelAdd();
  }

  // -- 导入 / 导出（对齐 Lumie v2） -------------------------------------------

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

  // -- UI ---------------------------------------------------------------------


  @Builder
  private BookmarkRow(node: BookmarkNode, index: number) {
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
          Image($r('app.media.aura_close'))
            .width(18)
            .height(18)
            .fillColor($r('app.color.icon_secondary'))
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .accessibilityText('删除书签')
        .onClick(() => {
          this.removeNode(node);
        })
      }
      .width('100%')
      .constraintSize({ minHeight: 60 })
      .padding({ left: 16, right: 6, top: 8, bottom: 8 })
      .onClick(() => {
        this.openNode(node);
      })

      if (index < this.nodes.length - 1) {
        Divider()
          .color($r('app.color.divider'))
          .margin({ left: 50 })
      }
    }
    .width('100%')
  }

  @Builder
  private AddDialog() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.modal_scrim'))
        .onClick(() => {
          this.cancelAdd();
        })

      Column({ space: 14 }) {
        Text('添加书签')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')

        Column({ space: 6 }) {
          Text('名称')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          TextInput({ text: this.addTitle, placeholder: '书签名称' })
            .height(46)
            .fontSize(15)
            .backgroundColor($r('app.color.surface_secondary'))
            .borderRadius(10)
            .onChange((value: string): void => {
              this.addTitle = value;
            })
        }
        .width('100%')

        Column({ space: 6 }) {
          Text('网址')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          TextInput({ text: this.addUrl, placeholder: 'https://…' })
            .height(46)
            .fontSize(15)
            .type(InputType.Normal)
            .backgroundColor($r('app.color.surface_secondary'))
            .borderRadius(10)
            .onChange((value: string): void => {
              this.addUrl = value;
            })
        }
        .width('100%')

        Row({ space: 12 }) {
          Button('取消')
            .layoutWeight(1)
            .height(44)
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.surface_secondary'))
            .borderRadius(10)
            .onClick(() => {
              this.cancelAdd();
            })
          Button('保存')
            .layoutWeight(1)
            .height(44)
            .fontSize(16)
            .fontColor($r('app.color.on_accent'))
            .backgroundColor($r('app.color.accent_primary'))
            .borderRadius(10)
            .enabled(this.addUrl.trim().length > 0)
            .opacity(this.addUrl.trim().length > 0 ? 1 : 0.5)
            .onClick(() => {
              this.confirmAdd();
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(20)
      .borderRadius(16)
      .backgroundColor($r('app.color.card_background'))
    }
    .width('100%')
    .height('100%')
  }

  // ⋯ 的子菜单改走系统 ActionSheet（本页是原生内容，系统弹窗可用；
  // 网页上方的浮层才禁用系统弹窗，见 MobileBrowserOverlay 菜单卡注释）。
  private showMoreSheet(): void {
    ActionSheet.show({
      title: '书签操作',
      message: '',
      sheets: [
        {
          title: '手动添加书签',
          action: (): void => {
            this.openAddDialog();
          }
        },
        {
          title: '导入书签',
          action: (): void => {
            this.startImport();
          }
        },
        {
          title: '导出书签',
          action: (): void => {
            this.startExport();
          }
        }
      ]
    });
  }

  private listScroller: Scroller = new Scroller();

  build() {
    // 标题栏放进 Navigation（HarmonyOS 7 之后只有 Navigation 标题栏 / 底部
    // TabBar / 弹窗类还在沉浸光感的生效范围内，自绘 Header 挂材质会静默失效）。
    // 本页标题栏右侧还有「+」和「更多」，所以不用 GlassPage，自己包一层。
    GlassPage({
      title: '书签',
      scrollers: [this.listScroller],
      menus: {
        value: [
          {
            content: {
              icon: $r('app.media.aura_plus'),
              label: '收藏当前网页',
              isEnabled: this.currentUrl.length > 0,
              action: (): void => {
                this.addCurrentPage();
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
        if (this.adding) {
          this.cancelAdd();
        } else {
          this.onBack();
        }
      }
    }) {
    Column() {
      if (this.nodes.length === 0) {
        Column({ space: 6 }) {
          Text(this.loading ? '加载中…' : '暂无书签')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
          if (!this.loading) {
            Text('点右上角"+"收藏当前网页，或打开 ⋯ 导入书签')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
          }
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll(this.listScroller) {
          Column() {
            AuraSectionLabel({ text: `最近添加 · ${this.nodes.length}`, tightTop: true })

            Column() {
              ForEach(this.nodes, (node: BookmarkNode, index: number) => {
                this.BookmarkRow(node, index)
              }, (node: BookmarkNode): string => node.id)
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor($r('app.color.card_background'))
            .clip(true)

            Text('右上角 ⋯ 里可以手动添加、导入或导出书签。')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: 4, right: 4, top: 10 })
          }
          .width('100%')
          // 大标题带：滚动内容穿过「书签」大标题时逐渐虚化（见 GlassPage 文件头）。
          .padding({ top: glassHeaderInsetVp() })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
      }

      if (this.adding) {
        this.AddDialog()
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, bottom: 16 })
    .backgroundColor($r('app.color.page_background'))

    }
  }
}
