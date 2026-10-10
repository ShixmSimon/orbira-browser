/*
 * 手机自绘设置页（参考外壳扩展）。
 * 数据流：getPrefs / getSearchEngines / getAboutInfo -> 对应事件
 * （AuraShell 转存到 'auraPanelPrefs' / 'auraPanelEngines' / 'auraPanelAbout'）。
 * setPref 成功后引擎推 prefsChanged（转存到 'auraPanelEvent'），本页据此重拉。
 */
import { common } from '@kit.AbilityKit';
import { AppearanceSettings, ColorModeSetting } from '../../utils/appearance/AppearanceSettings';
import { GlassPage, glassBottomInsetVp, glassHeaderInsetVp } from './GlassPage';
import { ShellUiPrefs } from '../../utils/appearance/ShellUiPrefs';
import { HuaweiAccountInfo } from '../../utils/account/HuaweiAccountService';
import { HuaweiAccountView } from './AccountPanel';
import { AuraNavIconRow, AuraSectionLabel } from './LumieKit';
import {
  BrowsingDataType,
  BrowsingDataTimeRange,
  BrowserCommandPayload,
  SearchEngine,
  ShellPrefKey,
  ShellPrefValue
} from 'engine';

interface PrefRow {
  key: ShellPrefKey;
  label: string;
}

const PREF_ROWS: PrefRow[] = [
  { key: 'blockThirdPartyCookies', label: '阻止第三方 Cookie' },
  { key: 'javascriptEnabled', label: '启用 JavaScript' },
  { key: 'popupsBlocked', label: '拦截弹窗' },
  { key: 'doNotTrack', label: '发送"请勿追踪"请求' },
  { key: 'preloadPages', label: '预加载网页' },
  { key: 'forceDarkWebContents', label: '网页强制深色' },
  { key: 'downloadAskWhereToSave', label: '下载前询问' }
];

interface RangeRow {
  key: BrowsingDataTimeRange;
  label: string;
}

const CLEAR_RANGES: RangeRow[] = [
  { key: 'lastHour', label: '过去 1 小时' },
  { key: 'lastDay', label: '过去 24 小时' },
  { key: 'lastWeek', label: '过去 7 天' },
  { key: 'last4Weeks', label: '过去 4 周' },
  { key: 'all', label: '全部时间' }
];

// Passwords are deliberately left out: clearing them is a separate, riskier
// action the settings page does not offer yet.
const CLEAR_TYPES: BrowsingDataType[] = ['history', 'cookies', 'cache', 'siteSettings', 'formData', 'downloads'];

interface PrefToggleItem {
  key: ShellPrefKey;
  label: string;
  value: boolean;
}

// 设置项检索：把散在各分区里的条目集中登记一次（名称 + 关键词 + 分区 +
// 打开方式）。搜索只过滤这个清单，不改动既有分区 UI。
interface SettingsEntry {
  id: string;
  // 匹配范围：标题 + 副标题 + 关键词（同义词、英文、别称）。
  title: string;
  subtitle: string;
  keywords: string[];
  section: string;
  // 点击后如何到达：直接跳二级页、由外壳打开独立页，或是某个开关。
  kind: 'page' | 'shell' | 'toggle' | 'externalToggle';
}

