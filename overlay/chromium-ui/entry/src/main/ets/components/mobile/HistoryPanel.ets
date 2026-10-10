/*
 * 手机自绘历史页（对齐 Lumie v2）：卡片式列表，按天分组（今天 / 昨天 /
 * 月日 / 年月日，对齐 Lumie 的 DayGrouping）。
 * 数据流：queryHistory -> historyResults 事件（AuraShell 转存到
 * 'auraPanelHistory'）；删除或别处变化后引擎推 historyChanged
 * （转存到 'auraPanelEvent'），本页据此重拉。
 */
import { BrowserCommandPayload, HistoryItem } from 'engine';
import { displayUrl, dayGroupLabel, formatClock } from './PanelBridge';
import { AuraSectionLabel } from './LumieKit';
import { GlassPage, glassHeaderInsetVp } from './GlassPage';

interface HistoryGroup {
  label: string;
  items: HistoryItem[];
}

// 按天分组；queryHistory 结果已按时间倒序。
function groupHistory(items: HistoryItem[]): HistoryGroup[] {
  const groups: HistoryGroup[] = [];
  for (let index = 0; index < items.length; index += 1) {
    const item = items[index];
    const label = dayGroupLabel(item.visitTime);
    const last = groups.length > 0 ? groups[groups.length - 1] : undefined;
    if (last === undefined || last.label !== label) {
      groups.push({ label: label, items: [] });
    }
    groups[groups.length - 1].items.push(item);
  }
  return groups;
}

@Component
export struct HistoryPanel {
  @StorageLink('auraPanelHistory') @Watch('onHistoryChanged') historyJson: string = '';
  @StorageLink('auraPanelEvent') @Watch('onPanelEvent') panelEventJson: string = '';
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  onBack: () => void = (): void => {};
  onClose: () => void = (): void => {};

  @State private items: HistoryItem[] = [];
  @State private groups: HistoryGroup[] = [];
  @State private loading: boolean = true;
  // 渐变模糊滚动效果按官方要求 bindToScrollable。
  private listScroller: Scroller = new Scroller();
  @State private searchText: string = '';
  // 过滤结果落 @State：build 里 ForEach/if 经方法间接读 @State 不会建立更新依赖
  //（编译器不分析方法体），搜索词变化时列表不刷新——显式重算才能驱动更新。
  @State private filteredGroups: HistoryGroup[] = [];
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
      this.groups = groupHistory(this.items);
      this.recomputeFiltered();
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

  @Builder
  private HistoryRow(item: HistoryItem, isLast: boolean) {
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
          Text(`${displayUrl(item.url)} · ${formatClock(item.visitTime)}`)
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
        .accessibilityText('删除这条记录')
        .onClick(() => {
          this.removeItem(item);
        })
      }
      .width('100%')
      .constraintSize({ minHeight: 60 })
      .padding({ left: 16, right: 6, top: 8, bottom: 8 })
      .onClick(() => {
        this.openItem(item);
      })

      if (!isLast) {
        Divider()
          .color($r('app.color.divider'))
          .margin({ left: 50 })
      }
    }
    .width('100%')
  }

  // 重算过滤结果（写入 @State）：搜索词变化与数据源变化处都要调用。
  private recomputeFiltered(): void {
    const q = this.searchText.trim().toLowerCase();
    if (q.length === 0) {
      this.filteredGroups = this.groups;
      return;
    }
    const out: HistoryGroup[] = [];
    for (const group of this.groups) {
      const items: HistoryItem[] = [];
      for (const item of group.items) {
        if (item.title.toLowerCase().includes(q) || item.url.toLowerCase().includes(q)) {
          items.push(item);
        }
      }
      if (items.length > 0) {
        out.push({ label: group.label, items: items } as HistoryGroup);
      }
    }
    this.filteredGroups = out;
  }

    build() {
    // 标题栏交给 GlassPage（落在 Navigation 标题栏里 —— HarmonyOS 7 之后
    // 只有这块区域 + 弹窗类还在沉浸光感的生效范围内）。
    GlassPage({ title: '历史', scrollers: [this.listScroller], onBack: (): void => { this.onBack(); } }) {
    Column() {
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
        Scroll(this.listScroller) {
          Column() {
            Row({ space: 8 }) {
              Image($r('app.media.chromium_search'))
                .width(16)
                .height(16)
                .fillColor($r('app.color.icon_secondary'))
              TextInput({ text: this.searchText, placeholder: '搜索历史记录' })
                .layoutWeight(1)
                .height(38)
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .placeholderColor($r('app.color.text_secondary'))
                .backgroundColor(Color.Transparent)
                .onChange((value: string) => {
                  this.searchText = value;
                  this.recomputeFiltered();
                })
            }
            .width('100%')
            .height(40)
            .borderRadius(20)
            .backgroundColor($r('app.color.surface_secondary'))
            .padding({ left: 12, right: 12 })
            .margin({ bottom: 10 })

            if (this.filteredGroups.length === 0) {
              Text('没有匹配的历史记录')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .margin({ top: 40 })
            }
            ForEach(this.filteredGroups, (group: HistoryGroup, index: number) => {
              AuraSectionLabel({ text: group.label, tightTop: index === 0 })
              Column() {
                ForEach(group.items, (item: HistoryItem, index: number) => {
                  this.HistoryRow(item, index === group.items.length - 1)
                }, (item: HistoryItem): string => `${item.url}|${item.visitTime}`)
              }
              .width('100%')
              .borderRadius(16)
              .backgroundColor($r('app.color.card_background'))
              .clip(true)
            // 键里带上条数：过滤后同组标签（如"今天"）条数变化时键不同，
            // 强制 itemGenerator 重跑——否则 ForEach 复用旧组节点，看起来"搜索无效"。
            }, (group: HistoryGroup): string => `${group.label}#${group.items.length}`)
          }
          .width('100%')
          // 大标题带：滚动内容穿过「历史」大标题时逐渐虚化（见 GlassPage 文件头）。
          .padding({ top: glassHeaderInsetVp() })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.page_background'))
    }
  }
}
