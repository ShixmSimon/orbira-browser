/*
 * 手机"最近关闭的标签页"（对齐 Lumie v2：卡片式列表）。
 * 数据流：getRecentlyClosed -> recentlyClosed 事件（AuraShell 转存到
 * 'auraPanelRecent'）；点按一条即 restoreRecentlyClosed 并回到网页。
 */
import { BrowserCommandPayload, RecentlyClosedTab } from 'engine';
import { displayUrl, formatVisitTime } from './PanelBridge';
import { AuraSectionLabel } from './LumieKit';
import { GlassPage } from './GlassPage';

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

  @Builder
  private RecentRow(item: RecentlyClosedTab, index: number) {
    Column() {
      Row({ space: 12 }) {
        Image($r('app.media.aura_clock'))
          .width(22)
          .height(22)
          .fillColor($r('app.color.icon_primary'))

        Column({ space: 2 }) {
          Text(item.title.length > 0 ? item.title : displayUrl(item.url))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text(`${displayUrl(item.url)} · ${formatVisitTime(item.closedTime)}`)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .constraintSize({ minHeight: 60 })
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .onClick(() => {
        this.restore(item);
      })

      if (index < this.items.length - 1) {
        Divider()
          .color($r('app.color.divider'))
          .margin({ left: 50 })
      }
    }
    .width('100%')
  }

  build() {
    // 标题栏交给 GlassPage（落在 Navigation 标题栏里 —— HarmonyOS 7 之后
    // 只有这块区域 + 弹窗类还在沉浸光感的生效范围内）。
    GlassPage({ title: '最近关闭', onBack: (): void => { this.onBack(); } }) {
    Column() {
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
            AuraSectionLabel({ text: '最近关闭' })

            Column() {
              ForEach(this.items, (item: RecentlyClosedTab, index: number) => {
                this.RecentRow(item, index)
              }, (item: RecentlyClosedTab): string => item.id)
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor($r('app.color.card_background'))
            .clip(true)

            Text('点一条就可以把它重新打开。')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: 4, right: 4, top: 10 })
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
    .padding({ left: 16, right: 16, bottom: 16 })
    .backgroundColor($r('app.color.page_background'))
    }
  }
}