const SETTINGS_ENTRIES: SettingsEntry[] = [
  { id: 'searchEngine', title: '搜索引擎', subtitle: '选择默认搜索引擎',
    keywords: ['engine', 'search', '默认', '百度', 'google', '必应', '搜狗'], section: '常规', kind: 'page' },
  { id: 'extensions', title: '扩展程序', subtitle: '管理已安装的扩展',
    keywords: ['extension', '插件', 'addon'], section: '常规', kind: 'shell' },

  { id: 'sitePermissions', title: '网站权限', subtitle: '各网站的相机、定位等权限',
    keywords: ['permission', '权限', '相机', '定位', '麦克风'], section: '隐私与安全', kind: 'shell' },
  { id: 'externalAppLinks', title: '允许跳转本机应用', subtitle: '知乎、B站这类链接交给对应应用打开',
    keywords: ['external', '跳转', '应用', 'scheme', '知乎', 'B站', 'bilibili', '外部'],
    section: '隐私与安全', kind: 'externalToggle' },
  { id: 'passwords', title: '密码', subtitle: '查看和管理已保存的密码',
    keywords: ['password', '密码', '账号', '登录', 'vault'], section: '隐私与安全', kind: 'shell' },
  { id: 'blockThirdPartyCookies', title: '阻止第三方 Cookie', subtitle: '',
    keywords: ['cookie', '第三方', '追踪', '隐私'], section: '隐私与安全', kind: 'toggle' },
  { id: 'popupsBlocked', title: '拦截弹窗', subtitle: '',
    keywords: ['popup', '弹窗', '拦截', '广告'], section: '隐私与安全', kind: 'toggle' },
  { id: 'doNotTrack', title: '发送"请勿追踪"请求', subtitle: '',
    keywords: ['dnt', '请勿追踪', '追踪', '隐私'], section: '隐私与安全', kind: 'toggle' },
  { id: 'clearBrowsingData', title: '清除浏览数据', subtitle: '历史记录、Cookie、缓存等',
    keywords: ['clear', '清除', '清理', '历史', '缓存', 'cache', 'history'],
    section: '隐私与安全', kind: 'page' },

  { id: 'darkMode', title: '深色模式', subtitle: '浅色、深色或跟随系统',
    keywords: ['dark', '深色', '夜间', '主题', 'theme', '外观'], section: '外观', kind: 'page' },
  { id: 'hideStatusBarOnScroll', title: '上滑时隐藏状态栏', subtitle: '地址栏收起时一起隐藏，网页铺满全屏',
    keywords: ['状态栏', '全屏', '隐藏', '上滑'], section: '外观', kind: 'toggle' },
  { id: 'hideTopBarOnScroll', title: '滚动时隐藏地址栏', subtitle: '向下滚动时收起顶部地址栏',
    keywords: ['地址栏', '顶栏', '滚动', '隐藏'], section: '外观', kind: 'toggle' },
  { id: 'hideDockOnScroll', title: '滚动时隐藏底部栏', subtitle: '向下滚动时收起底部栏',
    keywords: ['底部栏', 'dock', '滚动', '隐藏'], section: '外观', kind: 'toggle' },
  { id: 'zoom', title: '网页缩放', subtitle: '整页一起放大或缩小',
    keywords: ['zoom', '缩放', '字体', '放大', '缩小', 'textScale'], section: '外观', kind: 'page' },
  { id: 'forceDarkWebContents', title: '网页强制深色', subtitle: '',
    keywords: ['dark', '深色', '网页', '强制'], section: '外观', kind: 'toggle' },

  { id: 'downloadAskWhereToSave', title: '下载前询问', subtitle: '安装包和未知文件总是询问',
    keywords: ['download', '下载', '询问', '保存位置'], section: '下载', kind: 'toggle' },

  { id: 'javascriptEnabled', title: '启用 JavaScript', subtitle: '',
    keywords: ['javascript', 'js', '脚本'], section: '高级', kind: 'toggle' },
  { id: 'preloadPages', title: '预加载网页', subtitle: '',
    keywords: ['preload', '预加载', '预读', '加速'], section: '高级', kind: 'toggle' }
];

@Component
export struct SettingsPanel {
  @StorageLink('auraPanelPrefs') @Watch('onPrefsPayload') prefsJson: string = '';
  @StorageLink('auraPanelEngines') @Watch('onEnginesPayload') enginesJson: string = '';
  @StorageLink('auraPanelAbout') @Watch('onAboutPayload') aboutJson: string = '';
  @StorageLink('auraPanelEvent') @Watch('onPanelEvent') panelEventJson: string = '';
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  onBack: () => void = (): void => {};
  onOpenExtensions: () => void = (): void => {};
  onOpenSitePermissions: () => void = (): void => {};
  onOpenPasswords: () => void = (): void => {};

  @State private page: string = 'main';
  // 设置检索：输入框内容 + 是否展开（点放大镜展开，清空或返回收起）。
  @State private searchText: string = '';
  @State private searching: boolean = false;
  // 渐变模糊滚动效果按官方要求 bindToScrollable：主面板与搜索引擎页各一个。
  private mainScroller: Scroller = new Scroller();
  private enginesScroller: Scroller = new Scroller();
  private searchScroller: Scroller = new Scroller();
  @State private toggleItems: PrefToggleItem[] = [];
  @State private engines: SearchEngine[] = [];
  @State private defaultEngineName: string = '';
  @State private chromiumVersion: string = '';
  @State private clearRange: BrowsingDataTimeRange = 'last4Weeks';
  @State private clearing: boolean = false;
  @State private colorModeSetting: ColorModeSetting = 'system';
  @State private textScalePercent: number = 100;
  @StorageLink('auraHideStatusBarOnScroll') hideStatusBarOnScroll: boolean = false;
  @StorageLink('auraHideTopBarOnScroll') hideTopBarOnScroll: boolean = true;
  @StorageLink('auraHideDockOnScroll') hideDockOnScroll: boolean = true;
  @StorageLink('auraExternalAppLinks') externalAppLinks: boolean = true;
  @StorageLink('auraHuaweiAccount') accountJson: string = '';
  private requestSeq: number = 0;
  private retryTimer: number = -1;

