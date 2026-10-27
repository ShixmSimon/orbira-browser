/*
 * 资源嗅探面板（手机）：列出当前页面被引擎自动识别出的媒体 / 图片等资源。
 * 数据流：进入页 → listResources 命令（带当前 tabId）；引擎回 resourceList
 * （AuraShell 转存到 'auraPanelResourceList'）；页面继续加载时引擎广播
 * resourcesChanged（AuraShell bump 'auraPanelResourceTick'），本页重拉。
 * 动作：downloadResource / clearResources（带 tabId + navigationId 防伪，
 * 避免对一个已跳转/重载的页面误下）；HLS / DASH 清单不可直下，只提供复制链接。
 * 引擎侧实现见 chrome/browser/ohos/resource_collector.cc（拦截 media/image
 * 子资源 GET 请求并归类，命令 listResources/downloadResource/clearResources）。
 */
import { BrowserCommandPayload } from 'engine';
import { pasteboard } from '@kit.BasicServicesKit';
import { GlassPage, glassHeaderInsetVp } from './GlassPage';

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

// 分类：音视频 = 视频 / 音频 / 两种流媒体清单；图片；其余归"文件"。
const CAT_ALL: string = 'all';
const CAT_AV: string = 'av';
const CAT_IMAGE: string = 'image';
const CAT_FILE: string = 'file';

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
    case 'hls': return 'HLS 清单';
    case 'dash': return 'DASH 清单';
    default: return kind;
  }
}

function categoryOf(item: ResourceItem): string {
  if (item.kind === 'image') {
    return CAT_IMAGE;
  }
  if (item.kind === 'video' || item.kind === 'audio' ||
    item.kind === 'hls' || item.kind === 'dash') {
    return CAT_AV;
  }
  return CAT_FILE;
}

// 从 URL 里取主机名（不引 @kit.ArkTS 的 url 模块，避免多一层异常处理）。
function hostOf(raw: string): string {
  let text: string = raw;
  const scheme: number = text.indexOf('://');
  if (scheme >= 0) {
    text = text.substring(scheme + 3);
  }
  const slash: number = text.indexOf('/');
  if (slash >= 0) {
    text = text.substring(0, slash);
  }
  const query: number = text.indexOf('?');
  if (query >= 0) {
    text = text.substring(0, query);
  }
  return text;
}

