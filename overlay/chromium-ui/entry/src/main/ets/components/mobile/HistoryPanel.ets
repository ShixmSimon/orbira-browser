/*
 * 手机自绘历史页（参考外壳扩展）。
 * 数据流：queryHistory -> historyResults 事件（AuraShell 转存到
 * 'auraPanelHistory'）；删除或别处变化后引擎推 historyChanged
 * （转存到 'auraPanelEvent'），本页据此重拉。
 */
import { BrowserCommandPayload, HistoryItem } from 'engine';
import { displayUrl, formatVisitTime } from './PanelBridge';

@Component
export struct HistoryPanel {
  @StorageLink('auraPanelHistory') @Watch('onHistoryChanged') historyJson: string = '';
  @StorageLink('auraPanelEvent') @Watch('onPanelEvent') panelEventJson: string = '';
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  onBack: () => void = (): void => {};
  onClose: () => void = (): void => {};

  @State private items: HistoryItem[] = [];
  @State private loading: boolean = true;
  private requestSeq: number = 0;
  private retryTimer: number = -1;

  aboutToAppear(): void {
    // Seed from storage first: a @StorageLink does not fire @Watch for its
    // initial value, and a byte-identical engine reply raises no change
    // either, so a re-opened panel would otherwise stay on "loading".
    this.onHistoryChanged();
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
    this.onCommand({ command: 'queryHistory', requestId: this.requestSeq, text: '', maxCount: 200 });
  }

  private onHistoryChanged(): void {
    if (this.historyJson.length === 0) {
      return;
    }
    try {
      this.items = JSON.parse(this.historyJson) as HistoryItem[];
      this.loading = false;
    } catch (error) {
      this.loading = false;
    }
  }

  private onPanelEvent(): void {
    // historyChanged: reload.
    this.reload();
  }

  private openItem(item: HistoryItem): void {
    if (item.url.length === 0) {
      return;
    }
    this.onCommand({ command: 'navigate', url: item.url });
    this.onClose();
  }

  private removeItem(item: HistoryItem): void {
    if (item.url.length === 0) {
      return;
    }
    this.onCommand({
      command: 'removeHistoryItems',
      items: [{ url: item.url, visitTime: item.visitTime }]
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

        Text('历史')
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
          Text(this.loading ? '加载中…' : '暂无历史记录')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 2 }) {
          ForEach(this.items, (item: HistoryItem) => {
            ListItem() {
              Row({ space: 10 }) {
                Column({ space: 2 }) {
                  Text(item.title.length > 0 ? item.title : displayUrl(item.url))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .fontSize(16)
                    .fontColor($r('app.color.text_primary'))
                  Text(`${displayUrl(item.url)} · ${formatVisitTime(item.visitTime)}`)
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
                .accessibilityText('删除这条记录')
                .onClick(() => {
                  this.removeItem(item);
                })
              }
              .width('100%')
              .height(58)
              .padding({ left: 4, right: 2 })
              .onClick(() => {
                this.openItem(item);
              })
            }
          }, (item: HistoryItem): string => `${item.url}|${item.visitTime}`)
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
