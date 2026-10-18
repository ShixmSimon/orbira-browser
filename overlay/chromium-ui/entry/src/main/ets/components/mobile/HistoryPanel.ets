/*
 * 手机自绘历史页：卡片式列表，按天分组（今天 / 昨天 /
 * 月日 / 年月日）。
 * 数据流：queryHistory -> historyResults 事件（AuraShell 转存到
 * 'auraPanelHistory'）；删除或别处变化后引擎推 historyChanged
 * （转存到 'auraPanelEvent'），本页据此重拉。
 */
import { BrowserCommandPayload, HistoryItem, HistoryVisitRef } from 'engine';
import { displayUrl, dayGroupLabel, formatClock } from './PanelBridge';
import { AuraSectionLabel, AuraSiteIcon, AuraSearchBar } from './AuraKit';
import { requestFavicons, ingestFavicons, snapshotFavicons, faviconData } from './FaviconKit';
import { GlassPage, glassBottomInsetVp, glassHeaderInsetVp, glassTopSafeVp } from './GlassPage';
import { promptAction, curves } from '@kit.ArkUI';
import { MoreMenuDialog, MoreMenuItemSpec } from './MoreMenuDialog';

interface HistoryGroup {
  label: string;
  items: HistoryItem[];
}

interface PanelEventPayload {
  kind?: string;
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
  // 搜索框随列表滚走后，标题栏右侧（⋯ 菜单旁）浮现搜索按钮（点它回顶 + 聚焦）。
  @State private searchFabVisible: boolean = false;
  // 站点图标：引擎回包统一落 'auraFavicons'（AuraShell 转存），各页只从该键读取。
  @StorageLink('auraFavicons') @Watch('onFaviconsChanged') faviconsJson: string = '';
  @State private faviconMap: Map<string, string> = new Map();

  // 搜索框滚走后，点标题栏搜索按钮平滑回顶并聚焦搜索框。
  // 聚焦必须延迟到回顶动画结束之后：requestFocus 唤起输入法会触发重布局，
  // 打断进行中的回顶弹簧动画 —— 实测列表停在半路，搜索框压在视口上方露不出来。
  private scrollToSearch(): void {
    this.listScroller.scrollTo({
      xOffset: 0,
      yOffset: 0,
      animation: { duration: 320, curve: curves.springMotion(0.34, 0.84) }
    });
    setTimeout((): void => {
      this.getUIContext().getFocusController().requestFocus('history_search_input');
    }, 480);
  }
  // 过滤结果落 @State：build 里 ForEach/if 经方法间接读 @State 不会建立更新依赖
  //（编译器不分析方法体），搜索词变化时列表不刷新——显式重算才能驱动更新。
  @State private filteredGroups: HistoryGroup[] = [];
  private requestSeq: number = 0;
  private retryTimer: number = -1;

  // 批量管理：选择模式 + 已选历史项（以 url|visitTime 为 key）。
  @State private selectMode: boolean = false;
  @State private selectedHistoryKeys: string[] = [];
  // ⋯ 菜单项（原地 mutate，让「多选」按需出现）。
  private moreItems: MoreMenuItemSpec[] = [];

