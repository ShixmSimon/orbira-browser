/*
 * 资源嗅探面板（手机）：列出当前页面被引擎自动识别出的媒体 / 图片等资源，
 * 支持逐个下载与一键清空。
 * 数据流：进入页 → listResources 命令（带当前 tabId）；引擎回 resourceList
 * （AuraShell 转存到 'auraPanelResourceList'）；页面继续加载时引擎广播
 * resourcesChanged（AuraShell bump 'auraPanelResourceTick'），本页重拉。
 * 动作：downloadResource / clearResources（带 tabId + navigationId 防伪，
 * 避免对一个已跳转/重载的页面误下）。
 * 引擎侧实现见 chrome/browser/ohos/resource_collector.cc（拦截 media/image
 * 子资源 GET 请求并归类，命令 listResources/downloadResource/clearResources）。
 */
import router from '@ohos.router';
import { BrowserCommandPayload } from 'engine';
import { GlassPage, glassHeaderInsetVp } from './GlassPage';
import { curves } from '@kit.ArkUI';

interface ResourceItem {
  id: string;
  kind: string;
  name: string;
  url: string;
  mimeType: string;
  totalBytes: number;
  downloadable: boolean;
}

interface ResourceListPayload {
  ok?: boolean;
  tabId?: string;
  navigationId?: string;
  protocolVersion?: number;
  truncated?: boolean;
  resources?: ResourceItem[];
}

interface ResourceActionPayload {
  event?: string;
  ok?: boolean;
  reason?: string;
  navigationId?: string;
}

function formatBytes(bytes: number): string {
  if (bytes <= 0) {
    return '';
  }
  const units: string[] = ['B', 'KB', 'MB', 'GB'];
  let value: number = bytes;
  let unit: number = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value = value / 1024;
    unit += 1;
  }
  if (unit === 0) {
    return `${Math.round(value)} ${units[unit]}`;
  }
  return `${value.toFixed(1)} ${units[unit]}`;
}

function kindLabel(kind: string): string {
  switch (kind) {
    case 'video': return '视频';
    case 'audio': return '音频';
    case 'image': return '图片';
    case 'hls': return 'HLS 流';
    case 'dash': return 'DASH 流';
    default: return kind;
  }
}

@Component
export struct ResourceSniffPanel {
  @StorageLink('auraPanelResourceList') @Watch('onResourceList') resourceListJson: string = '';
  @StorageLink('auraPanelResourceTick') @Watch('onResourceTick') resourceTick: number = 0;
  @StorageLink('auraPanelEvent') @Watch('onPanelEvent') panelEventJson: string = '';
  @StorageLink('auraActiveTabId') activeTabId: string = '';
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  onBack: () => void = (): void => {};
  onClose: () => void = (): void => {};

  @State private items: ResourceItem[] = [];
  @State private navigationId: string = '';
  @State private truncated: boolean = false;
  @State private loading: boolean = true;
  private listScroller: Scroller = new Scroller();
  private requestSeq: number = 0;
  private lastReloadAt: number = 0;
  private retryTimer: number = -1;

  aboutToAppear(): void {
    // 先吃一份存储里的旧值：@StorageLink 初始值不触发 @Watch，若引擎回包字节
    // 完全一致也无变化事件，重开的面板会一直停在加载态。
    this.onResourceList();
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
    if (this.activeTabId.length === 0) {
      return;
    }
    this.loading = true;
    this.requestSeq += 1;
    this.lastReloadAt = Date.now();
    this.onCommand({ command: 'listResources', requestId: this.requestSeq, tabId: this.activeTabId });
  }

