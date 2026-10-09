/*
 * 手机自绘设置页（参考外壳扩展）。
 * 数据流：getPrefs / getSearchEngines / getAboutInfo -> 对应事件
 * （AuraShell 转存到 'auraPanelPrefs' / 'auraPanelEngines' / 'auraPanelAbout'）。
 * setPref 成功后引擎推 prefsChanged（转存到 'auraPanelEvent'），本页据此重拉。
 */
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { hdsMaterial } from '@kit.UIDesignKit';
import { AppearanceSettings, ColorModeSetting } from '../../utils/appearance/AppearanceSettings';
import { GlassPage, GLASS_TITLE_ZONE_VP } from './GlassPage';
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
  @StorageLink('auraHuaweiAccount') accountJson: string = '';
  // Runtime diagnostics at the bottom of the page: device API level,
  // immersive-material support / switch / level, and both colour-mode
  // values (shell view vs. system configuration).
  @State private diagApi: string = '…';
  @State private diagMaterialSupport: string = '…';
  @State private diagMaterialState: string = '…';
  @State private diagMaterialLevel: string = '…';
  // HDS 侧探测：getSystemMaterialTypes() 报告本机可渲染的材质类型
  // （Lumie 同款入口；全 NONE = 系统材质被关掉）。
  @State private diagHdsMaterial: string = '…';
  @State private diagColorScheme: string = '…';
  @State private diagSystemColorMode: string = '…';
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
    this.collectDiagnostics();
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

  private accountInfo(): HuaweiAccountInfo {
    if (this.accountJson.length === 0) {
      return { signedIn: false, openID: '', unionID: '' };
    }
    try {
      const value = JSON.parse(this.accountJson) as HuaweiAccountInfo;
      return {
        signedIn: value.signedIn === true,
        openID: String(value.openID ?? ''),
        unionID: String(value.unionID ?? '')
      };
    } catch (error) {
      return { signedIn: false, openID: '', unionID: '' };
    }
  }

  private accountTitle(): string {
    return this.accountInfo().signedIn ? '已登录华为账号' : '华为账号';
  }

  private accountSubtitle(): string {
    return this.accountInfo().signedIn ? '已登录' : '登录后同步书签和密码';
  }

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

  // Snapshots the runtime facts that decide whether the HarmonyOS 7
  // immersive-light effects can show up at all. Every probe is guarded:
  // on devices without API 26 the uiMaterial namespace simply throws.
  private collectDiagnostics(): void {
    this.diagApi = String(deviceInfo.sdkApiVersion);
    try {
      this.diagMaterialSupport = uiMaterial.isImmersiveMaterialSupported() ? '是' : '否';
    } catch (error) {
      this.diagMaterialSupport = 'API 不可用';
    }
    try {
      const state = uiMaterial.getMaterialInfo().state;
      if (state === uiMaterial.MaterialState.ENABLE) {
        this.diagMaterialState = 'ENABLE';
      } else if (state === uiMaterial.MaterialState.DISABLE) {
        this.diagMaterialState = 'DISABLE';
      } else {
        this.diagMaterialState = 'DEFAULT';
      }
    } catch (error) {
      this.diagMaterialState = 'API 不可用';
    }
    try {
      const level = uiMaterial.getGlobalMaterialLevel();
      if (level === uiMaterial.MaterialLevel.EXQUISITE) {
        this.diagMaterialLevel = '高（完整效果）';
      } else if (level === uiMaterial.MaterialLevel.GENTLE) {
        this.diagMaterialLevel = '中（均衡）';
      } else {
        this.diagMaterialLevel = '低（降级）';
      }
    } catch (error) {
      this.diagMaterialLevel = 'API 不可用';
    }
    try {
      const materialTypes: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
      const supported: boolean = materialTypes.some((type: hdsMaterial.MaterialType): boolean =>
        type !== hdsMaterial.MaterialType.NONE);
      if (!supported) {
        this.diagHdsMaterial = '不可用';
      } else {
        const immersive: boolean = materialTypes.some((type: hdsMaterial.MaterialType): boolean =>
          type === hdsMaterial.MaterialType.IMMERSIVE);
        this.diagHdsMaterial = immersive ? '可用 · IMMERSIVE' : '可用 · ADAPTIVE';
      }
    } catch (error) {
      this.diagHdsMaterial = 'API 不可用';
    }
    this.diagColorScheme = String(AppStorage.get('auraColorScheme') ?? '?');
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context) {
      const mode = context.config.colorMode;
      if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
        this.diagSystemColorMode = 'dark';
      } else if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
        this.diagSystemColorMode = 'light';
      } else {
        this.diagSystemColorMode = 'not-set';
      }
    } else {
      this.diagSystemColorMode = '?';
    }
  }

  private colorModeLabel(): string {
    if (this.colorModeSetting === 'dark') {
      return '深色';
    }
    return this.colorModeSetting === 'light' ? '浅色' : '跟随系统';
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
      // Refresh the diagnostics so the colour-mode rows reflect the switch.
      setTimeout((): void => {
        this.collectDiagnostics();
      }, 600);
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

  // 返回：二级页回主面板，主面板才真的退出设置。
  private handleTitleBack(): void {
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
  private DiagRow(label: string, value: string) {
    Row({ space: 12 }) {
      Image($r('app.media.aura_info'))
        .width(22)
        .height(22)
        .fillColor($r('app.color.icon_secondary'))
      Text(label)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
      Blank()
      Text(value)
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
    }
    .width('100%')
    .constraintSize({ minHeight: 44 })
    .padding({ left: 16, right: 16 })
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

  @Builder
  private MainView() {
    Column() {
      Scroll() {
        Column() {
          this.SectionLabel('华为账号', true)
          Column() {
            AuraNavIconRow({
              icon: $r('app.media.aura_account'),
              title: this.accountTitle(),
              subtitle: this.accountSubtitle(),
              showDivider: false,
              onTap: (): void => {
                this.page = 'account';
              }
            })
          }
          .width('100%')
          .padding({ left: 0, right: 0, top: 2, bottom: 2 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)

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

          this.SectionLabel('诊断信息')
          Column() {
            this.DiagRow('UI 构建', 'v8 · HDS 背板 + 渐变遮罩')
            this.CardDivider()
            this.DiagRow('设备 API', this.diagApi)
            this.CardDivider()
            this.DiagRow('材质支持', this.diagMaterialSupport)
            this.CardDivider()
            this.DiagRow('材质开关', this.diagMaterialState)
            this.CardDivider()
            this.DiagRow('算力档', this.diagMaterialLevel)
            this.CardDivider()
            this.DiagRow('HDS 材质', this.diagHdsMaterial)
            this.CardDivider()
            this.DiagRow('应用色彩', this.diagColorScheme)
            this.CardDivider()
            this.DiagRow('系统色彩', this.diagSystemColorMode)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 2, bottom: 2 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)

          Blank()
            .height(24)
        }
        .width('100%')
        // 大标题带：留给内容区顶部的「设置」大标题 + 渐隐遮罩。
        // 必须加在滚动内容的 Column 上（加在外层容器上内容就不会从标题
        // 底下穿过，虚化效果看不见）。
        .padding({ top: GLASS_TITLE_ZONE_VP })
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
    .padding({ top: GLASS_TITLE_ZONE_VP })
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
        Scroll() {
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
          .padding({ top: GLASS_TITLE_ZONE_VP })
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
    .padding({ top: GLASS_TITLE_ZONE_VP })
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
    .padding({ top: GLASS_TITLE_ZONE_VP })
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
      onBack: (): void => {
        this.handleTitleBack();
      }
    }) {
      // 主面板和所有二级页**常驻挂载**，用可见性切换 —— 原来的 if/else 换分支
      // 会销毁重建，从二级页返回时主面板 Scroll 归零（真机反馈：返回后回到设置
      // 最顶端）。Visibility.None 保留组件实例，各页滚动位置原样留住。
      Stack() {
        Column() {
          this.MainView()
        }
        .width('100%')
        .height('100%')
        .visibility(this.page === 'main' ? Visibility.Visible : Visibility.None)

        Column() {
          this.ClearView()
        }
        .width('100%')
        .height('100%')
        .visibility(this.page === 'clear' ? Visibility.Visible : Visibility.None)

        Column() {
          this.EnginesView()
        }
        .width('100%')
        .height('100%')
        .visibility(this.page === 'engines' ? Visibility.Visible : Visibility.None)

        Column() {
          this.AppearanceView()
        }
        .width('100%')
        .height('100%')
        .visibility(this.page === 'appearance' ? Visibility.Visible : Visibility.None)

        Column() {
          this.ZoomView()
        }
        .width('100%')
        .height('100%')
        .visibility(this.page === 'zoom' ? Visibility.Visible : Visibility.None)

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
      .padding({ left: 16, right: 16, bottom: 16 })
    }
  }
}