  aboutToAppear(): void {
    // Seed from storage first: a @StorageLink does not fire @Watch for its
    // initial value, and a byte-identical engine reply raises no change
    // either, so a re-opened panel would otherwise stay on "loading".
    // 站点图标同理：先吃一次已有回包，否则首帧全是占位色块。
    this.onFaviconsChanged();
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
      this.requestHistoryFavicons();
    } catch (error) {
      this.loading = false;
    }
  }

  // 'auraFavicons' 更新（含其它页触发的回包）：并进累积缓存后取整份快照，
  // 赋新对象触发重绘。@StorageLink 的初值不触发 @Watch，故 aboutToAppear 也调一次。
  private onFaviconsChanged(): void {
    ingestFavicons(this.faviconsJson);
    this.faviconMap = snapshotFavicons();
    // 回包可能只覆盖一部分 url（引擎只回命中的）：把还缺的补问一次。
    // Kit 内部按 url 记次数（≤3 次）并跳过已命中的，不会死循环。
    this.requestHistoryFavicons();
  }

  // 把当前历史条目的 url 交给共享 FaviconKit 合批请求（去重 + 攒拍）。
  private requestHistoryFavicons(): void {
    const urls: string[] = [];
    for (const item of this.items) {
      if (item.url.length > 0) {
        urls.push(item.url);
      }
    }
    requestFavicons(urls, this.onCommand);
  }

  private onPanelEvent(): void {
    // 只响应历史变化事件，避免书签/偏好等无关面板事件也触发历史重查与引擎往返。
    if (this.panelEventJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.panelEventJson) as PanelEventPayload;
      if (String(payload.kind ?? '') === 'historyChanged') {
        this.reload();
      }
    } catch (error) {
    }
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

  // -- 批量管理 ----------------------------------------------------------------

  private historyKey(item: HistoryItem): string {
    return `${item.url}|${item.visitTime}`;
  }

  private isSelectedHistory(key: string): boolean {
    return this.selectedHistoryKeys.indexOf(key) >= 0;
  }

  private toggleHistory(item: HistoryItem): void {
    const key = this.historyKey(item);
    const idx = this.selectedHistoryKeys.indexOf(key);
    if (idx >= 0) {
      this.selectedHistoryKeys.splice(idx, 1);
    } else {
      this.selectedHistoryKeys.push(key);
    }
    this.selectedHistoryKeys = this.selectedHistoryKeys.slice();
  }

  private allHistoryKeys(): string[] {
    const keys: string[] = [];
    for (const item of this.items) {
      keys.push(this.historyKey(item));
    }
    return keys;
  }

  private enterHistorySelect(): void {
    this.selectedHistoryKeys = [];
    this.selectMode = true;
  }

  private exitHistorySelect(): void {
    this.selectedHistoryKeys = [];
    this.selectMode = false;
  }

  private selectAllHistory(): void {
    this.selectedHistoryKeys = this.allHistoryKeys();
  }

  private batchRemoveHistory(): void {
    if (this.selectedHistoryKeys.length === 0) {
      return;
    }
    const keys = this.selectedHistoryKeys;
    const items = this.items.filter((item: HistoryItem): boolean =>
      keys.indexOf(this.historyKey(item)) >= 0);
    const count = items.length;
    this.getUIContext().getPromptAction().showDialog({
      title: '删除所选',
      message: `确定删除选中的 ${count} 条历史记录吗？`,
      buttons: [
        { text: '取消', color: '#5F6368' },
        { text: '删除', color: '#E24B4A' }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (result.index !== 1) {
        return;
      }
      const payloadItems: HistoryVisitRef[] = items.map(
        (item: HistoryItem): HistoryVisitRef => ({ url: item.url, visitTime: item.visitTime })
      );
      this.onCommand({ command: 'removeHistoryItems', items: payloadItems });
      this.selectedHistoryKeys = [];
      this.selectMode = false;
    }).catch((error: Error): void => {
    });
  }

  private showMoreSheet(): void {
    this.moreItems.length = 0;
    this.moreItems.push(
      {
        icon: $r('app.media.aura_check'),
        label: '多选',
        action: (): void => {
          this.enterHistorySelect();
        }
      }
    );
    this.moreMenuDialog.open();
  }

  private moreMenuDialog: CustomDialogController = new CustomDialogController({
    builder: MoreMenuDialog({
      items: this.moreItems
    }),
    autoCancel: true,
    customStyle: true,
    maskColor: Color.Transparent,
    alignment: DialogAlignment.TopEnd,
    // ⚠️ 用 glassTopSafeVp()（= 状态栏高）而不是 glassHeaderInsetVp()：后者还含
    // 标题行 56 + 渐隐带 16，菜单卡会被推到列表中部（用户反馈「位置异常」）。
    offset: { dx: -12, dy: glassTopSafeVp() + 62 }
  });

  @Builder
  private SelectBoxHistory(key: string) {
    Column() {
      if (this.isSelectedHistory(key)) {
        Image($r('app.media.aura_check'))
          .width(16)
          .height(16)
          .fillColor($r('app.color.on_accent'))
      }
    }
    .width(26)
    .height(26)
    .borderRadius(13)
    .border({ width: 2, color: this.isSelectedHistory(key) ? $r('app.color.accent_primary') : $r('app.color.divider') })
    .backgroundColor(this.isSelectedHistory(key) ? $r('app.color.accent_primary') : Color.Transparent)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private HistoryRow(item: HistoryItem, isLast: boolean) {
    Column() {
      Row({ space: 12 }) {
        if (this.selectMode) {
          this.SelectBoxHistory(this.historyKey(item))
        } else {
          AuraSiteIcon({ url: item.url, iconData: faviconData(item.url, this.faviconMap) })
        }

        Column({ space: 2 }) {
          Text(item.title.length > 0 ? item.title : displayUrl(item.url))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text(displayUrl(item.url))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (!this.selectMode) {
          // 右侧只留时刻（HH:MM）：分组标签已经写明「今天/昨天/日期」，重复日期没意义。
          Text(formatClock(item.visitTime))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
        }
      }
      .width('100%')
      .constraintSize({ minHeight: 60 })
      .padding({ left: 16, right: 6, top: 8, bottom: 8 })
      .onClick(() => {
        if (this.selectMode) {
          this.toggleHistory(item);
        } else {
          this.openItem(item);
        }
      })

      if (!isLast) {
        Divider()
          .color($r('app.color.divider'))
          .margin({ left: 50 })
      }
    }
    .width('100%')
  }

  @Builder
  private HistoryGroupHeader(label: string, tightTop: boolean) {
    AuraSectionLabel({ text: label, tightTop: tightTop })
  }

  // 左滑删除：end 动作（从右往左滑，右侧露出红色删除）。多选态返回空，避免误删。
  @Builder
  private HistoryDeleteBuilder(item: HistoryItem) {
    if (!this.selectMode) {
      Button({ type: ButtonType.Circle }) {
        Image($r('app.media.aura_trash'))
          .width(20)
          .height(20)
          .fillColor($r('app.color.on_accent'))
      }
      .width(48)
      .height(48)
      .backgroundColor($r('app.color.danger'))
      .margin({ right: 16 })
      .onClick((): void => {
        this.removeItem(item);
      })
    }
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

  // 悬浮批量操作条：绝对定位于 body Stack 底部，自绘仿玻璃药丸（float_bar_bg +
  // 细描边 + 投影）。**宽度随内容走**：外层全宽 Row 只负责底部定位与水平居中，
  // 自身透明且透传点击；内层 Scroll 不设 minWidth，只约束 maxWidth 100%，
  // 只有一个「全选」时就是一小颗药丸，四周/下方露出列表与页面底色，不会被拉成
  // 横贯屏幕的白色长条。选中后出现「删除」，药丸随之变长，横向 Scroll 兜底。
  @Builder
  private BatchActionBar() {
    if (this.selectMode) {
      Stack({ alignContent: Alignment.Center }) {
        Scroll() {
          Row({ space: 8 }) {
            Row({ space: 6 }) {
              Image($r('app.media.aura_check'))
                .width(16)
                .height(16)
                .fillColor($r('app.color.accent_primary'))
              Text('全选')
                .fontSize(14)
                .fontColor($r('app.color.accent_primary'))
            }
            .height(36)
            .padding({ left: 16, right: 16 })
            .borderRadius(18)
            .onClick(() => {
              this.selectAllHistory();
            })

            if (this.selectedHistoryKeys.length > 0) {
              Row({ space: 6 }) {
                Image($r('app.media.aura_trash'))
                  .width(16)
                  .height(16)
                  .fillColor($r('app.color.danger'))
                Text(`删除 (${this.selectedHistoryKeys.length})`)
                  .fontSize(14)
                  .fontColor($r('app.color.danger'))
              }
              .height(36)
              .padding({ left: 16, right: 16 })
              .borderRadius(18)
              .onClick(() => {
                this.batchRemoveHistory();
              })
            }
          }
          .justifyContent(FlexAlign.Center)
          .padding({ left: 8, right: 8 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .constraintSize({ maxWidth: '100%' })
        .clip(true)
        .backgroundColor($r('app.color.float_bar_bg'))
        // 不用 backgroundBlurStyle(Thin)：系统 Thin 材质会再叠一层白，实测把 60%
        // 白色药丸渲染成不透明纯白（254,254,254），用户看到的就是"不透"。
        .border({ width: 0.5, color: $r('app.color.divider') })
        .borderRadius(23)
        .shadow({ radius: 18, color: $r('app.color.shadow'), offsetY: 6 })
        .padding({ top: 5, bottom: 5 })
      }
      .width('100%')
      .position({ bottom: glassBottomInsetVp() })
      .hitTestBehavior(HitTestMode.Transparent)
    }
  }

    build() {
    // 标题栏交给 GlassPage（落在 Navigation 标题栏里 —— HarmonyOS 7 之后
    // 只有这块区域 + 弹窗类还在沉浸光感的生效范围内）。
    GlassPage({
      title: this.selectMode ? `已选 ${this.selectedHistoryKeys.length} 项` : '历史',
      scrollers: [this.listScroller],
      menus: {
        value: this.selectMode
          ? [
            {
              content: {
                icon: $r('app.media.aura_close'),
                label: '取消',
                action: (): void => {
                  this.exitHistorySelect();
                }
              }
            }
          ]
          : (this.searchFabVisible
            ? [
              {
                content: {
                  icon: $r('app.media.chromium_search'),
                  label: '回到搜索',
                  action: (): void => {
                    this.scrollToSearch();
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
            : [
              {
                content: {
                  icon: $r('app.media.aura_more'),
                  label: '更多操作',
                  action: (): void => {
                    this.showMoreSheet();
                  }
                }
              }
            ])
      },
      onBack: (): void => {
        // 选择态下返回键先退出多选，别直接退页面。
        if (this.selectMode) {
          this.exitHistorySelect();
          return;
        }
        this.onBack();
      }
    }) {
    Stack({ alignContent: Alignment.TopStart }) {
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
        List({ scroller: this.listScroller }) {
          // 顶部占位：glassHeaderInsetVp() 的空白必须做成**滚动内容里的占位 Item**，
          // 绝不能写成 List 本体的 .padding——那样会把滚动视口整体压到标题行下方，
          // 内容永远进不了标题行区域，顶部渐变模糊（GRADIENT_BLUR）就不会出现。
          ListItem() {
            Row().width('100%').height(glassHeaderInsetVp())
          }
          .height(glassHeaderInsetVp())
          .selectable(false)

          ListItem() {
            AuraSearchBar({
              placeholder: '搜索历史记录',
              text: this.searchText,
              showClear: true,
              inputId: 'history_search_input',
              onInput: (value: string): void => {
                this.searchText = value;
                this.recomputeFiltered();
              },
              onClear: (): void => {
                this.searchText = '';
                this.recomputeFiltered();
              }
            })
          }
          .margin({ bottom: 10 })

          if (this.filteredGroups.length === 0) {
            ListItem() {
              Text('没有匹配的历史记录')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .margin({ top: 40 })
            }
          }

          // 每组一个浮框卡片（ListItemGroup 带卡片底色 + 圆角 + 裁切），
          // 组内每条记录是独立 ListItem，可左滑删除。
          ForEach(this.filteredGroups, (group: HistoryGroup, index: number) => {
            ListItemGroup({ header: (): void => { this.HistoryGroupHeader(group.label, index === 0); } }) {
              ForEach(group.items, (item: HistoryItem, index: number) => {
                ListItem() {
                  this.HistoryRow(item, index === group.items.length - 1)
                }
                .swipeAction({ end: (): void => { this.HistoryDeleteBuilder(item); } })
              }, (item: HistoryItem): string => `${item.url}|${item.visitTime}`)
            }
            .borderRadius(16)
            .backgroundColor($r('app.color.card_background'))
            .clip(true)
            .margin({ bottom: 10 })
          }, (group: HistoryGroup): string => `${group.label}#${group.items.length}`)

          // 底部占位同理：多选操作条悬浮在内容之上，末条要留出空间不被压住。
          if (this.selectMode) {
            ListItem() {
              Row().width('100%').height(50 + glassBottomInsetVp())
            }
            .height(50 + glassBottomInsetVp())
            .selectable(false)
          }
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .align(Alignment.TopStart)
        .onDidScroll(() => {
          // 搜索框随列表滚走后，标题栏右侧浮现搜索按钮（点它回顶 + 聚焦）。
          const off = this.listScroller.currentOffset().yOffset;
          const show = off > glassHeaderInsetVp() + 20;
          if (show !== this.searchFabVisible) {
            this.searchFabVisible = show;
          }
        })
      }

      // 批量操作条改为悬浮胶囊（见 BatchActionBar()，挂 body Stack，不占流式高度）。
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.page_background'))

    this.BatchActionBar()
    }
    .width('100%')
    .height('100%')
    }
  }
}
