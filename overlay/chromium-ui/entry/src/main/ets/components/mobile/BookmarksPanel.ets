/*
 * 手机自绘书签页（参考外壳扩展）。
 * 数据流：getRecentBookmarks -> recentBookmarks 事件（AuraShell 转存到
 * 'auraPanelBookmarks'）；添加/删除后引擎推 bookmarkCreated /
 * bookmarkOpResult / bookmarksChanged（转存到 'auraPanelEvent'），本页据此重拉。
 */
import { BookmarkNode, BrowserCommandPayload } from 'engine';
import { displayUrl } from './PanelBridge';

@Component
export struct BookmarksPanel {
  @Prop currentUrl: string = '';
  @Prop currentTitle: string = '';
  @StorageLink('auraPanelBookmarks') @Watch('onBookmarksChanged') bookmarksJson: string = '';
  @StorageLink('auraPanelEvent') @Watch('onPanelEvent') panelEventJson: string = '';
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  onBack: () => void = (): void => {};
  onClose: () => void = (): void => {};

  @State private nodes: BookmarkNode[] = [];
  @State private loading: boolean = true;
  private requestSeq: number = 0;
  private retryTimer: number = -1;

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

  build() {
    Column() {
      Row() {
        Button({ type: ButtonType.Circle }) {
          Image($r('app.media.chromium_back'))
            .width(22)
            .height(22)
            .fillColor($r('app.color.icon_primary'))
        }
        .width(44)
        .height(44)
        .backgroundColor($r('app.color.surface_secondary'))
        .accessibilityText('返回')
        .onClick(() => {
          this.onBack();
        })

        Text('书签')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 12 })

        Blank()

        Button({ type: ButtonType.Circle }) {
          Image($r('app.media.chromium_add'))
            .width(22)
            .height(22)
            .fillColor($r('app.color.icon_primary'))
        }
        .width(44)
        .height(44)
        .backgroundColor($r('app.color.surface_secondary'))
        .accessibilityText('收藏当前网页')
        .enabled(this.currentUrl.length > 0)
        .opacity(this.currentUrl.length > 0 ? 1 : 0.5)
        .onClick(() => {
          this.addCurrentPage();
        })
      }
      .width('100%')
      .height(52)

      if (this.nodes.length === 0) {
        Column({ space: 6 }) {
          Text(this.loading ? '加载中…' : '暂无书签')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
          if (!this.loading) {
            Text('点右上角"+"把当前网页加入书签')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
          }
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 2 }) {
          ForEach(this.nodes, (node: BookmarkNode) => {
            ListItem() {
              Row({ space: 10 }) {
                Column({ space: 2 }) {
                  Text(node.title.length > 0 ? node.title : displayUrl(node.url ?? ''))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .fontSize(16)
                    .fontColor($r('app.color.text_primary'))
                  Text(displayUrl(node.url ?? ''))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Button({ type: ButtonType.Circle }) {
                  Image($r('app.media.chromium_close'))
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
              .height(58)
              .padding({ left: 4, right: 2 })
              .onClick(() => {
                this.openNode(node);
              })
            }
          }, (node: BookmarkNode): string => node.id)
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, bottom: 16 })
    .backgroundColor($r('app.color.surface_primary'))
  }
}
