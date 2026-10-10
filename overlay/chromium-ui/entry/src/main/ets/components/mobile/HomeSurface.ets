/*
 * 手机主页（新标签页覆盖层）。
 * 当前标签停在 chrome://newtab 时，AuraShell 在本层之上铺出它：产品名、
 * 搜索框（与地址栏共用同一套"搜索或网址"规则）和常用网站（getTopSites，
 * 引擎按访问习惯生成）。
 */
import { BrowserCommandPayload, FaviconImage, TopSite } from 'engine';
import { common } from '@kit.AbilityKit';
import { promptAction, display } from '@kit.ArkUI';
import { normalizeAddress } from './ShellUtils';
import { ScanService } from './ScanService';
import { TopSitesBlocklist } from '../../utils/appearance/TopSitesBlocklist';
import { HomeShortcut, HomeShortcuts } from '../../utils/appearance/HomeShortcuts';

const TOP_SITE_RETRY_MS: number = 1500;
const MAX_TOP_SITE_RETRIES: number = 3;
// 长按菜单卡宽度（与 ⋮ 卡/网页长按卡同一家族，Lumie 风格）。
const SHORTCUT_MENU_CARD_VP: number = 190;

function initialOf(site: TopSite): string {
  const title = site.title.trim();
  if (title.length > 0) {
    return title.substring(0, 1).toUpperCase();
  }
  const url = site.url.trim();
  const schemeIndex = url.indexOf('://');
  const host = schemeIndex >= 0 ? url.substring(schemeIndex + 3) : url;
  return host.length > 0 ? host.substring(0, 1).toUpperCase() : '?';
}

// 归一化常用网站 url，让黑名单能跨"https://x.com"与"https://x.com/"这类写法匹配。
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

// 首页磁贴（手动快捷方式 + 引擎常用网站合成后的渲染单元）。
interface HomeTile {
  url: string;
  title: string;
  manual: boolean;
}

@Component
export struct HomeSurface {
  @StorageLink('auraTopSites') @Watch('onTopSitesChanged') topSitesJson: string = '';
  @StorageLink('auraFavicons') @Watch('onFaviconsChanged') faviconsJson: string = '';
  // 无痕会话：主页换成无痕的标题与说明，常用网站也不再列（那是普通 profile
  // 的访问习惯，跟这个会话无关）。
  @Prop incognito: boolean = false;
  // 状态栏避让由本组件内部承担（不再靠外层 padding）：surface_primary 背景
  // 因此能铺满状态栏条带——首页顶部与内容同色，不再露出垫底引擎页的灰条。
  @StorageProp('auraTopSafeVp') topSafeVp: number = 0;
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  @State private topSites: TopSite[] = [];
  // 手动添加的快捷方式（preferences 持久化），渲染排在常用网站前面。
  @State private shortcuts: HomeShortcut[] = [];
  // 合成后的磁贴渲染序列（手动+引擎、按用户排序）——落 @State 驱动更新。
  @State private tileList: HomeTile[] = [];
  // 用户排序表（normUrl 后的 url 有序列表，preferences 持久化）。
  private tileOrder: string[] = [];
  @State private showAddShortcut: boolean = false;
  @State private newShortcutTitle: string = '';
  @State private newShortcutUrl: string = '';
  // 「编辑快捷方式」：非空 = 正在编辑（值为原 url）。编辑引擎常用网站保存后
  // 会落成手动快捷方式，渲染按 url 去重自动顶掉原引擎项。
  @State private editingOriginalUrl: string = '';
  // 长按菜单：目标 url（'' = 收起）+ 是否手动项 + 菜单卡落点（vp，已钳制）。
  @State private shortcutMenuUrl: string = '';
  @State private shortcutMenuManual: boolean = false;
  @State private menuX: number = 0;
  @State private menuY: number = 0;
  private menuPressX: number = 0;
  private menuPressY: number = 0;
  private windowW: number = 360;
  private windowH: number = 780;
  @State private query: string = '';
  // url -> data URL, from getFavicons; sites without one keep the letter
  // avatar placeholder.
  @State private favicons: Map<string, string> = new Map();
  private requestSeq: number = 0;
  private retryTimer: number = -1;
  private retryCount: number = 0;
  // 用户长按移除过的 url（本地黑名单）：引擎会重新生成历史衍生的常用网站，
  // 只靠 removeTopSite 挡不住，解析 topSites 时在这里再过滤一遍。
  private blocklist: Set<string> = new Set();

