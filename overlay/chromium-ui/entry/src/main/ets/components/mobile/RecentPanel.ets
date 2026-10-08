/*
 * 手机"最近关闭的标签页"（参考外壳扩展）。
 * 数据流：getRecentlyClosed -> recentlyClosed 事件（AuraShell 转存到
 * 'auraPanelRecent'）；点按一条即 restoreRecentlyClosed 并回到网页。
 */
import { BrowserCommandPayload, RecentlyClosedTab } from 'engine';
import { displayUrl, formatVisitTime } from './PanelBridge';

@Component
export struct RecentPanel {
  @StorageLink('auraPanelRecent') @Watch('onRecentPayload') recentJson: string = '';
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  onBack: () => void = (): void => {};
  onClose: () => void = (): void => {};

  @State private items: RecentlyClosedTab[] = [];
  @State private loading: boolean = true;
  private requestSeq: number = 0;
  private retryTimer: number = -1;

  aboutToAppear(): void {
    // Seed from storage first: a @StorageLink does not fire @Watch for its
    // initial value, and a byte-identical engine reply raises no change
    // either, so a re-opened panel would otherwise stay on "loading".
    this.onRecentPayload();
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
    this.onCommand({ command: 'getRecentlyClosed', requestId: this.requestSeq, maxCount: 50 });
  }

  private onRecentPayload(): void {
    if (this.recentJson.length === 0) {
      return;
    }
    try {
      this.items = JSON.parse(this.recentJson) as RecentlyClosedTab[];
      this.loading = false;
    } catch (error) {
      this.loading = false;
    }
  }

  private restore(item: RecentlyClosedTab): void {
    this.onCommand({ command: 'restoreRecentlyClosed', id: item.id });
    this.onClose();
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

        Text('最近关闭')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 12 })

        Blank()
      }
      .width('100%')
      .height(52)

      if (this.items.length === 0) {
        Column() {
          Text(this.loading ? '加载中…' : '没有最近关闭的标签页')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            ForEach(this.items, (item: RecentlyClosedTab, index: number) => {
              Column() {
                Row({ space: 10 }) {
                  Column({ space: 2 }) {
                    Text(item.title.length > 0 ? item.title : displayUrl(item.url))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .fontSize(16)
                      .fontColor($r('app.color.text_primary'))
                    Text(`${displayUrl(item.url)} · ${formatVisitTime(item.closedTime)}`)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .fontSize(12)
                      .fontColor($r('app.color.text_secondary'))
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                }
                .width('100%')
                .height(58)
                .padding({ left: 4, right: 2 })
                .onClick(() => {
                  this.restore(item);
                })

                if (index < this.items.length - 1) {
                  Divider()
                    .color($r('app.color.divider'))
                }
              }
              .width('100%')
            }, (item: RecentlyClosedTab): string => item.id)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        // Scroll centers content shorter than the viewport by default (the
        // universal `align` attribute defaults to Alignment.Center); pin to
        // the top instead.
        .align(Alignment.TopStart)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, bottom: 16 })
    .backgroundColor($r('app.color.surface_primary'))
  }
}
