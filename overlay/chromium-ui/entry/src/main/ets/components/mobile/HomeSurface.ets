/*
 * 手机主页（新标签页覆盖层）v2 —— 1.0.79 主页改造。
 *
 * 17.1 快捷方式 → 书签：磁贴数据源改为书签树里「首页」文件夹（手机书签根下）。
 *   进入时自动发现该文件夹（缺失即创建）；老的手动快捷方式一次性迁入；
 *   添加/编辑/删除都走书签命令（addBookmark / updateBookmark / removeBookmarks）。
 * 17.2 主页布局（原「主页设置」，1.0.88 改名）：右上角齿轮 → 背景图上传（照片选择器 → 拷进沙箱）、
 *   Logo·搜索框·书签区 的上下位移与显隐（preferences 持久化，HomePrefs）。
 *
 * 请求通道说明：getBookmarks 回包经 AuraShell 落 'auraPanelBookmarkList'，
 * 书签面板共用同一存储 —— 主页用 700000 起的独立序号段 + 父层校验过滤自己的
 * 回包；面板在别处操作书签会发 bookmarkCreated/bookmarksChanged（'auraPanelEvent'），
 * 主页借此刷新磁贴。
 */
import { AutocompleteItem, BookmarkNode, BrowserCommandPayload, FaviconImage } from 'engine';
import { common } from '@kit.AbilityKit';
import { promptAction, display, curves } from '@kit.ArkUI';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { normalizeAddress } from './ShellUtils';
import { ScanService } from './ScanService';
import { HomeShortcut, HomeShortcuts } from '../../utils/appearance/HomeShortcuts';
import { HomeCustom, HomePrefs, defaultHomeCustom } from '../../utils/appearance/HomePrefs';
import { HomeCache, HomeCacheData } from '../../utils/appearance/HomeCache';

// 书签「首页」文件夹的标题（同时作为目录名使用）。
const HOME_FOLDER_TITLE: string = '首页';
// 主页的请求序号段（书签面板从 0 起；以此区分谁的回包）。
const HOME_SEQ_BASE: number = 700000;
// 主页搜索框联想的序号段（与书签段、面板段都错开，回包只认自己这一段）。
const HOME_SUGGEST_SEQ_BASE: number = 950000;
// 主页序号在这段里循环（[700000, 900000)），始终高于书签面板的 600000 上限。
const HOME_SEQ_SPAN: number = 200000;
// 模块级序号抬升：每次挂载 +1000（同 BookmarksPanel 的 panelSeqBump）。
// 原因：AppStorage.setOrCreate 存的是 JSON 字符串，**内容完全相同就不算变化
// → @Watch 不触发**。主页每次按主页键都会销毁重建，homeSeq 若从 700000 重来，
// 请求号与上一轮撞车 → 回包 JSON 与上次逐字节相同 → 引擎回了包但主页收不到，
// 磁贴一直空着，要等 1.6s 超时重试才补上（表现为「书签不显示/延迟出现」）。
let homeSeqBump: number = HOME_SEQ_BASE;
// 发现链 / 磁贴刷新的兜底时间。
const CHAIN_TIMEOUT_MS: number = 1600;
const REFRESH_DEBOUNCE_MS: number = 260;
const MAX_CHAIN_RETRIES: number = 3;
// 长按菜单卡宽度（与 ⋮ 卡/网页长按卡同一家族）。
const MENU_CARD_VP: number = 190;
const MENU_CARD_H: number = 204;
// 页面顶部常驻工具条的占高（vp）：简约风格是「主页 / 标签数 / ⋮」，Chrome
// 风格是上置 dock。真机 dump 到该行 168px ≈ 56vp。主页内容不能落进这条带里。
const TOP_CHROME_EXTENT_VP: number = 56;
// 磁贴底板边长（vp）。底板是磁贴的「托盘」，图标画在它里面。
const TILE_ICON_VP: number = 46;
// 磁贴底板圆角（约边长 28%，与原 54/15 的比例一致）。
const TILE_ICON_RADIUS: number = 13;
// favicon 在底板里的**绘制**边长（vp）。这是「图标糊」的根治点：
// 引擎按 sizeVp×deviceScaleFactor 生成 PNG（overlay/chrome/browser/ui/ohos/
// shell_favicons_ohos.cc: size_px = clamp(sizeVp) × PrimaryDisplayScale()），
// 站点只给 16/32px 的 favicon 时会被拉大 —— 画得越大越糊（46vp 满铺 =
// 138px，实测发虚）。24vp 又太小：磁贴里只剩中间一小块，和「没有图标时
// 铺满底板的字母」完全不是一个观感（用户实拍对比）。
// 1.0.4：36 → 30（用户定稿，磁贴里更收敛一点，仍远低于 46 的糊边门槛）。
const TILE_FAVICON_VP: number = 30;
// 底板里 favicon 的圆角（按边长约 25% 收）。
const TILE_FAVICON_RADIUS: number = 8;
// 向引擎请求的尺寸（vp）= 绘制尺寸 × 2：站点声明了 touch / web-manifest 大图
// 时能拿到真像素再**缩着画**（Interpolation.High），比放大清楚；没有大图的
// 站点退化为和以前一样的放大，那一档靠上面的小绘制尺寸兜住。
const TILE_FAVICON_REQUEST_VP: number = TILE_FAVICON_VP * 2;
// 冷启动缓存里 favicon base64 的字符上限（≈192KB）。超了就不缓存图标，只留磁贴。
const MAX_CACHE_FAVICONS_CHARS: number = 262144;
// favicon 请求合批窗口（ms）。同一帧里几十个磁贴
// 各自 want() → 攒一拍合成**一次** getFavicons（引擎一次最多 100 个 url，
// 见 shell_favicons_ohos.cc kMaxUrlsPerRequest）。
const FAVICON_BATCH_MS: number = 60;
// 引擎一次 getFavicons 的上限；超过就分片（分片回包会累积进同一个 map）。
const FAVICON_BATCH_MAX: number = 100;
// 无 favicon 时的占位底板配色（Chrome 的 fake favicon 做法：按主机名稳定取色
// + 白字首字母）。比一片灰底字母可分辨得多。
const PLACEHOLDER_TINTS: string[] = [
  '#4285F4', '#0F9D58', '#DB4437', '#F4B400',
  '#7B61FF', '#00897B', '#E8710A', '#546E7A'
];

interface BookmarkListPayload {
  requestId?: number;
  parentId?: string;
  nodes?: BookmarkNode[];
}

interface PanelEventPayload {
  kind?: string;
  revision?: number;
}

// 引擎 autocomplete 回包（与地址栏共用同一条命令与同一个存储键，
// 各按自己的 requestId 过滤）。
interface HomeAutocompletePayload {
  requestId?: number;
  items?: AutocompleteItem[];
  done?: boolean;
}

// 首页默认书签（首次运行时种入「首页」文件夹）。
interface HomeSeedSite {
  title: string;
  url: string;
}

function formatOffset(value: number): string {
  return value > 0 ? `+${value}` : `${value}`;
}

// 默认书签去重用的归一化键：去 scheme / 前导 www. / 尾斜杠 / path，只留主机名。
// 让 https://www.baidu.com、https://baidu.com/、http://baidu.com 视为同一站点。
function seedKey(url: string): string {
  let host = url.trim().toLowerCase();
  const schemeIndex = host.indexOf('://');
  if (schemeIndex >= 0) {
    host = host.substring(schemeIndex + 3);
  }
  const slashIndex = host.indexOf('/');
  if (slashIndex >= 0) {
    host = host.substring(0, slashIndex);
  }
  if (host.startsWith('www.')) {
    host = host.substring(4);
  }
  return host;
}

function initialOf(node: BookmarkNode): string {
  const title = node.title.trim();
  if (title.length > 0) {
    return title.substring(0, 1).toUpperCase();
  }
  const url = (node.url ?? '').trim();
  const schemeIndex = url.indexOf('://');
  const host = schemeIndex >= 0 ? url.substring(schemeIndex + 3) : url;
  return host.length > 0 ? host.substring(0, 1).toUpperCase() : '?';
}

// 主机名（小写）。占位色与 favicon 请求都按它归一 —— 同一站点的不同页面
// 用同一块色板，色块不会随页面跳来跳去。
function hostOf(node: BookmarkNode): string {
  const url = (node.url ?? '').trim();
  const schemeIndex = url.indexOf('://');
  let host = schemeIndex >= 0 ? url.substring(schemeIndex + 3) : url;
  const slash = host.indexOf('/');
  if (slash >= 0) {
    host = host.substring(0, slash);
  }
  return host.toLowerCase();
}

// 无 favicon 的占位底板色：主机名哈希 → 稳定落在 PLACEHOLDER_TINTS 上。
function placeholderTint(node: BookmarkNode): string {
  const host = hostOf(node);
  let hash = 0;
  for (let i = 0; i < host.length; i += 1) {
    hash = (hash * 31 + host.charCodeAt(i)) % 1000003;
  }
  const index = hash % PLACEHOLDER_TINTS.length;
  return PLACEHOLDER_TINTS[index];
}

// 只把 http(s) 交给引擎问图标：chrome:// file:// data: 之类永远没有 favicon，
// 白占一次 requests 的额度（FaviconStore.want() 同样是这道门）。
function isFetchableUrl(url: string): boolean {
  return url.startsWith('http://') || url.startsWith('https://');
}