  private onResourceList(): void {
    if (this.resourceListJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.resourceListJson) as ResourceListPayload;
      if (payload.ok === false) {
        this.loading = false;
        return;
      }
      this.items = payload.resources ?? [];
      this.navigationId = payload.navigationId ?? '';
      this.truncated = payload.truncated === true;
      this.loading = false;
    } catch (error) {
      this.loading = false;
    }
  }

  // 页面继续加载时引擎广播 resourcesChanged（不含列表，只通知有变化）。
  // 节流后重拉一次即可，避免每秒多次刷新。
  private onResourceTick(): void {
    if (this.activeTabId.length === 0) {
      return;
    }
    if (Date.now() - this.lastReloadAt < 1200) {
      return;
    }
    this.reload();
  }

  private onPanelEvent(): void {
    if (this.panelEventJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.panelEventJson) as ResourceActionPayload;
      if (payload.event !== 'resourceActionResult') {
        return;
      }
      const ok = payload.ok === true;
      let message = '已开始下载';
      if (!ok) {
        message = payload.reason === 'staleResource' ? '资源已失效，请重新嗅探' :
          payload.reason === 'manifestOnly' ? '该清单 / 流媒体无法直接下载' :
          payload.reason === 'staleDocument' ? '页面已跳转，请重新打开' : '操作失败';
      }
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
      if (ok) {
        setTimeout((): void => { this.reload(); }, 600);
      }
    } catch (error) {
    }
  }

  private download(item: ResourceItem): void {
    if (!item.downloadable || this.navigationId.length === 0) {
      return;
    }
    this.requestSeq += 1;
    this.onCommand({
      command: 'downloadResource',
      requestId: this.requestSeq,
      tabId: this.activeTabId,
      navigationId: this.navigationId,
      id: item.id
    });
  }

  private clearAll(): void {
    if (this.navigationId.length === 0) {
      return;
    }
    this.requestSeq += 1;
    this.onCommand({
      command: 'clearResources',
      requestId: this.requestSeq,
      tabId: this.activeTabId,
      navigationId: this.navigationId
    });
    setTimeout((): void => { this.reload(); }, 400);
  }

  @Builder
  private ResourceRow(item: ResourceItem, index: number) {
    Column() {
      Row({ space: 12 }) {
        Image($r('app.media.aura_globe'))
          .width(22)
          .height(22)
          .fillColor($r('app.color.icon_primary'))

        Column({ space: 2 }) {
          Text(item.name.length > 0 ? item.name : item.url)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Row({ space: 8 }) {
            Text(kindLabel(item.kind))
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
            if (item.totalBytes > 0) {
              Text(formatBytes(item.totalBytes))
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
          }
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (item.downloadable) {
          Text('下载')
            .fontSize(13)
            .fontColor($r('app.color.accent_primary'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(8)
            .backgroundColor($r('app.color.surface_secondary'))
            .onClick((): void => this.download(item))
        } else {
          Text('流媒体')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 12, bottom: 12 })

      if (index < this.items.length - 1) {
        Divider()
          .color($r('app.color.divider'))
          .margin({ left: 50 })
      }
    }
    .width('100%')
  }

  build() {
    GlassPage({
      title: '资源嗅探',
      scrollers: [this.listScroller],
      onBack: (): void => { this.onBack(); }
    }) {
      Column() {
        if (this.items.length > 0) {
          Row() {
            Text(`共 ${this.items.length} 项`)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
            Blank()
            Text('清空')
              .fontSize(13)
              .fontColor($r('app.color.danger'))
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(8)
              .backgroundColor($r('app.color.surface_secondary'))
              .onClick((): void => this.clearAll())
          }
          .width('100%')
          .padding({ left: 4, right: 4, bottom: 8 })
        }

        if (this.items.length === 0) {
          Column() {
            Text(this.loading ? '正在嗅探当前页面的资源…' : '本页面暂未发现可下载的资源')
              .fontSize(15)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll(this.listScroller) {
            Column() {
              if (this.truncated) {
                Text('列表较长，已截断显示最新的一部分。')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                  .padding({ left: 4, right: 4, top: 4, bottom: 8 })
              }
              Column() {
                ForEach(this.items, (item: ResourceItem, index: number) => {
                  this.ResourceRow(item, index)
                }, (item: ResourceItem): string => item.id)
              }
              .width('100%')
              .borderRadius(16)
              .backgroundColor($r('app.color.card_background'))
              .clip(true)

              Text('点击「下载」交给系统下载；HLS / DASH 等流媒体清单无法直接下载。')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .padding({ left: 4, right: 4, top: 10 })
            }
            .width('100%')
            .padding({ top: glassHeaderInsetVp() })
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
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