// 没有名字的资源用 URL 最后一段兜底（去掉查询串），比整条 URL 好看。
function fileNameOf(item: ResourceItem): string {
  if (item.name.length > 0) {
    return item.name;
  }
  let text: string = item.url;
  const query: number = text.indexOf('?');
  if (query >= 0) {
    text = text.substring(0, query);
  }
  const slash: number = text.lastIndexOf('/');
  if (slash >= 0 && slash < text.length - 1) {
    text = text.substring(slash + 1);
  }
  return text.length > 0 ? text : item.url;
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
  @State private activeCat: string = CAT_ALL;
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
      this.showToast(message);
      if (ok) {
        setTimeout((): void => { this.reload(); }, 600);
      }
    } catch (error) {
    }
  }

  private showToast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
  }

  private countIn(cat: string): number {
    if (cat === CAT_ALL) {
      return this.items.length;
    }
    let count: number = 0;
    for (const item of this.items) {
      if (categoryOf(item) === cat) {
        count += 1;
      }
    }
    return count;
  }

  private visibleItems(): ResourceItem[] {
    if (this.activeCat === CAT_ALL) {
      return this.items;
    }
    const shown: ResourceItem[] = [];
    for (const item of this.items) {
      if (categoryOf(item) === this.activeCat) {
        shown.push(item);
      }
    }
    return shown;
  }

  private metaLine(item: ResourceItem): string {
    const parts: string[] = [kindLabel(item.kind)];
    const size: string = formatBytes(item.totalBytes);
    if (size.length > 0) {
      parts.push(size);
    }
    const host: string = hostOf(item.url);
    if (host.length > 0) {
      parts.push(host);
    }
    return parts.join(' · ');
  }

  private copyLink(item: ResourceItem): void {
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, item.url);
      pasteboard.getSystemPasteboard().setData(data).then((): void => {
        this.showToast('链接已复制');
      }).catch((): void => {
        this.showToast('复制失败');
      });
    } catch (error) {
      this.showToast('复制失败');
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
    if (this.navigationId.length === 0 || this.items.length === 0) {
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

  // 按类型换图标（原来一律用地球图标，分不出音视频/图片/清单）。
  @Builder
  private KindIcon(kind: string) {
    if (kind === 'video') {
      Image($r('app.media.aura_res_video')).width(20).height(20).fillColor('#E8663D')
    } else if (kind === 'audio') {
      Image($r('app.media.aura_res_audio')).width(20).height(20).fillColor('#9B6BDF')
    } else if (kind === 'image') {
      Image($r('app.media.aura_res_image')).width(20).height(20).fillColor('#2FA36B')
    } else if (kind === 'hls' || kind === 'dash') {
      Image($r('app.media.aura_res_stream')).width(20).height(20).fillColor('#E0A32E')
    } else {
      Image($r('app.media.aura_res_file')).width(20).height(20)
        .fillColor($r('app.color.icon_secondary'))
    }
  }

  @Builder
  private CategoryTab(cat: string, label: string) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text(label)
          .fontSize(15)
          .fontWeight(this.activeCat === cat ? FontWeight.Medium : FontWeight.Regular)
          .fontColor(this.activeCat === cat ?
            $r('app.color.accent_primary') : $r('app.color.text_primary'))
        Text(`${this.countIn(cat)}`)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
      }
      .height(24)

      Column()
        .width(18)
        .height(3)
        .borderRadius(2)
        .backgroundColor(this.activeCat === cat ?
          $r('app.color.accent_primary') : Color.Transparent)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
    .onClick((): void => {
      this.activeCat = cat;
    })
  }

  // 注意：@Builder 的**按值参数不会随状态刷新**（挂载时算一次就定住）。
  // 「全部 N」的 N 必须在 builder 内部读 state 算，不能当字符串参数传进来
  // ——之前传进来，列表加载完了它还停在「全部 0」。
  private chipLabel(id: string): string {
    if (id === CAT_ALL) {
      return `全部 ${this.items.length}`;
    }
    if (id === 'refresh') {
      return '刷新';
    }
    return '清空列表';
  }

  @Builder
  private FilterChip(id: string) {
    Text(this.chipLabel(id))
      .fontSize(13)
      .fontColor(this.activeCat === CAT_ALL && id === CAT_ALL ?
        $r('app.color.on_accent') : $r('app.color.text_primary'))
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor(this.activeCat === CAT_ALL && id === CAT_ALL ?
        $r('app.color.accent_primary') : $r('app.color.surface_secondary'))
      .onClick((): void => {
        if (id === CAT_ALL) {
          this.activeCat = CAT_ALL;
        } else if (id === 'refresh') {
          this.reload();
        } else if (id === 'clear') {
          this.clearAll();
        }
      })
  }

  @Builder
  private ActionText(label: string, onTap: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor($r('app.color.accent_primary'))
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .borderRadius(14)
      .backgroundColor($r('app.color.surface_secondary'))
      .onClick((): void => {
        onTap();
      })
  }

  @Builder
  private ResourceCard(item: ResourceItem) {
    Column() {
      Row({ space: 10 }) {
        this.KindIcon(item.kind)
        Column({ space: 2 }) {
          Text(fileNameOf(item))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.metaLine(item))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Text(item.url)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 8 })

      Row({ space: 8 }) {
        this.ActionText('复制链接', (): void => this.copyLink(item))
        if (item.downloadable) {
          this.ActionText('下载', (): void => this.download(item))
        }
      }
      .width('100%')
      .margin({ top: 10 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .borderRadius(16)
    .backgroundColor($r('app.color.card_background'))
    .margin({ bottom: 10 })
  }

  build() {
    GlassPage({
      title: '资源嗅探',
      scrollers: [this.listScroller],
      onBack: (): void => { this.onBack(); }
    }) {
      Column() {
        Scroll(this.listScroller) {
          Column() {
            // 分类 + 动作 chip 都在滚动内容里，靠 glassHeaderInsetVp 让开状态栏
            // （原来这一行在 Scroll 外，没吃到内距 → 压到状态栏上）。
            Row() {
              this.CategoryTab(CAT_AV, '音视频')
              this.CategoryTab(CAT_IMAGE, '图片')
              this.CategoryTab(CAT_FILE, '文件')
            }
            .width('100%')
            .padding({ left: 4, right: 4 })
            .margin({ bottom: 10 })

            Row({ space: 8 }) {
              this.FilterChip(CAT_ALL)
              this.FilterChip('refresh')
              this.FilterChip('clear')
            }
            .width('100%')
            .margin({ bottom: 10 })

            Text('记录当前页面已请求的资源。清单仅支持复制链接，暂不合并流媒体分片。')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .margin({ bottom: 10 })

            if (this.truncated) {
              Text('列表较长，已截断显示最新的一部分。')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .margin({ bottom: 10 })
            }

            if (this.visibleItems().length === 0) {
              Column() {
                Text(this.loading ? '正在嗅探当前页面的资源…' :
                  (this.items.length === 0 ? '本页面暂未发现资源' : '该分类下暂无资源'))
                  .fontSize(15)
                  .fontColor($r('app.color.text_secondary'))
              }
              .width('100%')
              .padding({ top: 60 })
              .justifyContent(FlexAlign.Center)
            } else {
              ForEach(this.visibleItems(), (item: ResourceItem) => {
                this.ResourceCard(item)
              }, (item: ResourceItem): string =>
                `${item.id}|${this.activeCat}|${item.totalBytes}|${item.downloadable ? 1 : 0}`)
            }

            Text('HLS / DASH 等流媒体清单（m3u8 / mpd）不能直接下载，请复制链接到播放器使用。')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ top: 2, bottom: 8 })
          }
          .width('100%')
          .padding({ top: glassHeaderInsetVp() })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .align(Alignment.TopStart)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16 })
      .backgroundColor($r('app.color.page_background'))
    }
  }
}