// 归一化 url：比较书签去重/迁移时跨 "https://x.com" 与 "https://x.com/" 匹配。
function normUrl(url: string): string {
  if (!url || url.length === 0) {
    return url;
  }
  let s = url.trim();
  const idx = s.indexOf('://');
  if (idx >= 0) {
    s = s.substring(0, idx).toLowerCase() + s.substring(idx);
  }
  if (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

// 主页布局弹层的两类行必须走 @Component + @Prop（血泪红线：@Builder 按值传参
// 的动态内容不会刷新 UI —— 1.0.76「设置改完返回主页摘要仍是旧值」的根因）。
@Component
struct HomeSettingToggleRow {
  icon: Resource = $r('app.media.aura_display');
  label: string = '';
  @Prop isOn: boolean = true;
  onToggle: (on: boolean) => void = (_on: boolean): void => {};

  build() {
    Row({ space: 12 }) {
      Image(this.icon)
        .width(20)
        .height(20)
        .fillColor($r('app.color.icon_primary'))
      Text(this.label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .selectedColor($r('app.color.accent_primary'))
        .onChange((on: boolean): void => {
          this.onToggle(on);
        })
    }
    .width('100%')
    .height(46)
  }
}

@Component
struct HomePositionSliderRow {
  label: string = '';
  @Prop posOffset: number = 0;
  min: number = 0;
  max: number = 260;
  onMoved: (value: number, end: boolean) => void = (_value: number, _end: boolean): void => {};

  build() {
    Row({ space: 10 }) {
      Text(this.label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .width(58)
      Slider({ value: this.posOffset, min: this.min, max: this.max, step: 4 })
        .layoutWeight(1)
        .selectedColor($r('app.color.accent_primary'))
        .onChange((value: number, mode: SliderChangeMode): void => {
          const end = mode === SliderChangeMode.End || mode === SliderChangeMode.Click;
          this.onMoved(Math.round(value), end);
        })
      Text(formatOffset(this.posOffset))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width(40)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .height(44)
  }
}

@Component
export struct HomeSurface {
  @StorageLink('auraPanelBookmarkList') @Watch('onBookmarkListChanged') bookmarkListJson: string = '';
  @StorageLink('auraPanelEvent') @Watch('onPanelEvent') panelEventJson: string = '';
  @StorageLink('auraFavicons') @Watch('onFaviconsChanged') faviconsJson: string = '';
  // 主页搜索框联想：与地址栏同一条 autocomplete 通道（存储键 'auraAutocomplete'），
  // 用独立序号段 + requestId 过滤自己的回包，互不串。
  @StorageLink('auraAutocomplete') @Watch('onHomeAutocomplete') autocompleteJson: string = '';
  @State private suggestItems: AutocompleteItem[] = [];
  private suggestPending: number = -1;
  private suggestSeq: number = HOME_SUGGEST_SEQ_BASE;
  private suggestTimer: number = -1;
  // 已经「上过屏」的 requestId：首包判断用（同一轮只立即上屏一次，后续包合并刷）。
  private suggestShownFor: number = -1;
  // 合并刷新的定时器与暂存（避免每个 provider 包都重建整张卡）。
  private suggestFlushTimer: number = -1;
  private suggestQueued: AutocompleteItem[] = [];
  // 无痕会话：主页换成无痕的标题与说明，书签磁贴与主页布局入口都不出现。
  @Prop incognito: boolean = false;
  // 状态栏避让由本组件内部承担：surface_primary 背景能铺满状态栏条带。
  @StorageProp('auraTopSafeVp') topSafeVp: number = 0;
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};

  // -- 磁贴数据（书签「首页」文件夹） ------------------------------------------
  @State private tiles: BookmarkNode[] = [];
  // 文件夹**全量**子节点（含子文件夹）——引擎 moveBookmarks 的 index 是全量
  // 位次，排序换算要用它；磁贴渲染只取其中的 url 节点。
  private fullNodes: BookmarkNode[] = [];
  @State private homeFolderId: string = '';
  // 主页默认书签（谷歌/必应/百度/GitHub）是否已一次性种入「首页」文件夹。
  @State private homeBookmarksSeeded: boolean = false;
  // seeded 标志位是否已从偏好读回来。读回来之前一律不种：书签回包可能先到，
  // 那时 homeBookmarksSeeded 还是 false，会被当成"没种过"而补回用户删掉的站。
  private homeSeedLoaded: boolean = false;
  @State private tilesError: boolean = false;
  // 绘制用的 url → data URL（引擎 PNG 转成的 data URL）。
  @State private favicons: Map<string, string> = new Map();
  // 累积的 url → PNG base64。分片请求会分批回包，这份是**并集**（渲染 map 由它
  // 重建；回包只覆盖自己那一片，不能直接替换）。
  private faviconBase64: Map<string, string> = new Map();
  // 已经问过引擎的 url（含取不到的）。FaviconStore.settled：命中
  // 即不再重复问，避免每次书签刷新都重发同一批请求。
  private faviconAsked: Set<string> = new Set();
  // 本轮等待合批的 url（pending）。
  private faviconQueued: Set<string> = new Set();
  private faviconBatchTimer: number = -1;

  // -- 主页布局 ----------------------------------------------------------------
  @State private custom: HomeCustom = defaultHomeCustom();
  @State private bgUri: string = '';
  @State private showSettings: boolean = false;
  // 1.0.97：仅拖动位置滑块时弹窗才转高透（松手恢复近实底）——拖的时候要能
  // 看见后边主页的实时位置变化，静止时保持可读性。
  @State private layoutDragging: boolean = false;
  // 1.0.91 设置-主页设置「自定义主页布局」经此信号请求打开主页布局弹层。
  @StorageLink('auraOpenHomeLayout') @Watch('onOpenHomeLayout') openHomeLayoutSignal: number = 0;
  // （1.0.111 移除 auraOpenHomeTile 信号：「网址主页」语义纠正为"设置自定义主页
  // 网址"，表单落在 overlay 层，与主页磁贴/书签无关。）

  // -- 添加/编辑书签弹层 --------------------------------------------------------
  @State private showAddBookmark: boolean = false;
  @State private editingId: string = '';
  @State private newBookmarkTitle: string = '';
  @State private newBookmarkUrl: string = '';

  // -- 长按菜单 ----------------------------------------------------------------
  @State private menuTitle: string = '';
  @State private menuId: string = '';
  @State private menuX: number = 0;
  @State private menuY: number = 0;
  private menuPressX: number = 0;
  private menuPressY: number = 0;

  // 右上角齿轮的果冻按压态（与顶栏圆钮同款 hand-rolled jelly；内容区拿不到
  // 系统 interactive 形变，见 MobileBrowserOverlay.handleRoundTouch）。
  @State private pressedGear: boolean = false;

  @State private query: string = '';
  // 窗宽/窗高（vp）：主页所有锚点（Logo 22% / 搜索框 33.5% 窗高等）都基于它们。
  // 必须是 @State + 跟根节点 onAreaChange 更新：只在 aboutToAppear 读一次
  // display 尺寸的话，横竖屏切换后仍按旧值排版 —— 用户实拍「退出全屏转回竖屏后
  // 主页整体位移、logo 显示不全」就是这个（display 尺寸在挂载时是竖屏值）。
  @State private windowW: number = 360;
  @State private windowH: number = 780;

  // -- 书签发现链状态 ----------------------------------------------------------
  // step: idle | root | mobile | tiles | creating | done
  private step: string = 'idle';
  private waitingSeq: number = 0;
  private waitingParent: string = '';
  private homeSeq: number = HOME_SEQ_BASE;
  private mobileId: string = '';
  private chainTimer: number = -1;
  private chainRetries: number = 0;
  private refreshTimer: number = -1;
  private migratedChecked: boolean = false;
  // 冷启动缓存（文件）：tiles 与 favicon 各存一份原始 JSON，读到的第一帧即可
  // 渲染（用户报「冷启动书签加载慢」——原本要等 根→手机书签→首页 三次往返）。
  private cacheTilesJson: string = '';
  private cacheFaviconsJson: string = '';
  // 本轮磁贴是否来自「持久化的首页文件夹 id 直取」。直取失败（id 失效：书签被
  // 清空/换机）时不认死理，回退完整发现链重建。
  private fastTilePath: boolean = false;
  // 本轮发现链里是否已建过「首页」文件夹（防列表暂未反映时重复创建）。
  private createdInChain: boolean = false;
  // 「首页」文件夹回包为空时是否已重试过一次。引擎刚起步（书签模型还没加载完）
  // 会先回一个空列表，若此时把空结果当真，缓存会被写空、磁贴就空了；只可疑
  // 一次，重试仍空就认（用户确实把书签删光了）。
  private emptyTilesRetried: boolean = false;

  aboutToAppear(): void {
    const dsp = display.getDefaultDisplaySync();
    this.windowW = dsp.width / dsp.densityPixels;
    this.windowH = dsp.height / dsp.densityPixels;
    // 请求号跨挂载抬一段：避免回包 JSON 与上一轮逐字节相同（AppStorage 认为没变
    // → @Watch 不触发），磁贴要等超时重试才出现。
    homeSeqBump = HOME_SEQ_BASE + ((homeSeqBump - HOME_SEQ_BASE + 1000) % HOME_SEQ_SPAN);
    this.homeSeq = homeSeqBump;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    // 第一件事：把上次的磁贴与图标画出来（同步读文件，不等引擎回包）。
    this.applyCache(context);
    // 种子解析：@StorageLink 初值不触发 @Watch（血泪：只靠 @Watch 会等不到）。
    this.onFaviconsChanged();
    HomePrefs.loadCustom(context).then((value: HomeCustom): void => {
      this.custom = value;
      this.applyBackgroundPath(value.bgPath);
    });
    // 冷启动快速路径：上次已定位到「首页」文件夹，直接取它一层子节点（**一次
    // 往返**），不必再走 根→手机书签→首页 的三次往返（用户报「冷启动书签加载
    // 慢」）。id 失效时链式超时会回退完整发现（见 armChainTimer）。
    HomePrefs.loadFolderId(context).then((id: string): void => {
      if (id.length === 0) {
        this.refreshBookmarks();
        return;
      }
      this.homeFolderId = id;
      this.fastTilePath = true;
      this.requestChildren(id, 'tiles');
    });
    // 种子：设置面板里点的「自定义主页布局」可能先于 HomeSurface 挂载发出信号，
    // @Watch 初值不触发，挂载时补开一次并消费信号（无痕不打开）。
    HomePrefs.loadSeeded(context).then((seeded: boolean): void => {
      this.homeBookmarksSeeded = seeded;
      this.homeSeedLoaded = true;
      // 偏好可能晚于书签回包：标志位到位后补判一次，避免漏种/误种。
      this.maybeSeedDefaultBookmarks();
    });
    const pendingLayout: number = (AppStorage.get('auraOpenHomeLayout') as number) ?? 0;
    if (pendingLayout > 0 && !this.incognito) {
      this.showSettings = true;
    }
    AppStorage.set('auraOpenHomeLayout', 0);
  }

  aboutToDisappear(): void {
    this.clearChainTimer();
    if (this.refreshTimer !== -1) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = -1;
    }
    if (this.faviconBatchTimer !== -1) {
      clearTimeout(this.faviconBatchTimer);
      this.faviconBatchTimer = -1;
    }
  }

  // -- 冷启动缓存（HomeCache）---------------------------------------------------

  // 回填上次的磁贴与图标：有就立刻可画，没有就静默跳过。**不动 step**——回包
  // 处理链按自己的节奏推进（inFlight 只看 root/mobile/tiles），缓存只负责
  // 「第一帧别空着」。
  private applyCache(context: common.UIAbilityContext | undefined): void {
    const cached: HomeCacheData = HomeCache.load(context);
    if (cached.tilesJson.length > 0) {
      try {
        const nodes: BookmarkNode[] = JSON.parse(cached.tilesJson) as BookmarkNode[];
        if (nodes.length > 0) {
          this.fullNodes = nodes;
          this.rebuildTiles();
          // 记住「上次这份文件夹不是空的」：后面若收到空回包就能判断那是可疑的
          // 假空（引擎书签模型还没就位），而不是用户把书签删光了。
          this.cacheTilesJson = cached.tilesJson;
        }
      } catch (error) {
      }
    }
    if (cached.faviconsJson.length > 0 && cached.faviconSizeVp === TILE_FAVICON_REQUEST_VP) {
      this.applyFaviconsJson(cached.faviconsJson, false);
    }
  }

  // 写缓存：tiles 与 favicon 各自到达时更新对应的那段，再整体落盘（两个字段
  // 都在内存里，避免读-改-写）。
  private persistCache(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    // 图标 base64 会随书签数量线性增长；超过上限就只缓存磁贴列表（缓存是加速
    // 手段，不值得为它写一个几百 KB 的文件）。
    const faviconsJson: string = this.cacheFaviconsJson.length > MAX_CACHE_FAVICONS_CHARS ?
      '' : this.cacheFaviconsJson;
    const data: HomeCacheData = {
      tilesJson: this.cacheTilesJson,
      faviconsJson: faviconsJson,
      faviconSizeVp: TILE_FAVICON_REQUEST_VP
    };
    HomeCache.save(context, data);
  }

  // -- 背景图 ------------------------------------------------------------------

  private applyBackgroundPath(path: string): void {
    if (path.length === 0) {
      this.bgUri = '';
      return;
    }
    try {
      if (!fs.accessSync(path)) {
        this.bgUri = '';
        return;
      }
      this.bgUri = fileUri.getUriFromPath(path);
    } catch (error) {
      this.bgUri = '';
    }
  }

  private async pickBackground(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    try {
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const result = await new photoAccessHelper.PhotoViewPicker().select(options);
      const uris: string[] = result.photoUris ?? [];
      if (uris.length === 0) {
        return;
      }
      const dest = `${context.filesDir}/home_bg_${Date.now()}.jpg`;
      const source = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
      fs.copyFileSync(source.fd, dest);
      fs.closeSync(source);
      const old = this.custom.bgPath;
      if (old.length > 0 && old !== dest) {
        try {
          fs.unlinkSync(old);
        } catch (error) {
        }
      }
      this.custom.bgPath = dest;
      this.applyBackgroundPath(dest);
      HomePrefs.saveCustom(context, this.custom);
      this.getUIContext().getPromptAction().showToast({ message: '背景已更新', duration: 1500 });
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: '选择图片失败', duration: 1500 });
    }
  }

  private removeBackground(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    const old = this.custom.bgPath;
    if (old.length > 0) {
      try {
        fs.unlinkSync(old);
      } catch (error) {
      }
    }
    this.custom.bgPath = '';
    this.bgUri = '';
    HomePrefs.saveCustom(context, this.custom);
  }

  private persistCustom(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    HomePrefs.saveCustom(context, this.custom);
  }

  // -- 书签发现链：根 -> 手机书签 -> 「首页」文件夹（缺则建）-> 磁贴 -------------

  private nextSeq(): number {
    this.homeSeq += 1;
    return this.homeSeq;
  }

  private clearChainTimer(): void {
    if (this.chainTimer !== -1) {
      clearTimeout(this.chainTimer);
      this.chainTimer = -1;
    }
  }

  private armChainTimer(): void {
    this.clearChainTimer();
    this.chainTimer = setTimeout((): void => {
      this.chainTimer = -1;
      if (this.chainRetries >= MAX_CHAIN_RETRIES) {
        // 直取持久化的「首页」文件夹 id 失败（id 失效：书签被清空 / 换机 / 重装）：
        // 不认死理，回到完整发现链重建。
        if (this.fastTilePath && this.step === 'tiles') {
          this.fastTilePath = false;
          this.chainRetries = 0;
          this.homeFolderId = '';
          this.requestRoot();
          return;
        }
        this.tilesError = true;
        this.step = 'done';
        return;
      }
      this.chainRetries += 1;
      if (this.step === 'root') {
        this.requestRoot();
      } else if (this.step === 'mobile' && this.mobileId.length > 0) {
        this.requestChildren(this.mobileId, 'mobile');
      } else if (this.step === 'tiles' && this.homeFolderId.length > 0) {
        this.requestChildren(this.homeFolderId, 'tiles');
      } else if (this.step === 'creating' && this.mobileId.length > 0) {
        this.step = 'mobile';
        this.requestChildren(this.mobileId, 'mobile');
      }
    }, CHAIN_TIMEOUT_MS);
  }

  /** 全链重启（进入主页 / 手动重试）。 */
  private refreshBookmarks(): void {
    this.chainRetries = 0;
    this.tilesError = false;
    this.createdInChain = false;
    // 只要已知「首页」文件夹 id 就直取（一次往返）——不再要求 step === 'done'：
    // 书签在别处被改动后的刷新、以及冷启动，走的都是这条最短路径。
    if (this.homeFolderId.length > 0) {
      this.requestChildren(this.homeFolderId, 'tiles');
      return;
    }
    this.requestRoot();
  }

  private requestRoot(): void {
    this.step = 'root';
    this.waitingParent = '';
    this.waitingSeq = this.nextSeq();
    this.onCommand({ command: 'getBookmarks', requestId: this.waitingSeq });
    this.armChainTimer();
  }

  private requestChildren(parentId: string, step: string): void {
    this.step = step;
    this.waitingParent = parentId;
    this.waitingSeq = this.nextSeq();
    this.onCommand({ command: 'getBookmarks', requestId: this.waitingSeq, parentId: parentId });
    this.armChainTimer();
  }

  private onBookmarkListChanged(): void {
    if (this.bookmarkListJson.length === 0) {
      return;
    }
    const inFlight = this.step === 'root' || this.step === 'mobile' || this.step === 'tiles';
    if (!inFlight) {
      return;
    }
    let payload: BookmarkListPayload;
    try {
      payload = JSON.parse(this.bookmarkListJson) as BookmarkListPayload;
    } catch (error) {
      return;
    }
    const reqId = payload.requestId ?? -1;
    // 只认主页序号段的回包；宽松匹配（序号一致，或父层一致）——防两条回包挤在
    // 同一帧、@Watch 只见后一条（书签面板同时刷新时）而漏掉自己的。
    if (reqId < HOME_SEQ_BASE) {
      return;
    }
    if (reqId !== this.waitingSeq && (payload.parentId ?? '') !== this.waitingParent) {
      return;
    }
    this.clearChainTimer();
    const nodes: BookmarkNode[] = payload.nodes ?? [];

    if (this.step === 'root') {
      let mobile = '';
      for (const node of nodes) {
        if (node.rootType === 'mobile') {
          mobile = node.id;
          break;
        }
      }
      if (mobile.length === 0) {
        this.failChainStep();
        return;
      }
      this.mobileId = mobile;
      this.requestChildren(mobile, 'mobile');
      return;
    }

    if (this.step === 'mobile') {
      let folderId = '';
      for (const node of nodes) {
        if (node.type === 'folder' &&
          (node.title === HOME_FOLDER_TITLE || node.id === this.homeFolderId)) {
          folderId = node.id;
          break;
        }
      }
      if (folderId.length === 0) {
        // 本轮已建过一次还是没找到：收尾报错，避免重复创建文件夹。
        if (this.createdInChain) {
          this.tilesError = true;
          this.step = 'done';
          return;
        }
        // 文件夹还没建：建一个，等 bookmarkCreated 事件后回本层找 id。
        this.createdInChain = true;
        this.step = 'creating';
        this.waitingParent = this.mobileId;
        this.waitingSeq = this.nextSeq();
        this.onCommand({
          command: 'createBookmarkFolder',
          parentId: this.mobileId,
          title: HOME_FOLDER_TITLE,
          requestId: this.waitingSeq
        });
        this.armChainTimer();
        return;
      }
      this.setHomeFolder(folderId);
      this.requestChildren(folderId, 'tiles');
      return;
    }

    if (this.step === 'tiles') {
      // 可疑的空回包：上次的「首页」文件夹不是空的（缓存里还有内容），引擎多半
      // 只是书签模型还没加载完就先回了空列表。别当真——不落缓存、不收尾，等
      // 超时重发一次（只重试一次，仍空就认，用户可能真把书签删光了）。
      if (nodes.length === 0 && this.cacheTilesJson.length > 0 && !this.emptyTilesRetried) {
        this.emptyTilesRetried = true;
        this.armChainTimer();
        return;
      }
      this.emptyTilesRetried = false;
      this.fullNodes = nodes;
      this.rebuildTiles();
      this.step = 'done';
      this.fastTilePath = false;
      // 落缓存：写的是**全量子节点**（与 fullNodes 一致），下次冷启动第一帧
      // 就能画出磁贴，且排序换算照样可用。
      this.cacheTilesJson = JSON.stringify(nodes);
      this.persistCache();
      this.requestFavicons();
      this.maybeMigrate();
      // 首次运行且首页文件夹为空：种入谷歌/必应/百度/GitHub 四个默认书签。
      this.maybeSeedDefaultBookmarks();
      return;
    }
  }

  // 主页默认书签：首次运行把谷歌/必应/百度/GitHub 补进「首页」文件夹——按归一化 URL
  // 去重（已有同名站点跳过，不产生重复磁贴），补完置 seeded 标志位，用户之后删掉
  // 也不会被反复补回。
  private maybeSeedDefaultBookmarks(): void {
    // 偏好没读回来之前不种：回包先到时 homeBookmarksSeeded 还是 false，
    // 会被当成"没种过"而把用户删掉的默认站补回来。
    if (!this.homeSeedLoaded || this.homeBookmarksSeeded || this.homeFolderId.length === 0) {
      return;
    }
    const existing: string[] = [];
    for (const node of this.fullNodes) {
      if (node.type === 'url') {
        existing.push(seedKey(node.url ?? ''));
      }
    }
    const defaults: HomeSeedSite[] = [
      { title: '谷歌', url: 'https://www.google.com' },
      { title: '必应', url: 'https://www.bing.com' },
      { title: '百度', url: 'https://www.baidu.com' },
      { title: 'GitHub', url: 'https://github.com' }
    ];
    for (const site of defaults) {
      if (existing.indexOf(seedKey(site.url)) >= 0) {
        continue;
      }
      this.onCommand({
        command: 'addBookmark',
        url: site.url,
        title: site.title,
        parentId: this.homeFolderId,
        requestId: this.nextSeq()
      });
    }
    this.homeBookmarksSeeded = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    HomePrefs.saveSeeded(context, true);
  }

  /** 从全量子节点里取 url 磁贴（保持引擎回包顺序 = 文件夹位次）。 */
  private rebuildTiles(): void {
    const urls: BookmarkNode[] = [];
    for (const node of this.fullNodes) {
      if (node.type === 'url' && (node.url ?? '').length > 0) {
        urls.push(node);
      }
    }
    this.tiles = urls;
  }

  /**
   * 上移/下移磁贴：走引擎 moveBookmarks 在**同一文件夹**内换位次（引擎原生
   * 支持插入 index，越界自动钳制）。注意 index 是「全部子节点」的位次——
   * 子文件夹也占位，所以目标位次要按全量列表里相邻 url 节点的落点来算。
   * 本地先乐观换序（即时反馈），引擎 bookmarksChanged 回来后再校正。
   */
  private moveTile(id: string, dir: number): void {
    if (this.homeFolderId.length === 0 || this.fullNodes.length === 0) {
      return;
    }
    let idx = -1;
    for (let i = 0; i < this.fullNodes.length; i++) {
      if (this.fullNodes[i].id === id) {
        idx = i;
        break;
      }
    }
    if (idx < 0) {
      return;
    }
    let j = idx + dir;
    while (j >= 0 && j < this.fullNodes.length && this.fullNodes[j].type !== 'url') {
      j += dir;
    }
    if (j < 0 || j >= this.fullNodes.length) {
      return;
    }
    const target = j;
    const nodes = this.fullNodes.slice();
    const moved = nodes[idx];
    nodes.splice(idx, 1);
    nodes.splice(target, 0, moved);
    this.fullNodes = nodes;
    this.rebuildTiles();
    // 引擎 moveBookmarks 走 Chromium BookmarkModel::Move 语义：同父、目标 index
    // 大于源 index 时引擎会把 index 自动 -1（先移除源再插入）。所以「下移」要
    // 补 +1 抵消，否则下移会被引擎当成原位、等于没动（这就是「下移不起作用」的根因）；
    // 「上移」送相邻 index 即可。本地已先乐观换序，引擎刷新后校正。
    const sendIndex = dir > 0 ? target + 1 : target;
    this.onCommand({
      command: 'moveBookmarks',
      ids: [id],
      parentId: this.homeFolderId,
      index: sendIndex,
      requestId: this.nextSeq()
    });
  }

  private failChainStep(): void {
    if (this.chainRetries >= MAX_CHAIN_RETRIES) {
      this.tilesError = true;
      this.step = 'done';
      return;
    }
    this.chainRetries += 1;
    this.requestRoot();
  }

  private setHomeFolder(id: string): void {
    this.homeFolderId = id;
    AppStorage.setOrCreate('auraHomeFolderId', id);
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    HomePrefs.saveFolderId(context, id);
  }

  /** 面板在别处动了书签：轻量刷新磁贴（防抖合流多次变更）。 */
  private onPanelEvent(): void {
    if (this.panelEventJson.length === 0) {
      return;
    }
    let kind = '';
    try {
      kind = (JSON.parse(this.panelEventJson) as PanelEventPayload).kind ?? '';
    } catch (error) {
      return;
    }
    if (kind !== 'bookmarkCreated' && kind !== 'bookmarksChanged') {
      return;
    }
    if (this.step === 'creating') {
      // 刚建的「首页」文件夹就绪：回手机书签层把它找出来。
      if (this.mobileId.length > 0) {
        this.requestChildren(this.mobileId, 'mobile');
      } else {
        this.requestRoot();
      }
      return;
    }
    if (this.step !== 'done' && this.step !== 'idle') {
      return;
    }
    if (this.refreshTimer !== -1) {
      clearTimeout(this.refreshTimer);
    }
    this.refreshTimer = setTimeout((): void => {
      this.refreshTimer = -1;
      if (this.homeFolderId.length > 0) {
        this.requestChildren(this.homeFolderId, 'tiles');
      } else {
        this.requestRoot();
      }
    }, REFRESH_DEBOUNCE_MS);
  }

  // -- 老快捷方式一次性迁入「首页」文件夹 ---------------------------------------

  private maybeMigrate(): void {
    if (this.migratedChecked) {
      return;
    }
    this.migratedChecked = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    HomePrefs.loadMigrated(context).then((done: boolean): void => {
      if (done) {
        return;
      }
      HomeShortcuts.load(context).then((olds: HomeShortcut[]): void => {
        const have: Set<string> = new Set();
        for (const tile of this.tiles) {
          have.add(normUrl(tile.url ?? ''));
        }
        let added = 0;
        for (const item of olds) {
          if (item.url.length === 0 || have.has(normUrl(item.url))) {
            continue;
          }
          have.add(normUrl(item.url));
          this.onCommand({
            command: 'addBookmark',
            url: item.url,
            title: item.title,
            parentId: this.homeFolderId,
            requestId: this.nextSeq()
          });
          added += 1;
        }
        HomePrefs.saveMigrated(context, true);
        if (added > 0) {
          this.getUIContext().getPromptAction()
            .showToast({ message: `已将 ${added} 个原快捷方式迁入书签「首页」`, duration: 2000 });
        }
      });
    });
  }

  // -- 图标 --------------------------------------------------------------------
  //
  // 取图标这一层对齐 FaviconStore 的做法：
  //   ① 只问 http(s)（want() 里那道门）；
  //   ② settled / pending 两个集合去重，命中过就不再问；
  //   ③ 攒一拍合批（BATCH_DELAY_MS）后**一次**发出去，回包后统一派发。
  // 我们的差异：settled 只在内存里，冷启动的第一帧由文件缓存（HomeCache）兜。

  private requestFavicons(): void {
    if (this.tiles.length === 0) {
      return;
    }
    // 上一轮没取到的 url 放回队列再问一次（命中的永不重问）。没有这一步的话，
    // 「先建书签、后访问站点」的磁贴要等重启才补上图标。
    const misses: string[] = [];
    this.faviconAsked.forEach((url: string): void => {
      if (!this.faviconBase64.has(url)) {
        misses.push(url);
      }
    });
    for (const url of misses) {
      this.faviconAsked.delete(url);
    }
    let queued = 0;
    for (const node of this.tiles) {
      const url = (node.url ?? '').trim();
      if (!isFetchableUrl(url)) {
        continue;
      }
      if (this.faviconAsked.has(url) || this.faviconQueued.has(url)) {
        continue;
      }
      this.faviconQueued.add(url);
      queued += 1;
    }
    if (queued === 0 || this.faviconBatchTimer !== -1) {
      return;
    }
    this.faviconBatchTimer = setTimeout((): void => {
      this.faviconBatchTimer = -1;
      this.flushFavicons();
    }, FAVICON_BATCH_MS);
  }

  // 把这一拍攒下的 url 发出去；超过引擎的单次上限（100）就分片，回包累积。
  private flushFavicons(): void {
    const urls: string[] = Array.from(this.faviconQueued);
    this.faviconQueued.clear();
    if (urls.length === 0) {
      return;
    }
    // 先记 settled：命中不命中都只问一次（引擎只回命中的，未回的就是没有）。
    for (const url of urls) {
      this.faviconAsked.add(url);
    }
    for (let start = 0; start < urls.length; start += FAVICON_BATCH_MAX) {
      const slice = urls.slice(start, start + FAVICON_BATCH_MAX);
      this.onCommand({
        command: 'getFavicons', requestId: this.nextSeq(), urls: slice,
        sizeVp: TILE_FAVICON_REQUEST_VP
      });
    }
  }

  private onFaviconsChanged(): void {
    // 引擎回包：解析 + 落缓存（下次冷启动第一帧就能画出来）。
    this.applyFaviconsJson(this.faviconsJson, true);
  }

  private applyFaviconsJson(json: string, persist: boolean): void {
    if (json.length === 0) {
      return;
    }
    try {
      const items: FaviconImage[] = JSON.parse(json) as FaviconImage[];
      for (const item of items) {
        if (item.url && item.url.length > 0 && item.pngBase64 && item.pngBase64.length > 0) {
          this.faviconBase64.set(item.url, item.pngBase64);
        }
      }
      this.rebuildFavicons();
      if (persist) {
        this.cacheFaviconsJson = this.serializeFavicons();
        this.persistCache();
      }
    } catch (error) {
    }
  }

  // 累积的 base64 → 绘制用的 data URL map（赋值新对象才会触发重绘）。
  private rebuildFavicons(): void {
    const map: Map<string, string> = new Map();
    this.faviconBase64.forEach((base64: string, url: string): void => {
      map.set(url, `data:image/png;base64,${base64}`);
    });
    this.favicons = map;
  }

  private serializeFavicons(): string {
    const items: FaviconImage[] = [];
    this.faviconBase64.forEach((base64: string, url: string): void => {
      items.push({ url: url, pngBase64: base64 });
    });
    return JSON.stringify(items);
  }

  private faviconFor(node: BookmarkNode): string {
    const url = node.url ?? '';
    if (url.length > 0) {
      const value = this.favicons.get(url);
      if (value) {
        return value;
      }
    }
    return '';
  }

  // 底板色：有图标用中性托盘（透明底 logo 也看得清），没图标用按站点哈希出的
  // 稳定色 + 白字首字母（Chrome 的 fake favicon 做法）。
  private plateColor(node: BookmarkNode): ResourceColor {
    if (this.faviconFor(node).length > 0) {
      return $r('app.color.surface_secondary');
    }
    return placeholderTint(node);
  }

  // -- 行为 --------------------------------------------------------------------

  private submitQuery(): void {
    const target = normalizeAddress(this.query);
    this.query = '';
    this.clearSuggest();
    if (target.length > 0) {
      this.onCommand({ command: 'navigate', url: target });
    }
  }

  // 主页搜索框联想：输入即问引擎（与地址栏同一条 autocomplete 命令）。
  // 只有非空输入才发，130ms 防抖——和地址栏一样的手感。
  private requestSuggest(text: string): void {
    if (this.suggestTimer !== -1) {
      clearTimeout(this.suggestTimer);
      this.suggestTimer = -1;
    }
    if (text.trim().length === 0) {
      this.suggestPending = -1;
      this.suggestItems = [];
      return;
    }
    // 新输入 = 新的一轮：恢复到「还没上屏」，这样引擎第一包能立刻把卡弹出来。
    this.suggestShownFor = -1;
    this.suggestTimer = setTimeout((): void => {
      this.suggestTimer = -1;
      this.suggestSeq += 1;
      if (this.suggestSeq > HOME_SUGGEST_SEQ_BASE + HOME_SEQ_SPAN) {
        this.suggestSeq = HOME_SUGGEST_SEQ_BASE + 1;
      }
      this.suggestPending = this.suggestSeq;
      this.onCommand({ command: 'autocomplete', requestId: this.suggestSeq, text: text });
      // 1.0.4：防抖 130 → 90ms。上游还有 130ms 才发请求，加上引擎各 provider
      // 耗时，用户感知就是「慢半拍」；90ms 仍足够合并连打。
    }, 90);
  }

  // 引擎回包：只认最新 requestId（旧包丢弃）。
  private onHomeAutocomplete(): void {
    if (this.autocompleteJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.autocompleteJson) as HomeAutocompletePayload;
      if (payload.requestId !== this.suggestPending) {
        return;
      }
      const items: AutocompleteItem[] = [];
      for (const parsed of payload.items ?? []) {
        items.push({
          type: parsed.type,
          title: typeof parsed.title === 'string' ? parsed.title : '',
          url: typeof parsed.url === 'string' ? parsed.url : '',
          description: typeof parsed.description === 'string' ? parsed.description : ''
        } as AutocompleteItem);
      }
      // 引擎对一次输入会推 2~5 包（每个 provider 各推一包，done 只在最后那包
      // 为 true）。全等 done 才有内容 → 弹窗得等最慢的 provider（搜索建议要走
      // 网络，几百毫秒），用户感知就是「弹出来慢」。
      // 所以分两段：**首包立刻上屏**（本地 provider 最快，先把卡弹出来），
      // 后续包不直接重建，攒最新一份 120ms 合并刷一次；done 到了立即刷。
      // 空包一律不落 UI，包括「done=true 但结果为空」那种：引擎的
      // AutocompleteController::Start() 会先 Stop 上一次请求，Stop 同步冲出一包
      // 「空结果 + done=true」，且带着**新**的 requestId。照单清空就会把卡片刷成
      // 只剩一行兜底行（观感「偶尔不展开」）。保留上一份列表更稳。
      if (items.length === 0) {
        return;
      }
      if (payload.done === true) {
        this.cancelSuggestFlush();
        this.suggestItems = items;
        this.suggestShownFor = payload.requestId;
        return;
      }
      if (this.suggestShownFor !== payload.requestId) {
        this.cancelSuggestFlush();
        this.suggestItems = items;
        this.suggestShownFor = payload.requestId;
        return;
      }
      this.suggestQueued = items;
      if (this.suggestFlushTimer !== -1) {
        return;
      }
      this.suggestFlushTimer = setTimeout((): void => {
        this.suggestFlushTimer = -1;
        if (this.suggestQueued.length > 0) {
          this.suggestItems = this.suggestQueued;
          this.suggestQueued = [];
        }
      }, 120);
    } catch (error) {
    }
  }

  private clearSuggest(): void {
    if (this.suggestTimer !== -1) {
      clearTimeout(this.suggestTimer);
      this.suggestTimer = -1;
    }
    this.cancelSuggestFlush();
    this.suggestPending = -1;
    this.suggestShownFor = -1;
    this.suggestItems = [];
  }

  // 取消待合并的刷新（新请求 / 收起列表时调用，避免旧包把新结果盖回去）。
  private cancelSuggestFlush(): void {
    if (this.suggestFlushTimer !== -1) {
      clearTimeout(this.suggestFlushTimer);
      this.suggestFlushTimer = -1;
    }
    this.suggestQueued = [];
  }

  private suggestActive(): boolean {
    return this.query.trim().length > 0 && this.suggestItems.length > 0;
  }

  private openSuggestion(item: AutocompleteItem): void {
    const target: string = item.url.length > 0 ? item.url : normalizeAddress(item.title);
    this.clearSuggest();
    this.query = '';
    if (target.length > 0) {
      this.onCommand({ command: 'navigate', url: target });
    }
  }

  @Builder
  private HomeSuggestCard() {
    Column() {
      ForEach(this.suggestItems, (item: AutocompleteItem, index: number) => {
        Column() {
          Row({ space: 10 }) {
            Image(item.type === 'search' ?
              $r('app.media.chromium_search') : $r('app.media.aura_clock'))
              .width(16)
              .height(16)
              .fillColor($r('app.color.icon_secondary'))
            Column({ space: 2 }) {
              Text(item.title.length > 0 ? item.title : item.url)
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              if (item.url.length > 0) {
                Text(item.url)
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .onClick((): void => {
            this.openSuggestion(item);
          })

          if (index < this.suggestItems.length - 1) {
            Divider()
              .color($r('app.color.divider'))
              .margin({ left: 40 })
          }
        }
        .width('100%')
      }, (item: AutocompleteItem, index: number): string =>
        `${item.type}|${item.url}|${item.title}`)
    }
    .width('100%')
    .borderRadius(16)
    .backgroundColor($r('app.color.card_background'))
    .clip(true)
    .shadow({ radius: 10, color: $r('app.color.shadow'), offsetY: 4 })
    .margin({ top: 8 })
    // 轻微淡入：卡片是随首个回包插入的，硬切会像"闪一下"。
    .transition(TransitionEffect.OPACITY.animation({ duration: 110, curve: Curve.Friction }))
  }

  private openBookmark(node: BookmarkNode): void {
    const url = node.url ?? '';
    if (url.length > 0) {
      this.onCommand({ command: 'navigate', url: url });
    }
  }

  private async startScan(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    const value = await ScanService.scanOnce(context);
    if (value.length > 0) {
      this.onCommand({ command: 'navigate', url: normalizeAddress(value) });
    }
  }

  // 右上角齿轮的果冻按压：按下快收 0.85，松手用欠阻尼弹簧振荡回弹。
  // 参数比顶栏圆钮（0.3/0.7）更小阻尼 —— 用户要「q 弹、按住拉变形」：
  // 官方 springMotion(response, dampingFraction)，0.3/0.5=多次振荡很强、
  // 0.5/0.7=适度自然，往小调振荡越多越弹（1.0.83 调为 0.25/0.55）。
  private handleGearTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      animateTo({ duration: 80, curve: Curve.FastOutSlowIn }, (): void => {
        this.pressedGear = true;
      });
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      animateTo({ curve: curves.springMotion(0.25, 0.55) }, (): void => {
        this.pressedGear = false;
      });
    }
  }

  private gearScale(): ScaleOptions {
    const s: number = this.pressedGear ? 0.85 : 1;
    return { x: s, y: s };
  }

  // -- 长按菜单 ----------------------------------------------------------------

  private showBookmarkActions(node: BookmarkNode): void {
    const cardW = MENU_CARD_VP;
    this.menuX = Math.min(Math.max(this.menuPressX - cardW / 2, 12),
      Math.max(12, this.windowW - cardW - 12));
    this.menuY = Math.min(Math.max(this.menuPressY + 8, 12), Math.max(12, this.windowH - MENU_CARD_H - 96));
    this.menuTitle = node.title;
    this.menuId = node.id;
  }

  private beginEditFromMenu(): void {
    const id = this.menuId;
    this.menuId = '';
    this.menuTitle = '';
    let title = '';
    let url = '';
    for (const node of this.tiles) {
      if (node.id === id) {
        title = node.title;
        url = node.url ?? '';
        break;
      }
    }
    this.editingId = id;
    this.newBookmarkTitle = title;
    this.newBookmarkUrl = url;
    this.showAddBookmark = true;
  }

  private deleteFromMenu(): void {
    const id = this.menuId;
    const title = this.menuTitle;
    this.menuId = '';
    this.menuTitle = '';
    if (id.length === 0) {
      return;
    }
    this.getUIContext().getPromptAction().showDialog({
      title: '删除书签',
      message: title.length > 0 ? title : '该网址',
      buttons: [
        { text: '取消', color: '#5F6368' },
        { text: '删除', color: '#E24B4A' }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (result.index !== 1) {
        return;
      }
      this.onCommand({ command: 'removeBookmarks', ids: [id], requestId: this.nextSeq() });
      this.getUIContext().getPromptAction().showToast({ message: '已删除', duration: 1500 });
    }).catch((error: Error): void => {
    });
  }

  private closeBookmarkForm(): void {
    this.showAddBookmark = false;
    this.editingId = '';
    this.newBookmarkTitle = '';
    this.newBookmarkUrl = '';
  }

  private confirmBookmarkForm(): void {
    const url = normalizeAddress(this.newBookmarkUrl.trim());
    if (url.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '请输入网址', duration: 1500 });
      return;
    }
    const title = this.newBookmarkTitle.trim();
    const editing = this.editingId.length > 0;
    if (editing) {
      this.onCommand({
        command: 'updateBookmark',
        id: this.editingId,
        title: title,
        url: url,
        requestId: this.nextSeq()
      });
    } else {
      this.onCommand({
        command: 'addBookmark',
        url: url,
        title: title,
        parentId: this.homeFolderId,
        requestId: this.nextSeq()
      });
    }
    this.closeBookmarkForm();
    this.getUIContext().getPromptAction()
      .showToast({ message: editing ? '已保存' : '已添加到主页', duration: 1500 });
  }

  // 一个书签磁贴：圆角底板 + favicon（缺失时首字母占位）+ 标题。
  // 单击 = 打开；长按 = 编辑/删除菜单。
  //
  // 【1.0.88 图标清晰度】底板仍是 46vp，但图标只画 TILE_FAVICON_VP=24vp：
  // 引擎按 sizeVp×density 把站点图标缩放到请求尺寸（shell_favicons_ohos.cc），
  // 站点只声明 16/32px 时**填满 46vp 就是硬放大 4 倍 → 糊**。小图标落在大
  // 托盘里（磁贴比例），既清晰又不头重脚轻。
  @Builder
  private BookmarkTile(node: BookmarkNode) {
    Column({ space: 7 }) {
      Stack({ alignContent: Alignment.Center }) {
        if (this.faviconFor(node).length > 0) {
          Image(this.faviconFor(node))
            .width(TILE_FAVICON_VP)
            .height(TILE_FAVICON_VP)
            .borderRadius(TILE_FAVICON_RADIUS)
            // Contain 而非 Cover：favicon 若为横条 logo（部分站点给的是宽图），
            // Cover 会把两侧裁掉；Contain 等比完整显示。
            .objectFit(ImageFit.Contain)
            // 请求尺寸是绘制的 2 倍 → 这里是**缩小**采样，High 插值清晰。
            .interpolation(ImageInterpolation.High)
            // Image 默认 draggable(true)：长按图标会启动拖拽、抢占磁贴的
            // LongPressGesture（长按文字正常、长按图标无反应的根因）。
            .draggable(false)
        } else {
          Text(initialOf(node))
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .textAlign(TextAlign.Center)
            .width(TILE_FAVICON_VP)
            .height(TILE_FAVICON_VP)
        }
      }
      .width(TILE_ICON_VP)
      .height(TILE_ICON_VP)
      .borderRadius(TILE_ICON_RADIUS)
      .backgroundColor(this.plateColor(node))

      Text(node.title.length > 0 ? node.title : (node.url ?? ''))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
    }
    .width('25%')
    .padding({ top: 14 })
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down && event.touches.length > 0) {
        this.menuPressX = event.touches[0].windowX;
        this.menuPressY = event.touches[0].windowY;
      }
    })
    // GestureGroup 显式声明"单击=打开 / 长按=菜单"，避免隐式 onClick 的 tap
    // 手势抢占长按（血泪：长按无反应）。
    .gesture(GestureGroup(GestureMode.Exclusive,
      LongPressGesture({ repeat: false })
        .onAction((): void => {
          this.showBookmarkActions(node);
        }),
      TapGesture({ count: 1 })
        .onAction((): void => {
          this.openBookmark(node);
        })
    ))
  }

  // 主页书签磁贴：4 列 Flex 布局。本 SDK 无 Grid 拖拽重排 API，放弃拖拽、
  // 回归稳定的长按菜单 + 添加（下移修复见 moveTile：sendIndex 下移 +1）。
  @Builder
  private BookmarkGrid() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.tiles, (node: BookmarkNode, index: number) => {
        this.BookmarkTile(node)
      }, (node: BookmarkNode): string =>
        `${node.id}|${node.title}|${node.url ?? ''}`)

      // 「添加书签」磁贴：点开添加表单（预填当前页）。
      Column({ space: 7 }) {
        Column() {
          Image($r('app.media.aura_plus'))
            .width(22)
            .height(22)
            .fillColor($r('app.color.icon_secondary'))
        }
        .width(TILE_ICON_VP)
        .height(TILE_ICON_VP)
        .borderRadius(TILE_ICON_RADIUS)
        .backgroundColor($r('app.color.surface_secondary'))
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        Text('添加')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
          .width('100%')
      }
      .width('25%')
      .padding({ top: 14 })
      .onClick(() => {
        this.editingId = '';
        this.newBookmarkTitle = '';
        this.newBookmarkUrl = '';
        this.showAddBookmark = true;
      })
    }
    .width('100%')

    if (this.tiles.length === 0) {
      Text('书签「首页」文件夹还是空的\n在「书签」中进入「首页」文件夹，或点「+」添加')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .width('100%')
        .margin({ top: 10 })
    }
  }

  // 长按书签的自绘菜单卡（menu_glass 实底 + 圆角 22 + 阴影，行高 48）。
  @Builder
  private BookmarkMenuOverlay() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .onClick(() => {
          this.menuId = '';
          this.menuTitle = '';
        })

      Column() {
        this.MenuRow($r('app.media.aura_chevron'), '上移', (): void => {
          const id = this.menuId;
          this.menuId = '';
          this.menuTitle = '';
          this.moveTile(id, -1);
        }, -90)
        this.MenuRow($r('app.media.aura_chevron'), '下移', (): void => {
          const id = this.menuId;
          this.menuId = '';
          this.menuTitle = '';
          this.moveTile(id, 1);
        }, 90)
        this.MenuRow($r('app.media.aura_edit'), '编辑', (): void => {
          this.beginEditFromMenu();
        }, 0)
        this.MenuRow($r('app.media.aura_trash'), '删除', (): void => {
          this.deleteFromMenu();
        }, 0)
      }
      .width(MENU_CARD_VP)
      .padding({ top: 6, bottom: 6 })
      .borderRadius(22)
      .backgroundColor($r('app.color.menu_glass'))
      .shadow({ radius: 26, color: $r('app.color.shadow'), offsetY: 8 })
      .position({ x: this.menuX, y: this.menuY })
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.opacity(0)
          .combine(TransitionEffect.scale({ x: 0.9, y: 0.9 })),
        TransitionEffect.opacity(0)
          .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }))
      ).animation({ curve: curves.springMotion(0.3, 0.72) }))
    }
    .width('100%')
    .height('100%')
    // 退场动效（1.0.68）：必须挂在 if 分支根节点上（挂子节点时退场被整子树
    // "原子删除"——真机"背景缓慢变暗、取消瞬间变亮闪一下"）。
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.opacity(1),
      TransitionEffect.opacity(0).animation({ duration: 300, curve: Curve.Friction })
    ))
  }

  @Builder
  private MenuRow(icon: Resource, label: string, action: () => void, iconAngle: number) {
    Row({ space: 14 }) {
      Image(icon)
        .width(21)
        .height(21)
        .fillColor($r('app.color.icon_primary'))
        .rotate({ angle: iconAngle })
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
      Blank()
    }
    .width('100%')
    .height(48)
    .padding({ left: 18, right: 16 })
    .onClick(action)
  }

  // 添加/编辑书签弹层（menu_glass 实底 + 遮罩盖满全屏）。
  @Builder
  private BookmarkFormOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.modal_scrim'))
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.opacity(0).animation({ duration: 260, curve: Curve.Friction }),
          TransitionEffect.opacity(0).animation({ duration: 380, curve: Curve.Friction })
        ))
        .onClick(() => {
          this.closeBookmarkForm();
        })

      Row() {
        Column({ space: 14 }) {
          // 1.0.111：文案回滚为「书签」——这个表单是主页磁贴（书签「首页」文件
          // 夹）的添加/编辑；「网址主页」是另一回事（overlay 层的设置表单）。
          Text(this.editingId.length > 0 ? '编辑书签' : '添加书签')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          if (this.editingId.length === 0) {
            Text('保存在书签「首页」文件夹，会显示在主页')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }

          Column({ space: 6 }) {
            Text('名称')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            TextInput({ text: this.newBookmarkTitle, placeholder: '网站名称（可留空）' })
              .height(46)
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_secondary'))
              .backgroundColor($r('app.color.surface_secondary'))
              .borderRadius(12)
              .onChange((value: string): void => {
                this.newBookmarkTitle = value;
              })
          }
          .width('100%')

          Column({ space: 6 }) {
            Text('网址')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            TextInput({ text: this.newBookmarkUrl, placeholder: 'https://…' })
              .height(46)
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_secondary'))
              .backgroundColor($r('app.color.surface_secondary'))
              .borderRadius(12)
              .onChange((value: string): void => {
                this.newBookmarkUrl = value;
              })
          }
          .width('100%')

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
              this.closeBookmarkForm();
            })

            Row() {
              Text(this.editingId.length > 0 ? '保存' : '添加')
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
              this.confirmBookmarkForm();
            })
          }
          .width('100%')
        }
        .width('100%')
        .padding(20)
        .borderRadius(22)
        .backgroundColor($r('app.color.menu_glass'))
        .shadow({ radius: 26, color: $r('app.color.shadow'), offsetY: 8 })
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.opacity(0)
            .combine(TransitionEffect.scale({ x: 0.92, y: 0.92 }))
            .animation({ curve: curves.springMotion(0.3, 0.75) }),
          TransitionEffect.opacity(0)
            .combine(TransitionEffect.scale({ x: 0.95, y: 0.95 }))
            .animation({ duration: 320, curve: Curve.FastOutSlowIn })
        ))
      }
      .padding({ left: 44, right: 44 })
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.opacity(1),
      TransitionEffect.opacity(0).animation({ duration: 340, curve: Curve.Friction })
    ))
  }

  // -- 主页布局 ----------------------------------------------------------------

  @Builder
  private HomeSettingsOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.modal_scrim'))
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.opacity(0).animation({ duration: 260, curve: Curve.Friction }),
          TransitionEffect.opacity(0).animation({ duration: 380, curve: Curve.Friction })
        ))
        .onClick(() => {
          this.showSettings = false;
        })

      Row() {
        Column({ space: 10 }) {
          Row() {
            Text('主页布局')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            Blank()
            Text('背景与布局只影响主页')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')

          Scroll() {
            Column({ space: 6 }) {
              // -- 背景 --
              Row({ space: 10 }) {
                if (this.bgUri.length > 0) {
                  Image(this.bgUri)
                    .width(74)
                    .height(46)
                    .borderRadius(10)
                    .objectFit(ImageFit.Cover)
                } else {
                  Column() {
                    Text('默认')
                      .fontSize(12)
                      .fontColor($r('app.color.text_secondary'))
                  }
                  .width(74)
                  .height(46)
                  .borderRadius(10)
                  .backgroundColor($r('app.color.surface_secondary'))
                  .justifyContent(FlexAlign.Center)
                }
                Row() {
                  Text('选择图片')
                    .fontSize(14)
                    .fontColor($r('app.color.text_primary'))
                }
                .justifyContent(FlexAlign.Center)
                .height(36)
                .padding({ left: 14, right: 14 })
                .borderRadius(18)
                .backgroundColor($r('app.color.surface_secondary'))
                .onClick(() => {
                  this.pickBackground();
                })
                Row() {
                  Text('移除背景')
                    .fontSize(14)
                    .fontColor(this.custom.bgPath.length > 0
                      ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
                }
                .justifyContent(FlexAlign.Center)
                .height(36)
                .padding({ left: 14, right: 14 })
                .borderRadius(18)
                .backgroundColor($r('app.color.surface_secondary'))
                .onClick(() => {
                  this.removeBackground();
                })
              }
              .width('100%')
              .margin({ top: 4 })

              // -- 显示 --
              Text('显示')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .margin({ top: 8 })
              HomeSettingToggleRow({
                icon: $r('app.media.aura_display'), label: 'Logo 区', isOn: this.custom.showLogo,
                onToggle: (on: boolean): void => {
                  this.custom.showLogo = on;
                  this.persistCustom();
                }
              })
              HomeSettingToggleRow({
                icon: $r('app.media.aura_bookmark'), label: '书签区', isOn: this.custom.showTiles,
                onToggle: (on: boolean): void => {
                  this.custom.showTiles = on;
                  this.persistCustom();
                }
              })

              // -- 位置 --
              Text('位置（上下微调）')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .margin({ top: 8 })
              HomePositionSliderRow({
                label: 'Logo', posOffset: this.custom.logoOffset, min: -120, max: 260,
                onMoved: (value: number, end: boolean): void => {
                  this.custom.logoOffset = value;
                  this.layoutDragging = !end;
                  if (end) {
                    this.persistCustom();
                  }
                }
              })
              HomePositionSliderRow({
                label: '搜索框', posOffset: this.custom.searchOffset, min: -40, max: 260,
                onMoved: (value: number, end: boolean): void => {
                  this.custom.searchOffset = value;
                  this.layoutDragging = !end;
                  if (end) {
                    this.persistCustom();
                  }
                }
              })
              HomePositionSliderRow({
                label: '书签区', posOffset: this.custom.tilesOffset, min: -40, max: 260,
                onMoved: (value: number, end: boolean): void => {
                  this.custom.tilesOffset = value;
                  this.layoutDragging = !end;
                  if (end) {
                    this.persistCustom();
                  }
                }
              })

              Row() {
                Text('恢复默认布局')
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
              }
              .width('100%')
              .height(42)
              .justifyContent(FlexAlign.Center)
              .borderRadius(12)
              .backgroundColor($r('app.color.surface_secondary'))
              .margin({ top: 8 })
              .onClick(() => {
                this.custom.logoOffset = 0;
                this.custom.searchOffset = 0;
                this.custom.tilesOffset = 0;
                this.custom.showLogo = true;
                this.custom.showSearch = true;
                this.custom.showTiles = true;
                this.persistCustom();
              })
            }
            .width('100%')
          }
          .width('100%')
          .constraintSize({ maxHeight: Math.max(300, this.windowH * 0.52) })
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })

          Row() {
            Text('完成')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.on_accent'))
          }
          .width('100%')
          .height(44)
          .justifyContent(FlexAlign.Center)
          .borderRadius(12)
          .backgroundColor($r('app.color.accent_primary'))
          .onClick(() => {
            this.showSettings = false;
          })
        }
        .width('100%')
        .padding(20)
        .borderRadius(22)
        // 1.0.97：平时近实底（可读），仅拖动位置滑块时转 60% 玻璃（float_bar_bg），
        // 松手恢复——拖的时候要能看见后边主页实时变化，静止时不要透。
        .backgroundColor(this.layoutDragging ?
          $r('app.color.float_bar_bg') : $r('app.color.menu_glass'))
        .shadow({ radius: 26, color: $r('app.color.shadow'), offsetY: 8 })
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.opacity(0)
            .combine(TransitionEffect.scale({ x: 0.92, y: 0.92 }))
            .animation({ curve: curves.springMotion(0.3, 0.75) }),
          TransitionEffect.opacity(0)
            .combine(TransitionEffect.scale({ x: 0.95, y: 0.95 }))
            .animation({ duration: 320, curve: Curve.FastOutSlowIn })
        ))
      }
      .padding({ left: 26, right: 26 })
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.opacity(1),
      TransitionEffect.opacity(0).animation({ duration: 340, curve: Curve.Friction })
    ))
  }

  // 设置-主页设置「自定义主页布局」入口触发：打开主页布局弹层（无痕不打开）。
  // 消费信号后置 0，避免 HomeSurface 卸载重挂时因信号残留被 aboutToAppear 种子误开。
  private onOpenHomeLayout(): void {
    if (!this.incognito) {
      this.showSettings = true;
    }
    AppStorage.set('auraOpenHomeLayout', 0);
  }

  // （1.0.111：onOpenHomeTile 随信号一并移除。）

  // 首页内容组的顶部锚点占位（1.0.180）：把 Logo 行中心钉在 22% 窗高
  // （设计稿 440×956 实测 21.9%）；Logo 关闭时改为把搜索框中心钉在 33.5%
  // （实测 33.6%）。减去的 24 = 行半高（Logo 行与搜索框都是 48 高）。
  // 「Logo」微调 logoOffset 叠加在锚点之上，负值可上移。
  private homeTopBlankVp(): number {
    const anchor: number = (this.custom.showLogo || this.incognito) ? 0.22 : 0.335;
    const anchored: number = this.windowH * anchor - this.topSafeVp - 24 + this.custom.logoOffset;
    // 下限：页面最上面常驻一条 56vp 的工具条（简约风格的主页/标签数/⋮，或
    // Chrome 风格的上置 dock），Blank 再小也不能把首行塞到它下面去 —— 横屏时
    // 窗高只有 ~419vp，算出来的 Blank 本来就只 68vp，一旦 windowH 被读小，
    // 整行 Logo 会钻到工具条背后、只露出图底部一条弧线（2026-10-27 实测）。
    return Math.max(TOP_CHROME_EXTENT_VP + 8, anchored);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 背景图（设置了才铺；无痕不铺）。hitTestBehavior None：纯装饰层。
      if (this.bgUri.length > 0 && !this.incognito) {
        Image(this.bgUri)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .hitTestBehavior(HitTestMode.None)
        // 主题色薄纱：亮色提亮 / 暗色压暗，保证文字对比度。
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.surface_primary'))
          .opacity(0.30)
          .hitTestBehavior(HitTestMode.None)
      }

      Column() {
        // 主页内容进 Scroll：横屏可用高只有 ~377vp（419 窗高 − 42 状态栏），
        // Logo 46 + 搜索框 48 + 磁贴两行几乎占满，再多一个书签就完全看不到、
        // 也没法挪 —— 原来是固定布局 + 弹性占位，超出视口的部分直接被裁掉
        // （用户实拍横屏问「是不是该能上下滚动」）。
        // 锚点不变：Blank 仍是滚动内容的第一段，未滚动时位置和以前一模一样。
        Scroll() {
          Column() {
            // 1.0.180：内容组按设计稿锚定——顶部是**按窗高算出的固定占位**
            // （Logo 行/搜索框的中心 22% / 33.5% 窗高，见 homeTopBlankVp）。
            // 内容高过视口时整组随 Scroll 上移，不再像以前那样被裁掉。
            // （1.0.178 的上下对半劈会把内容压到窗高 36% 一带，低于设计稿。）
            // 主页布局弹层的「Logo」微调叠加在锚点上：锚点是固定基数，负值
            // 可上移（1.0.178 弹性占位时代负值无效，那套限制随本次移除）。
            Blank()
              .height(this.homeTopBlankVp())

            if (this.custom.showLogo || this.incognito) {
              Row({ space: 8 }) {
                if (this.incognito) {
                  Image($r('app.media.aura_incognito'))
                    .width(26)
                    .height(26)
                    .fillColor($r('app.color.text_primary'))
                } else {
                  // 浏览器 logo（深浅色自适应：浅色 navy / 深色白）在文字前。
                  Image($r('app.media.orbira_logo'))
                    .width(42)
                    .height(30)
                    .draggable(false)
                }
                Text(this.incognito ? '无痕浏览' : 'Orbira')
                  .fontSize(34)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
              }
            }

            // Logo 行中心 ↔ 搜索框中心的锚点差 = 11.5% 窗高（设计稿 22% → 33.5%
            // 实测），减去两行半高（24 + 24）即为此处间隙；「搜索框」微调
            // searchOffset 照旧叠加。行高变化时两个锚点各偏半个误差，可接受。
            Blank()
              .height(Math.max(0, this.windowH * 0.115 - 48 + this.custom.searchOffset))

            if (this.custom.showSearch || this.incognito) {
              Row({ space: 10 }) {
                Image($r('app.media.chromium_search'))
                  .width(20)
                  .height(20)
                  .fillColor($r('app.color.text_secondary'))
                TextInput({ text: this.query, placeholder: '搜索或输入网址' })
                  .layoutWeight(1)
                  .height(48)
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                  .placeholderColor($r('app.color.text_secondary'))
                  .backgroundColor(Color.Transparent)
                  .enterKeyType(EnterKeyType.Go)
                  .onChange((value: string) => {
                    this.query = value;
                    // 与地址栏一致：输入即弹联想。
                    this.requestSuggest(value);
                  })
                  .onSubmit(() => {
                    this.submitQuery();
                  })
                Button({ type: ButtonType.Circle, stateEffect: true }) {
                  Image($r('app.media.chromium_scan'))
                    .width(20)
                    .height(20)
                    .fillColor($r('app.color.text_secondary'))
                }
                .width(36)
                .height(36)
                .backgroundColor(Color.Transparent)
                .accessibilityText('扫一扫')
                .onClick(() => {
                  this.startScan();
                })
              }
              .width('100%')
              .height(48)
              .borderRadius(24)
              .backgroundColor($r('app.color.surface_secondary'))
              .padding({ left: 16, right: 10 })
              .margin({ top: 0 })
            }

            // 联想列表：紧贴搜索框下方的一张卡（输入期间顶掉下面的磁贴，
            // 和地址栏联想一样是「盖住内容」而不是把内容推下去）。
            if (this.suggestActive()) {
              this.HomeSuggestCard()
            }

            if (this.incognito) {
              Text('无痕标签页不会保存浏览记录、Cookie 和表单数据；下载的文件和书签会保留。')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .textAlign(TextAlign.Center)
                .maxLines(3)
                .width('100%')
                .padding({ left: 12, right: 12 })
                .margin({ top: 16 })
            }

            Blank()
              .height(Math.max(0, 18 + this.custom.tilesOffset))

            if (!this.incognito && this.custom.showTiles) {
              if (this.tilesError) {
                Row({ space: 10 }) {
                  Text('书签加载失败')
                    .fontSize(13)
                    .fontColor($r('app.color.text_secondary'))
                  Text('重试')
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.accent_primary'))
                    .onClick(() => {
                      this.refreshBookmarks();
                    })
                }
                .width('100%')
                .height(40)
                .justifyContent(FlexAlign.Center)
              } else {
                // 联想期间只做 Visibility.None（节点留着），不要用 if 把整块磁贴
                // 拆掉 —— 那会连图标一起销毁重建，第一次弹联想时明显一顿。
                Column() {
                  this.BookmarkGrid()
                }
                .width('100%')
                .visibility(this.suggestActive() ? Visibility.None : Visibility.Visible)
              }
            }

            // 底部呼吸（替代原弹性占位）：底色由外层 Column 负责，
            // 内容比视口短时不必撑满，只留一点余量免得最后一行贴边。
            Blank()
              .height(24)
          }
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        // 必须显式顶端对齐：Scroll 在「内容比视口短」时默认居中，主页内容本来
        // 就比视口矮（竖屏 ~516 vs 832vp），不写这行整组会被下移半个差值
        // （用户实测「改完竖屏靠下了」）。项目里其余 Scroll 也都带这行。
        .align(Alignment.TopStart)
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.topSafeVp, left: 24, right: 24 })
      .backgroundColor(this.bgUri.length > 0 && !this.incognito
        ? Color.Transparent : $r('app.color.surface_primary'))

      // 1.0.96：主页右上角菜单按钮已去掉——简约风格底栏 dock 自带 ⋮ 菜单
      // （返回/前进/主页/标签页/菜单），Chrome 风格 dock 也有菜单槽位，主页
      // 页面再放一个是冗余入口。连带清理 MobileBrowserOverlay.onRequestMenuOpen
      // （auraRequestMenuOpen 信号已无发送方）。

      // 长按书签的自绘菜单卡。
      if (this.menuId.length > 0) {
        this.BookmarkMenuOverlay()
      }

      // 添加/编辑书签弹层。
      if (this.showAddBookmark) {
        this.BookmarkFormOverlay()
      }

      // 主页布局弹层。
      if (this.showSettings) {
        this.HomeSettingsOverlay()
      }
    }
    .width('100%')
    .height('100%')
    // 旋转/分屏/窗口尺寸变化都从这里重算锚点，但**不能直接用这一帧的 area**。
    // 实测（2026-10-27 横屏 logo 只剩一条弧线）：转屏时 onAreaChange 先以
    // 「宽度已变、高度还是键盘压矮后的值」的中间帧回调一次 —— 竖屏 419×920、
    // 键盘占 210vp 时，那一帧是 920×209，把它记成 windowH 后锚点全部错位：
    // Blank 从 68vp 塌到 22vp，Logo 行整条钻到顶部工具条背后。
    // 所以：宽度变了 → 用**物理屏**尺寸重算（display 会跟随方向），不采信中间帧；
    //       同宽下窗高变大（键盘收起 / 转屏收尾）→ 跟进；变小（键盘弹出）→ 忽略。
    .onAreaChange((_old: Area, now: Area): void => {
      const w: number = Number(now.width);
      const h: number = Number(now.height);
      if (w <= 0 || h <= 0) {
        return;
      }
      if (Math.abs(w - this.windowW) > 0.5) {
        this.windowW = w;
        let screenH: number = 0;
        try {
          const dsp = display.getDefaultDisplaySync();
          screenH = dsp.height / dsp.densityPixels;
        } catch (error) {
          screenH = 0;
        }
        this.windowH = screenH > 0 ? screenH : h;
        return;
      }
      if (h > this.windowH + 0.5) {
        this.windowH = h;
      }
    })
  }
}