  aboutToAppear(): void {
    // A @Watch callback does not run for the value a @StorageLink is created
    // with, and a byte-identical engine reply raises no change either, so a
    // re-opened settings page would otherwise stay half empty. Seed the view
    // from the stored payload first, then refresh it from the engine.
    this.onPrefsPayload();
    this.onEnginesPayload();
    this.onAboutPayload();
    this.reloadPrefs();
    this.reloadEngines();
    this.reloadAbout();
    this.loadColorModeSetting();
    // One retry in case the first round was sent before the engine answered.
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1;
      if (this.toggleItems.length === 0) {
        this.reloadPrefs();
      }
      if (this.engines.length === 0) {
        this.reloadEngines();
      }
      if (this.chromiumVersion.length === 0) {
        this.reloadAbout();
      }
    }, 1500);
  }

  aboutToDisappear(): void {
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  private reloadPrefs(): void {
    this.requestSeq += 1;
    // No `keys`: the engine returns every preference it supports.
    this.onCommand({ command: 'getPrefs', requestId: this.requestSeq });
  }

  private reloadEngines(): void {
    this.requestSeq += 1;
    this.onCommand({ command: 'getSearchEngines', requestId: this.requestSeq });
  }

  private reloadAbout(): void {
    this.requestSeq += 1;
    this.onCommand({ command: 'getAboutInfo', requestId: this.requestSeq });
  }

  // 华为账号入口隐藏后，下面三个方法暂无调用方；保留以便随时恢复入口。
  // private accountInfo(): HuaweiAccountInfo {
  //   if (this.accountJson.length === 0) {
  //     return { signedIn: false, openID: '', unionID: '' };
  //   }
  //   try {
  //     const value = JSON.parse(this.accountJson) as HuaweiAccountInfo;
  //     return {
  //       signedIn: value.signedIn === true,
  //       openID: String(value.openID ?? ''),
  //       unionID: String(value.unionID ?? '')
  //     };
  //   } catch (error) {
  //     return { signedIn: false, openID: '', unionID: '' };
  //   }
  // }
  //
  // private accountTitle(): string {
  //   return this.accountInfo().signedIn ? '已登录华为账号' : '华为账号';
  // }
  //
  // private accountSubtitle(): string {
  //   return this.accountInfo().signedIn ? '已登录' : '登录后同步书签和密码';
  // }

  private onPrefsPayload(): void {
    if (this.prefsJson.length === 0) {
      return;
    }
    try {
      const values = JSON.parse(this.prefsJson) as ShellPrefValue[];
      const map = new Map<string, boolean>();
      values.forEach((item: ShellPrefValue): void => {
        map.set(item.key, item.value === true);
      });
      const next: PrefToggleItem[] = PREF_ROWS.map((row: PrefRow): PrefToggleItem => ({
        key: row.key,
        label: row.label,
        value: map.get(row.key) ?? false
      }));
      this.toggleItems = next;
      values.forEach((item: ShellPrefValue): void => {
        if (item.key === 'textScale' && typeof item.value === 'number') {
          this.textScalePercent = item.value;
        }
      });
    } catch (error) {
    }
  }

  private onEnginesPayload(): void {
    if (this.enginesJson.length === 0) {
      return;
    }
    try {
      const engines = JSON.parse(this.enginesJson) as SearchEngine[];
      this.engines = engines;
      let defaultName = '';
      engines.forEach((engine: SearchEngine): void => {
        if (engine.isDefault) {
          defaultName = engine.name;
        }
      });
      this.defaultEngineName = defaultName;
    } catch (error) {
    }
  }

  private onAboutPayload(): void {
    if (this.aboutJson.length === 0) {
      return;
    }
    try {
      const about = JSON.parse(this.aboutJson) as Record<string, Object>;
      this.chromiumVersion = String(about['chromiumVersion'] ?? '');
    } catch (error) {
    }
  }

  private onPanelEvent(): void {
    if (this.panelEventJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.panelEventJson) as Record<string, Object>;
      const kind = String(payload['kind'] ?? '');
      if (kind === 'prefsChanged') {
        this.reloadPrefs();
      } else if (kind === 'clearBrowsingDataDone') {
        this.clearing = false;
        AlertDialog.show({
          title: '已清除',
          message: '所选时间范围内的浏览数据已删除。',
          confirm: {
            value: '好的',
            action: (): void => {
            }
          }
        });
        this.page = 'main';
      }
    } catch (error) {
    }
  }

  private setPref(key: ShellPrefKey, value: boolean): void {
    const next: PrefToggleItem[] = [];
    this.toggleItems.forEach((item: PrefToggleItem): void => {
      next.push({
        key: item.key,
        label: item.label,
        value: item.key === key ? value : item.value
      });
    });
    this.toggleItems = next;
    this.onCommand({ command: 'setPref', key: key, value: value });
  }

  private chooseEngine(engine: SearchEngine): void {
    this.onCommand({ command: 'setDefaultSearchEngine', id: engine.id });
    this.page = 'main';
    setTimeout((): void => {
      this.reloadEngines();
    }, 400);
  }

  private loadColorModeSetting(): void {
    const context = this.getUIContext().getHostContext() as common.Context | undefined;
    if (!context) {
      return;
    }
    AppearanceSettings.load(context).then((mode: ColorModeSetting): void => {
      this.colorModeSetting = mode;
    });
  }

  private colorModeLabel(): string {
    if (this.colorModeSetting === 'dark') {
      return '深色';
    }
    return this.colorModeSetting === 'light' ? '浅色' : '跟随系统';
  }

  // ---- 设置检索 ----

  private searchQuery(): string {
    return this.searchText.trim().toLowerCase();
  }

  private matchedEntries(): SettingsEntry[] {
    const query = this.searchQuery();
    if (query.length === 0) {
      return SETTINGS_ENTRIES;
    }
    const hits: SettingsEntry[] = [];
    SETTINGS_ENTRIES.forEach((entry: SettingsEntry): void => {
      const haystack: string =
        `${entry.title} ${entry.subtitle} ${entry.section} ${entry.keywords.join(' ')}`.toLowerCase();
      if (haystack.indexOf(query) >= 0) {
        hits.push(entry);
      }
    });
    return hits;
  }

  private entryValue(entry: SettingsEntry): boolean {
    if (entry.kind === 'externalToggle') {
      return this.externalAppLinks;
    }
    if (entry.id === 'hideStatusBarOnScroll') {
      return this.hideStatusBarOnScroll;
    }
    if (entry.id === 'hideTopBarOnScroll') {
      return this.hideTopBarOnScroll;
    }
    if (entry.id === 'hideDockOnScroll') {
      return this.hideDockOnScroll;
    }
    return this.prefValue(entry.id as ShellPrefKey);
  }

  private toggleEntry(entry: SettingsEntry, value: boolean): void {
    const context = this.getUIContext().getHostContext() as common.Context | undefined;
    if (entry.kind === 'externalToggle') {
      AppStorage.setOrCreate('auraExternalAppLinks', value);
      if (context) {
        ShellUiPrefs.saveExternalAppLinks(context, value);
      }
      return;
    }
    if (entry.id === 'hideStatusBarOnScroll') {
      AppStorage.setOrCreate('auraHideStatusBarOnScroll', value);
      if (context) {
        ShellUiPrefs.saveHideStatusBar(context, value);
      }
      return;
    }
    if (entry.id === 'hideTopBarOnScroll') {
      AppStorage.setOrCreate('auraHideTopBarOnScroll', value);
      if (context) {
        ShellUiPrefs.saveHideTopBar(context, value);
      }
      return;
    }
    if (entry.id === 'hideDockOnScroll') {
      AppStorage.setOrCreate('auraHideDockOnScroll', value);
      if (context) {
        ShellUiPrefs.saveHideDock(context, value);
      }
      return;
    }
    this.setPref(entry.id as ShellPrefKey, value);
  }

  // 搜索结果点击：开关就地切换，其余跳到对应页。
  private openEntry(entry: SettingsEntry): void {
    if (entry.kind === 'toggle' || entry.kind === 'externalToggle' ||
      (entry.kind === 'page' && (entry.id === 'hideStatusBarOnScroll' ||
        entry.id === 'hideTopBarOnScroll' || entry.id === 'hideDockOnScroll'))) {
      this.toggleEntry(entry, !this.entryValue(entry));
      return;
    }
    if (entry.id === 'searchEngine') {
      this.leaveSearch('engines');
    } else if (entry.id === 'clearBrowsingData') {
      this.leaveSearch('clear');
    } else if (entry.id === 'darkMode') {
      this.leaveSearch('appearance');
    } else if (entry.id === 'zoom') {
      this.leaveSearch('zoom');
    } else if (entry.id === 'passwords') {
      this.onOpenPasswords();
    } else if (entry.id === 'sitePermissions') {
      this.onOpenSitePermissions();
    } else if (entry.id === 'extensions') {
      this.onOpenExtensions();
    }
  }

  // 收起搜索再跳页：避免二级页返回后还停在搜索态。
  private leaveSearch(target: string): void {
    this.searching = false;
    this.searchText = '';
    this.page = target;
  }

  private chooseColorMode(mode: ColorModeSetting): void {
    this.colorModeSetting = mode;
    const context = this.getUIContext().getHostContext() as common.Context | undefined;
    if (!context) {
      return;
    }
    AppearanceSettings.save(context, mode).then((): void => {
      AppearanceSettings.apply(context, mode);
      // The shell UI re-resolves its resources immediately, but the engine
      // re-colors web content on load -- give it a beat, then reload the
      // page so the switch reads as live.
      setTimeout((): void => {
        this.onCommand({ command: 'reload' });
      }, 400);
    });
  }

  private clearData(): void {
    this.clearing = true;
    this.requestSeq += 1;
    this.onCommand({
      command: 'clearBrowsingData',
      requestId: this.requestSeq,
      types: CLEAR_TYPES,
      timeRange: this.clearRange
    });
  }

  // 标题栏（含圆形玻璃返回钮）交给 GlassPage —— 它把标题栏放进 Navigation，
  // 落进 HarmonyOS 7 之后沉浸光感仍然生效的「Navigation 标题栏」区域；
  // 自己画一条 Row 挂材质是拿不到的（还会把圆钮变成全透明）。
  private titleText(): string {
    if (this.searching) {
      return '搜索设置';
    }
    if (this.page === 'clear') {
      return '清除浏览数据';
    }
    if (this.page === 'engines') {
      return '搜索引擎';
    }
    if (this.page === 'appearance') {
      return '深色模式';
    }
    if (this.page === 'zoom') {
      return '网页缩放';
    }
    if (this.page === 'account') {
      return '华为账号';
    }
    return '设置';
  }

  // 返回：二级页回主面板，主面板才真的退出设置；搜索态先收起搜索。
  private handleTitleBack(): void {
    if (this.searching) {
      this.searching = false;
      this.searchText = '';
      return;
    }
    if (this.page === 'main') {
      this.onBack();
    } else {
      this.page = 'main';
    }
  }

  @Builder
  private SectionLabel(title: string, tightTop: boolean = false) {
    Text(title)
      .fontSize(13)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .margin({ top: tightTop ? 4 : 18, bottom: 8 })
  }

  @Builder
  private CardDivider() {
    Divider()
      .color($r('app.color.divider'))
      .margin({ left: 50 })
  }

  private prefValue(key: ShellPrefKey): boolean {
    let found = false;
    this.toggleItems.forEach((item: PrefToggleItem): void => {
      if (item.key === key) {
        found = item.value;
      }
    });
    return found;
  }

  @Builder
  private NavRow(icon: Resource, label: string, value: string, action: () => void, danger: boolean) {
    Row({ space: 12 }) {
      Image(icon)
        .width(22)
        .height(22)
        .fillColor(danger ? $r('app.color.danger') : $r('app.color.icon_primary'))
      Text(label)
        .fontSize(16)
        .fontColor(danger ? $r('app.color.danger') : $r('app.color.text_primary'))
      Blank()
      if (value.length > 0) {
        Text(value)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      Image($r('app.media.aura_chevron'))
        .width(16)
        .height(16)
        .fillColor($r('app.color.icon_secondary'))
        .opacity(0.65)
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .onClick(action)
  }

  @Builder
  private ToggleRow(icon: Resource, label: string, key: ShellPrefKey) {
    Row({ space: 12 }) {
      Image(icon)
        .width(22)
        .height(22)
        .fillColor($r('app.color.icon_primary'))
      Text(label)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: this.prefValue(key) })
        .onChange((isOn: boolean) => {
          this.setPref(key, isOn);
        })
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16 })
  }

  // 设置检索页：一个输入框 + 命中清单。开关项就地切换（带当前状态），
  // 其余跳到对应二级页或交给外壳打开独立页。
  @Builder
  private SearchView() {
    Column() {
      Row({ space: 8 }) {
        Image($r('app.media.aura_search'))
          .width(20)
          .height(20)
          .fillColor($r('app.color.icon_secondary'))
        TextInput({ placeholder: '搜索设置项', text: this.searchText })
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_secondary'))
          .backgroundColor(Color.Transparent)
          .layoutWeight(1)
          .onChange((value: string): void => {
            this.searchText = value;
          })
        if (this.searchText.length > 0) {
          Image($r('app.media.aura_close'))
            .width(18)
            .height(18)
            .fillColor($r('app.color.icon_secondary'))
            .onClick((): void => {
              this.searchText = '';
            })
        }
      }
      .width('100%')
      .height(44)
      .padding({ left: 14, right: 14 })
      .borderRadius(12)
      .backgroundColor($r('app.color.card_background'))
      .margin({ bottom: 8 })

      Scroll(this.searchScroller) {
        Column() {
          ForEach(this.matchedEntries(), (entry: SettingsEntry) => {
            this.SearchResultRow(entry)
          }, (entry: SettingsEntry): string => entry.id)

          if (this.matchedEntries().length === 0) {
            Text('没有找到相关设置项')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 32 })
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .padding({ top: glassHeaderInsetVp(), left: 16, right: 16 })
  }

  @Builder
  private SearchResultRow(entry: SettingsEntry) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(entry.title)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
        if (entry.subtitle.length > 0) {
          Text(entry.subtitle)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        Text(entry.section)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (entry.kind === 'toggle' || entry.kind === 'externalToggle' ||
        entry.id === 'hideStatusBarOnScroll' || entry.id === 'hideTopBarOnScroll' ||
        entry.id === 'hideDockOnScroll') {
        Toggle({ type: ToggleType.Switch, isOn: this.entryValue(entry) })
          .onChange((isOn: boolean): void => {
            this.toggleEntry(entry, isOn);
          })
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .borderRadius(12)
    .backgroundColor($r('app.color.card_background'))
    .margin({ bottom: 8 })
    .onClick((): void => {
      this.openEntry(entry);
    })
  }

  @Builder
  private MainView() {
    Column() {
      Scroll(this.mainScroller) {
        Column() {
          // 华为账号入口：按要求隐藏（同步/登录能力暂不面向用户开放）。
          // 恢复方式：把下面整段注释打开即可，二级页 AccountPanel 代码保留未删。
          // this.SectionLabel('华为账号', true)
          // Column() {
          //   AuraNavIconRow({
          //     icon: $r('app.media.aura_account'),
          //     title: this.accountTitle(),
          //     subtitle: this.accountSubtitle(),
          //     showDivider: false,
          //     onTap: (): void => {
          //       this.page = 'account';
          //     }
          //   })
          // }
          // .width('100%')
          // .padding({ left: 0, right: 0, top: 2, bottom: 2 })
          // .borderRadius(16)
          // .backgroundColor($r('app.color.card_background'))
          // .clip(true)

          this.SectionLabel('常规')
          Column() {
            this.NavRow($r('app.media.aura_search'), '搜索引擎',
              this.defaultEngineName.length > 0 ? this.defaultEngineName : '—', (): void => {
                this.page = 'engines';
              }, false)
            this.CardDivider()
            this.NavRow($r('app.media.aura_extensions'), '扩展程序', '', (): void => {
              this.onOpenExtensions();
            }, false)
          }
          .width('100%')
          .padding({ left: 0, right: 0, top: 2, bottom: 2 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)

          this.SectionLabel('隐私与安全')
          Column() {
            this.NavRow($r('app.media.aura_globe'), '网站权限', '', (): void => {
              this.onOpenSitePermissions();
            }, false)
            this.CardDivider()
            this.ShellToggleRow($r('app.media.aura_globe'), '允许跳转本机应用',
              '知乎、B站这类链接询问后交给对应应用打开；关掉则一律在浏览器里打开',
              this.externalAppLinks, (isOn: boolean): void => {
                AppStorage.setOrCreate('auraExternalAppLinks', isOn);
                const context = this.getUIContext().getHostContext() as common.Context | undefined;
                if (context) {
                  ShellUiPrefs.saveExternalAppLinks(context, isOn);
                }
              })
            this.CardDivider()
            this.NavRow($r('app.media.aura_lock'), '密码', '', (): void => {
              this.onOpenPasswords();
            }, false)
            this.CardDivider()
            this.ToggleRow($r('app.media.aura_cookie'), '阻止第三方 Cookie', 'blockThirdPartyCookies')
            this.CardDivider()
            this.ToggleRow($r('app.media.aura_window'), '拦截弹窗', 'popupsBlocked')
            this.CardDivider()
            this.ToggleRow($r('app.media.aura_block'), '发送"请勿追踪"请求', 'doNotTrack')
            this.CardDivider()
            this.NavRow($r('app.media.aura_trash'), '清除浏览数据', '', (): void => {
              this.page = 'clear';
            }, true)
          }
          .width('100%')
          .padding({ left: 0, right: 0, top: 2, bottom: 2 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)

          this.SectionLabel('外观')
          Column() {
            this.NavRow($r('app.media.aura_moon'), '深色模式', this.colorModeLabel(), (): void => {
              this.page = 'appearance';
            }, false)
            this.CardDivider()
            this.ShellToggleRow($r('app.media.aura_eye'), '上滑时隐藏状态栏', '地址栏收起时一起隐藏，网页铺满全屏',
              this.hideStatusBarOnScroll, (isOn: boolean): void => {
                AppStorage.setOrCreate('auraHideStatusBarOnScroll', isOn);
                const context = this.getUIContext().getHostContext() as common.Context | undefined;
                if (context) {
                  ShellUiPrefs.saveHideStatusBar(context, isOn);
                }
              })
            this.CardDivider()
            this.ShellToggleRow($r('app.media.aura_scroll'), '滚动时隐藏地址栏', '向下滚动时收起顶部地址栏；关掉则地址栏常驻',
              this.hideTopBarOnScroll, (isOn: boolean): void => {
                AppStorage.setOrCreate('auraHideTopBarOnScroll', isOn);
                const context = this.getUIContext().getHostContext() as common.Context | undefined;
                if (context) {
                  ShellUiPrefs.saveHideTopBar(context, isOn);
                }
              })
            this.CardDivider()
            this.ShellToggleRow($r('app.media.aura_dock'), '滚动时隐藏底部栏', '向下滚动时收起底部栏；关掉则常驻',
              this.hideDockOnScroll, (isOn: boolean): void => {
                AppStorage.setOrCreate('auraHideDockOnScroll', isOn);
                const context = this.getUIContext().getHostContext() as common.Context | undefined;
                if (context) {
                  ShellUiPrefs.saveHideDock(context, isOn);
                }
              })
            this.CardDivider()
            this.NavRow($r('app.media.aura_zoom'), '网页缩放', `${this.textScalePercent}%`, (): void => {
              this.page = 'zoom';
            }, false)
            this.CardDivider()
            this.ToggleRow($r('app.media.aura_display'), '网页强制深色', 'forceDarkWebContents')
          }
          .width('100%')
          .padding({ left: 0, right: 0, top: 2, bottom: 2 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)

          this.SectionLabel('下载')
          Column() {
            this.ToggleRow($r('app.media.aura_download'), '下载前询问', 'downloadAskWhereToSave')
          }
          .width('100%')
          .padding({ left: 0, right: 0, top: 2, bottom: 2 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)

          this.SectionLabel('高级')
          Column() {
            this.ToggleRow($r('app.media.aura_code'), '启用 JavaScript', 'javascriptEnabled')
            this.CardDivider()
            this.ToggleRow($r('app.media.aura_bolt'), '预加载网页', 'preloadPages')
          }
          .width('100%')
          .padding({ left: 0, right: 0, top: 2, bottom: 2 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)

          if (this.chromiumVersion.length > 0) {
            Text(`Orbira 星轨浏览器 · Chromium ${this.chromiumVersion}`)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 24, bottom: 8 })
          }

        }
        .width('100%')
        // 大标题带：留给内容区顶部的「设置」大标题 + 渐隐遮罩。
        // 必须加在滚动内容的 Column 上（加在外层容器上内容就不会从标题
        // 底下穿过，虚化效果看不见）。
        .padding({ top: glassHeaderInsetVp() })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      // Scroll centers content shorter than the viewport by default (the
      // universal `align` attribute defaults to Alignment.Center), which
      // showed up as a big gap under the header. Pin it to the top.
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private ClearView() {
    Column() {
      Text('将清除所选时间范围内的历史记录、Cookie、缓存、站点数据与下载记录。书签和密码不受影响。')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: 4, bottom: 12 })

      ForEach(CLEAR_RANGES, (row: RangeRow) => {
        Row() {
          Text(row.label)
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
          Blank()
          if (row.key === this.clearRange) {
            Text('已选')
              .fontSize(13)
              .fontColor($r('app.color.accent_primary'))
          }
        }
        .width('100%')
        .constraintSize({ minHeight: 56 })
        .padding({ left: 16, right: 16 })
        .borderRadius(10)
        .backgroundColor(row.key === this.clearRange ?
          $r('app.color.surface_secondary') : Color.Transparent)
        .onClick(() => {
          this.clearRange = row.key;
        })
      }, (row: RangeRow): string => row.key)

      Blank()

      Button(this.clearing ? '清除中…' : '清除数据')
        .margin({ bottom: glassBottomInsetVp() })
        .width('100%')
        .height(46)
        .fontSize(16)
        .fontColor($r('app.color.on_accent'))
        .backgroundColor($r('app.color.accent_primary'))
        .borderRadius(10)
        .enabled(!this.clearing)
        .onClick(() => {
          this.clearData();
        })
    }
    .width('100%')
    .height('100%')
    .padding({ top: glassHeaderInsetVp() })
  }

  @Builder
  private EnginesView() {
    Column() {
      if (this.engines.length === 0) {
        Column() {
          Text('加载中…')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll(this.enginesScroller) {
          Column() {
            AuraSectionLabel({ text: '选择默认搜索引擎', tightTop: true })

            Column() {
              ForEach(this.engines, (engine: SearchEngine, index: number) => {
                Column() {
                  Row({ space: 12 }) {
                    Image($r('app.media.aura_search'))
                      .width(22)
                      .height(22)
                      .fillColor($r('app.color.icon_primary'))
                    Text(engine.name)
                      .fontSize(16)
                      .fontColor($r('app.color.text_primary'))
                    Blank()
                    if (engine.isDefault) {
                      Text('✓')
                        .fontSize(16)
                        .fontColor($r('app.color.accent_primary'))
                    }
                  }
                  .width('100%')
                  .constraintSize({ minHeight: 56 })
                  .padding({ left: 16, right: 16 })
                  .onClick(() => {
                    this.chooseEngine(engine);
                  })

                  if (index < this.engines.length - 1) {
                    Divider()
                      .color($r('app.color.divider'))
                      .margin({ left: 50 })
                  }
                }
                .width('100%')
              }, (engine: SearchEngine): string => engine.id)
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor($r('app.color.card_background'))
            .clip(true)

            Text('默认搜索引擎用于地址栏和主页的搜索。')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: 4, right: 4, top: 10 })
          }
          .width('100%')
          // 大标题带：见 MainView 同款注释。
          .padding({ top: glassHeaderInsetVp() })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private ColorModeRow(mode: ColorModeSetting, label: string) {
    Row() {
      Text(label)
        .fontSize(16)
        .fontColor(this.colorModeSetting === mode ?
          $r('app.color.accent_primary') : $r('app.color.text_primary'))
      Blank()
      if (this.colorModeSetting === mode) {
        Text('✓')
          .fontSize(16)
          .fontColor($r('app.color.accent_primary'))
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16 })
    .backgroundColor(Color.Transparent)
    .onClick(() => {
      this.chooseColorMode(mode);
    })
  }

  @Builder
  private AppearanceView() {
    Column() {
      Text('深色模式下，浏览器界面和网页一起变暗。')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: 4, bottom: 12 })

      Column() {
        this.ColorModeRow('system', '跟随系统')
        Divider()
          .color($r('app.color.divider'))
          .margin({ left: 16, right: 16 })
        this.ColorModeRow('light', '浅色')
        Divider()
          .color($r('app.color.divider'))
          .margin({ left: 16, right: 16 })
        this.ColorModeRow('dark', '深色')
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      .borderRadius(16)
      .backgroundColor($r('app.color.card_background'))
      .clip(true)
      .margin({ top: 4 })
    }
    .width('100%')
    .height('100%')
    .padding({ top: glassHeaderInsetVp() })
  }

  // 外壳偏好（非引擎 prefs）：上滑隐藏状态栏，AppStorage + preferences 持久化。
  @Builder
  private ShellToggleRow(icon: Resource, label: string, subtitle: string, checked: boolean,
    onToggle: (on: boolean) => void) {
    Row({ space: 12 }) {
      Image(icon)
        .width(22)
        .height(22)
        .fillColor($r('app.color.icon_primary'))
      Column({ space: 2 }) {
        Text(label)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: checked })
        .onChange((isOn: boolean) => {
          onToggle(isOn);
        })
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
  }

  // 网页缩放：整页默认缩放（textScale，50–200）。
  @Builder
  private ZoomView() {
    Column() {
      Text('整页一起放大或缩小，对所有网页生效。')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: 4, bottom: 12 })

      Column() {
        ForEach([50, 75, 100, 125, 150, 175, 200], (scale: number) => {
          Row() {
            Text(`${scale}%`)
              .fontSize(16)
              .fontColor(scale === this.textScalePercent ?
                $r('app.color.accent_primary') : $r('app.color.text_primary'))
              .fontWeight(scale === this.textScalePercent ? FontWeight.Medium : FontWeight.Regular)
            Blank()
            if (scale === this.textScalePercent) {
              Text('✓')
                .fontSize(16)
                .fontColor($r('app.color.accent_primary'))
            }
          }
          .width('100%')
          .constraintSize({ minHeight: 56 })
          .padding({ left: 16, right: 16 })
          .onClick(() => {
            this.setPrefNumber('textScale', scale);
          })
          if (scale !== 200) {
            Divider()
              .color($r('app.color.divider'))
              .margin({ left: 16 })
          }
        }, (scale: number): string => scale.toString())
      }
      .width('100%')
      .padding({ top: 2, bottom: 2 })
      .borderRadius(16)
      .backgroundColor($r('app.color.card_background'))
      .clip(true)
    }
    .width('100%')
    .height('100%')
    .padding({ top: glassHeaderInsetVp() })
  }

  private setPrefNumber(key: ShellPrefKey, value: number): void {
    this.textScalePercent = value;
    this.onCommand({ command: 'setPref', key: key, value: value });
    setTimeout((): void => {
      this.reloadPrefs();
    }, 400);
  }

  build() {
    GlassPage({
      title: this.titleText(),
      scrollers: [this.mainScroller, this.enginesScroller, this.searchScroller],
      menus: {
        value: [
          {
            content: {
              icon: $r('app.media.aura_search'),
              label: '搜索',
              isEnabled: true,
              action: (): void => {
                this.searching = true;
                this.searchText = '';
              }
            }
          }
        ]
      },
      onBack: (): void => {
        this.handleTitleBack();
      }
    }) {
      // 主面板和所有二级页**常驻挂载**，用可见性切换 —— 原来的 if/else 换分支
      // 会销毁重建，从二级页返回时主面板 Scroll 归零（真机反馈：返回后回到设置
      // 最顶端）。Visibility.None 保留组件实例，各页滚动位置原样留住。
      Stack() {
        Column() {
          this.SearchView()
        }
        .width('100%')
        .height('100%')
        .visibility(this.searching ? Visibility.Visible : Visibility.None)

        Column() {
          this.MainView()
        }
        .width('100%')
        .height('100%')
        .visibility(!this.searching && this.page === 'main' ? Visibility.Visible : Visibility.None)

        Column() {
          this.ClearView()
        }
        .width('100%')
        .height('100%')
        .visibility(!this.searching && this.page === 'clear' ? Visibility.Visible : Visibility.None)

        Column() {
          this.EnginesView()
        }
        .width('100%')
        .height('100%')
        .visibility(!this.searching && this.page === 'engines' ? Visibility.Visible : Visibility.None)

        Column() {
          this.AppearanceView()
        }
        .width('100%')
        .height('100%')
        .visibility(!this.searching && this.page === 'appearance' ? Visibility.Visible : Visibility.None)

        Column() {
          this.ZoomView()
        }
        .width('100%')
        .height('100%')
        .visibility(!this.searching && this.page === 'zoom' ? Visibility.Visible : Visibility.None)

        Column() {
          // 标题栏由本页统一提供（设置的所有二级页共用一条 Navigation 标题栏），
          // 所以 AccountPanel 自己不再画 Header。
          HuaweiAccountView()
        }
        .width('100%')
        .height('100%')
        .visibility(this.page === 'account' ? Visibility.Visible : Visibility.None)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16 })
    }
  }
}