  aboutToAppear(): void {
    const dsp = display.getDefaultDisplaySync();
    this.windowW = dsp.width / dsp.densityPixels;
    this.windowH = dsp.height / dsp.densityPixels;
    // 种子解析：@StorageLink 的初值不会触发 @Watch，而且引擎回的 JSON 与已存
    // 的那份逐字节相同时也不会有变更通知 —— 从网页回到主页时组件是新建的，
    // 只靠 @Watch 就永远等不到，常用网站会整排消失（实测）。
    this.onTopSitesChanged();
    this.onFaviconsChanged();
    this.reloadTopSites();
    this.scheduleRetry();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    TopSitesBlocklist.load(context).then((urls: Set<string>): void => {
      this.blocklist = urls;
      this.applyBlocklist();
    });
    HomeShortcuts.load(context).then((items: HomeShortcut[]): void => {
      this.shortcuts = items;
      HomeShortcuts.loadOrder(context).then((order: string[]): void => {
        this.tileOrder = order;
        this.rebuildTiles();
      });
      this.requestFavicons();
    });
  }

  aboutToDisappear(): void {
    this.clearRetry();
  }

  // 引擎还没起来 / 回包丢了时的兜底：1.5 秒后仍为空就再问一次，最多三次。
  private scheduleRetry(): void {
    this.clearRetry();
    if (this.retryCount >= MAX_TOP_SITE_RETRIES) {
      return;
    }
    this.retryCount += 1;
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1;
      if (this.topSites.length === 0) {
        this.reloadTopSites();
        this.scheduleRetry();
      }
    }, TOP_SITE_RETRY_MS);
  }

  private clearRetry(): void {
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  // 合成磁贴渲染序列：手动项在前、引擎项在后（来源各自有序），再按用户
  // 排序表（tileOrder）重排——表里有的按表位次，没有的按原顺序垫后。
  // 数据源（shortcuts/topSites/blocklist/order）任一变化后都要调用。
  private rebuildTiles(): void {
    const seq: HomeTile[] = [];
    for (const item of this.shortcuts) {
      seq.push({ url: item.url, title: item.title, manual: true } as HomeTile);
    }
    for (const site of this.visibleTopSites()) {
      seq.push({ url: site.url, title: site.title, manual: false } as HomeTile);
    }
    const ranked: HomeTile[] = [];
    const used: boolean[] = [];
    for (let i = 0; i < seq.length; i++) {
      used.push(false);
    }
    for (const ou of this.tileOrder) {
      const target = normUrl(ou);
      for (let i = 0; i < seq.length; i++) {
        if (!used[i] && normUrl(seq[i].url) === target) {
          used[i] = true;
          ranked.push(seq[i]);
          break;
        }
      }
    }
    for (let i = 0; i < seq.length; i++) {
      if (!used[i]) {
        ranked.push(seq[i]);
      }
    }
    this.tileList = ranked;
  }

  // 上移/下移磁贴：交换排序表相邻项并持久化（引擎项也支持——排序表覆盖
  // 全部磁贴；首/末项越界时静默忽略）。
  private moveTile(url: string, dir: number): void {
    const urls: string[] = [];
    for (const tile of this.tileList) {
      urls.push(normUrl(tile.url));
    }
    const idx = urls.indexOf(normUrl(url));
    const j = idx + dir;
    if (idx < 0 || j < 0 || j >= urls.length) {
      return;
    }
    const tmp = urls[idx];
    urls[idx] = urls[j];
    urls[j] = tmp;
    this.tileOrder = urls;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    HomeShortcuts.saveOrder(context, urls);
    this.rebuildTiles();
  }

  // 长按 = 自绘操作菜单（用户定案 2026-10-10：弃用系统 ActionSheet，只留
  // 「编辑 / 删除」，样式与 ⋮ 卡/网页长按卡同一家族 menu_glass 实底）。
  // 菜单卡弹在按压点附近（钳制在屏内）；全屏透明层负责点外收起。
  private showSiteActions(site: TopSite, isManual: boolean): void {
    const cardW = SHORTCUT_MENU_CARD_VP;
    const cardH = 204;
    this.menuX = Math.min(Math.max(this.menuPressX - cardW / 2, 12),
      Math.max(12, this.windowW - cardW - 12));
    this.menuY = Math.min(this.menuPressY + 8, Math.max(12, this.windowH - cardH - 96));
    this.shortcutMenuManual = isManual;
    this.shortcutMenuUrl = site.url;
  }

  // 「编辑」：手动项就地更新；引擎常用网站改完保存后落成手动项。
  private beginEditFromMenu(): void {
    const url = this.shortcutMenuUrl;
    const manual = this.shortcutMenuManual;
    this.shortcutMenuUrl = '';
    let title = '';
    if (manual) {
      for (const item of this.shortcuts) {
        if (item.url === url) {
          title = item.title;
          break;
        }
      }
    } else {
      for (const site of this.topSites) {
        if (site.url === url) {
          title = site.title;
          break;
        }
      }
    }
    this.editingOriginalUrl = url;
    this.newShortcutTitle = title;
    this.newShortcutUrl = url;
    this.showAddShortcut = true;
  }

  private deleteFromMenu(): void {
    const url = this.shortcutMenuUrl;
    const manual = this.shortcutMenuManual;
    this.shortcutMenuUrl = '';
    if (manual) {
      this.removeManualShortcut(url);
      return;
    }
    for (const site of this.topSites) {
      if (site.url === url) {
        this.confirmRemoveSite(site);
        return;
      }
    }
  }

  private closeAddShortcut(): void {
    this.showAddShortcut = false;
    this.editingOriginalUrl = '';
    this.newShortcutTitle = '';
    this.newShortcutUrl = '';
  }

  private removeManualShortcut(url: string): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    HomeShortcuts.remove(context, url).then((items: HomeShortcut[]): void => {
      this.shortcuts = items;
      this.rebuildTiles();
      this.getUIContext().getPromptAction().showToast({ message: '已移除', duration: 1500 });
    });
  }

  private confirmAddShortcut(): void {
    const url = normalizeAddress(this.newShortcutUrl.trim());
    if (url.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '请输入网址', duration: 1500 });
      return;
    }
    const title = this.newShortcutTitle.trim();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    const editing = this.editingOriginalUrl.length > 0;
    let existsManual = false;
    if (editing) {
      for (const item of this.shortcuts) {
        if (item.url === this.editingOriginalUrl) {
          existsManual = true;
          break;
        }
      }
    }
    const promise = editing && existsManual
      ? HomeShortcuts.update(context, this.editingOriginalUrl, title, url)
      : HomeShortcuts.add(context, title, url);
    promise.then((items: HomeShortcut[]): void => {
      this.shortcuts = items;
      this.rebuildTiles();
      this.closeAddShortcut();
      this.requestFavicons();
      const message = editing && existsManual ? '已保存' : '已添加到主页';
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1500 });
    });
  }

  // 长按移除（引擎常用网站）：只把这一条加进引擎的黑名单（removeTopSite），
  // 下次 getTopSites 就不会再出现；顺手把本地列表也去掉，不用等回包。
  private confirmRemoveSite(site: TopSite): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '移除快捷方式',
      message: site.title.length > 0 ? site.title : site.url,
      buttons: [
        { text: '取消', color: '#5F6368' },
        { text: '移除', color: '#E24B4A' }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (result.index !== 1) {
        return;
      }
      this.onCommand({ command: 'removeTopSite', url: site.url });
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
      const norm = normUrl(site.url);
      TopSitesBlocklist.add(context, norm);
      this.blocklist.add(norm);
      const remaining: TopSite[] = [];
      for (const item of this.topSites) {
        if (normUrl(item.url) !== norm) {
          remaining.push(item);
        }
      }
      this.topSites = remaining;
      this.rebuildTiles();
      this.getUIContext().getPromptAction().showToast({ message: '已移除', duration: 1500 });
    }).catch((error: Error): void => {
    });
  }

  // 本地黑名单过滤：removeTopSite 对历史衍生的常用网站不生效（引擎会按
  // 访问习惯重新生成），移除过的 url 在这里挡回去。
  private applyBlocklist(): void {
    if (this.blocklist.size === 0 || this.topSites.length === 0) {
      return;
    }
    const kept: TopSite[] = [];
    for (const site of this.topSites) {
      if (!this.blocklist.has(normUrl(site.url))) {
        kept.push(site);
      }
    }
    if (kept.length !== this.topSites.length) {
      this.topSites = kept;
    }
  }

  private reloadTopSites(): void {
    this.requestSeq += 1;
    this.onCommand({ command: 'getTopSites', requestId: this.requestSeq, count: 8 });
  }

  private onTopSitesChanged(): void {
    if (this.topSitesJson.length === 0) {
      return;
    }
    try {
      this.topSites = JSON.parse(this.topSitesJson) as TopSite[];
      this.applyBlocklist();
      this.rebuildTiles();
      if (this.topSites.length > 0) {
        this.clearRetry();
      }
      this.requestFavicons();
    } catch (error) {
    }
  }

  // Ask the engine for site icons in one batch (max 100). Misses simply
  // don't come back -- the letter placeholder covers them.
  private requestFavicons(): void {
    if (this.topSites.length === 0) {
      return;
    }
    const urls: string[] = [];
    for (const site of this.topSites) {
      if (site.url && site.url.length > 0) {
        urls.push(site.url);
      }
    }
    for (const item of this.shortcuts) {
      if (item.url.length > 0) {
        urls.push(item.url);
      }
    }
    if (urls.length === 0) {
      return;
    }
    this.requestSeq += 1;
    this.onCommand({ command: 'getFavicons', requestId: this.requestSeq, urls: urls, sizeVp: 40 });
  }

  private onFaviconsChanged(): void {
    if (this.faviconsJson.length === 0) {
      return;
    }
    try {
      const items: FaviconImage[] = JSON.parse(this.faviconsJson) as FaviconImage[];
      const map: Map<string, string> = new Map();
      for (const item of items) {
        if (item.pngBase64 && item.pngBase64.length > 0) {
          map.set(item.url, `data:image/png;base64,${item.pngBase64}`);
        }
      }
      this.favicons = map;
    } catch (error) {
    }
  }

  private faviconFor(site: TopSite): string {
    if (site.url && site.url.length > 0) {
      const value = this.favicons.get(site.url);
      if (value) {
        return value;
      }
    }
    return '';
  }

  private submitQuery(): void {
    const target = normalizeAddress(this.query);
    this.query = '';
    if (target.length > 0) {
      this.onCommand({ command: 'navigate', url: target });
    }
  }

  private openSite(site: TopSite): void {
    if (site.url.length > 0) {
      this.onCommand({ command: 'navigate', url: site.url });
    }
  }

  // 扫一扫: decoded text follows the same URL/search rules as typed input.
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

  // 常用网站里滤掉手动添加过的（避免双份）。
  private visibleTopSites(): TopSite[] {
    if (this.shortcuts.length === 0) {
      return this.topSites;
    }
    const manual = new Set<string>();
    for (const item of this.shortcuts) {
      manual.add(normUrl(item.url));
    }
    const out: TopSite[] = [];
    for (const site of this.topSites) {
      if (!manual.has(normUrl(site.url))) {
        out.push(site);
      }
    }
    return out;
  }

  // 一个快捷方式磁贴：favicon（缺失时首字母占位）+ 标题。
  // 单击 = 打开；长按 = 操作菜单（打开/复制链接/移除）。
  @Builder
  private ShortcutTile(site: TopSite, isManual: boolean) {
    Column({ space: 7 }) {
      if (this.faviconFor(site).length > 0) {
        Image(this.faviconFor(site))
          .width(54)
          .height(54)
          .borderRadius(15)
          .objectFit(ImageFit.Cover)
          // Image 默认 draggable(true)：长按图标会启动拖拽、抢占磁贴的
          // LongPressGesture（长按文字正常、长按图标无反应的根因）。
          .draggable(false)
          .backgroundColor($r('app.color.surface_secondary'))
      } else {
        Text(initialOf(site))
          .fontSize(22)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .textAlign(TextAlign.Center)
          .width(54)
          .height(54)
          .borderRadius(15)
          .backgroundColor($r('app.color.surface_secondary'))
      }
      Text(site.title.length > 0 ? site.title : site.url)
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
    // 用 GestureGroup 显式声明"单击=打开 / 长按=操作菜单"，避免隐式 onClick 的
    // tap 手势抢占长按导致长按无反应。Exclusive：两者互斥，先识别到的生效。
    .gesture(GestureGroup(GestureMode.Exclusive,
      LongPressGesture({ repeat: false })
        .onAction((): void => {
          this.showSiteActions(site, isManual);
        }),
      TapGesture({ count: 1 })
        .onAction((): void => {
          this.openSite(site);
        })
    ))
  }

  // 长按快捷方式的自绘菜单卡：与 ⋮ 卡/网页长按卡同一套（menu_glass 全
  // 不透明 + 圆角 22 + 阴影，行高 48 图标 21 文字 15）。只留「编辑 / 删除」。
  // 全屏透明层负责点外收起；卡片 .position 在按压点附近（showSiteActions 已钳制）。
  @Builder
  private ShortcutMenuOverlay() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .onClick(() => {
          this.shortcutMenuUrl = '';
        })

      Column() {
        this.ShortcutMenuRow($r('app.media.aura_chevron'), '上移', (): void => {
          const url = this.shortcutMenuUrl;
          this.shortcutMenuUrl = '';
          this.moveTile(url, -1);
        }, -90)
        this.ShortcutMenuRow($r('app.media.aura_chevron'), '下移', (): void => {
          const url = this.shortcutMenuUrl;
          this.shortcutMenuUrl = '';
          this.moveTile(url, 1);
        }, 90)
        this.ShortcutMenuRow($r('app.media.aura_edit'), '编辑', (): void => {
          this.beginEditFromMenu();
        }, 0)
        this.ShortcutMenuRow($r('app.media.aura_trash'), '删除', (): void => {
          this.deleteFromMenu();
        }, 0)
      }
      .width(SHORTCUT_MENU_CARD_VP)
      .padding({ top: 6, bottom: 6 })
      .borderRadius(22)
      .backgroundColor($r('app.color.menu_glass'))
      .shadow({ radius: 26, color: $r('app.color.shadow'), offsetY: 8 })
      .position({ x: this.menuX, y: this.menuY })
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.opacity(0)
          .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 })),
        TransitionEffect.opacity(0)
      ).animation({ duration: 180, curve: Curve.Friction }))
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private ShortcutMenuRow(icon: Resource, label: string, action: () => void, iconAngle: number) {
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

  // 添加/编辑快捷方式弹层：卡片居中、遮罩盖满全屏（根 Stack 悬浮层）。
  // 样式统一到自绘体系：menu_glass 实底 + 圆角 22 + 阴影；按钮为自绘 Row
  //（血泪 #9：系统 Button 的默认状态蒙层/样式与自绘体系不统一）。
  @Builder
  private AddShortcutOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.modal_scrim'))
        .onClick(() => {
          this.closeAddShortcut();
        })

      Row() {
      Column({ space: 14 }) {
        Text(this.editingOriginalUrl.length > 0 ? '编辑快捷方式' : '添加快捷方式')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')

        Column({ space: 6 }) {
          Text('名称')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          TextInput({ text: this.newShortcutTitle, placeholder: '网站名称（可留空）' })
            .height(46)
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_secondary'))
            .backgroundColor($r('app.color.surface_secondary'))
            .borderRadius(12)
            .onChange((value: string): void => {
              this.newShortcutTitle = value;
            })
        }
        .width('100%')

        Column({ space: 6 }) {
          Text('网址')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          TextInput({ text: this.newShortcutUrl, placeholder: 'https://…' })
            .height(46)
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_secondary'))
            .backgroundColor($r('app.color.surface_secondary'))
            .borderRadius(12)
            .onChange((value: string): void => {
              this.newShortcutUrl = value;
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
            this.closeAddShortcut();
          })

          Row() {
            Text(this.editingOriginalUrl.length > 0 ? '保存' : '添加')
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
            this.confirmAddShortcut();
          })
        }
        .width('100%')
      }
      .width('100%')
      .padding(20)
      .borderRadius(22)
      .backgroundColor($r('app.color.menu_glass'))
      .shadow({ radius: 26, color: $r('app.color.shadow'), offsetY: 8 })
      .margin({ left: 0, right: 0 })
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.opacity(0)
          .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 })),
        TransitionEffect.opacity(0)
      ).animation({ duration: 200, curve: Curve.Friction }))
      }
      .padding({ left: 44, right: 44 })
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  build() {
    // 根级 Stack：内容层 + 悬浮层（长按菜单 / 添加弹窗）。悬浮层必须是根
    // Stack 的直接子节点——之前添加弹窗放在内容 Column 的流式布局里，
    // height('100%') 从网格底部又撑了一整屏，遮罩只盖半屏、卡片被顶出屏幕
    // （真机截图：只见半张卡）。挂在根 Stack 上 = viewport 固定，居中可见。
    Stack({ alignContent: Alignment.TopStart }) {
    Column() {
      Blank()
        .height('15%')

      Row({ space: 8 }) {
        if (this.incognito) {
          Image($r('app.media.aura_incognito'))
            .width(26)
            .height(26)
            .fillColor($r('app.color.text_primary'))
        }
        Text(this.incognito ? '无痕浏览' : 'Orbira')
          .fontSize(34)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
      }

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
      .margin({ top: 26 })

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

      if (!this.incognito) {
        Flex({ wrap: FlexWrap.Wrap }) {
          // 磁贴统一从 tileList 渲染（手动+引擎合成、按用户排序持久化，
          // 长按菜单「上移/下移」排序）。
          ForEach(this.tileList, (tile: HomeTile) => {
            this.ShortcutTile({ url: tile.url, title: tile.title } as TopSite, tile.manual)
          }, (tile: HomeTile): string => normUrl(tile.url))

          // 「添加快捷方式」磁贴
          Column({ space: 7 }) {
            Column() {
              Image($r('app.media.aura_plus'))
                .width(26)
                .height(26)
                .fillColor($r('app.color.icon_secondary'))
            }
            .width(54)
            .height(54)
            .borderRadius(15)
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
            this.showAddShortcut = true;
          })
        }
        .width('100%')
        .margin({ top: 18 })
      }

      Blank()
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topSafeVp, left: 24, right: 24 })
    .backgroundColor($r('app.color.surface_primary'))

    // 长按快捷方式的自绘菜单卡（Lumie 风格）。
    if (this.shortcutMenuUrl.length > 0) {
      this.ShortcutMenuOverlay()
    }

    // 添加/编辑快捷方式弹层。
    if (this.showAddShortcut) {
      this.AddShortcutOverlay()
    }
    }
    .width('100%')
    .height('100%')
  }
}
