/*
 * 手机自绘设置页（参考外壳扩展）。
 * 数据流：getPrefs / getSearchEngines / getAboutInfo -> 对应事件
 * （AuraShell 转存到 'auraPanelPrefs' / 'auraPanelEngines' / 'auraPanelAbout'）。
 * setPref 成功后引擎推 prefsChanged（转存到 'auraPanelEvent'），本页据此重拉。
 */
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { AppearanceSettings, ColorModeSetting } from '../../utils/appearance/AppearanceSettings';
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
  { key: 'forceDarkWebContents', label: '网页强制深色' }
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
  // Runtime diagnostics at the bottom of the page: device API level,
  // immersive-material support / switch / level, and both colour-mode
  // values (shell view vs. system configuration).
  @State private diagApi: string = '…';
  @State private diagMaterialSupport: string = '…';
  @State private diagMaterialState: string = '…';
  @State private diagMaterialLevel: string = '…';
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

  @Builder
  private Header(title: string, showBackToMain: boolean) {
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
        if (showBackToMain) {
          this.page = 'main';
        } else {
          this.onBack();
        }
      })

      Text(title)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ left: 12 })

      Blank()
    }
    .width('100%')
    .height(52)
  }

  @Builder
  private SectionLabel(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .margin({ top: 18, bottom: 8 })
  }

  @Builder
  private CardDivider() {
    Divider()
      .color($r('app.color.divider'))
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
  private NavRow(label: string, value: string, action: () => void) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
      Blank()
      if (value.length > 0) {
        Text(value)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
      Text('›')
        .fontSize(18)
        .fontColor($r('app.color.text_secondary'))
        .margin({ left: 6 })
    }
    .width('100%')
    .height(50)
    .onClick(action)
  }

  @Builder
  private DiagRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
      Blank()
      Text(value)
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
    }
    .width('100%')
    .height(36)
  }

  @Builder
  private ToggleRow(label: string, key: ShellPrefKey) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: this.prefValue(key) })
        .onChange((isOn: boolean) => {
          this.setPref(key, isOn);
        })
    }
    .width('100%')
    .height(50)
  }

  @Builder
  private MainView() {
    Column() {
      this.Header('设置', false)

      Scroll() {
        Column() {
          this.SectionLabel('常规')
          Column() {
            this.NavRow('搜索引擎', this.defaultEngineName.length > 0 ? this.defaultEngineName : '—', (): void => {
              this.page = 'engines';
            })
            this.CardDivider()
            this.NavRow('扩展程序', '', (): void => {
              this.onOpenExtensions();
            })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 2, bottom: 2 })
          .borderRadius(12)
          .backgroundColor($r('app.color.surface_secondary'))

          this.SectionLabel('隐私与安全')
          Column() {
            this.NavRow('网站权限', '', (): void => {
              this.onOpenSitePermissions();
            })
            this.CardDivider()
            this.NavRow('密码', '', (): void => {
              this.onOpenPasswords();
            })
            this.CardDivider()
            this.ToggleRow('阻止第三方 Cookie', 'blockThirdPartyCookies')
            this.CardDivider()
            this.ToggleRow('拦截弹窗', 'popupsBlocked')
            this.CardDivider()
            this.ToggleRow('发送"请勿追踪"请求', 'doNotTrack')
            this.CardDivider()
            this.NavRow('清除浏览数据', '', (): void => {
              this.page = 'clear';
            })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 2, bottom: 2 })
          .borderRadius(12)
          .backgroundColor($r('app.color.surface_secondary'))

          this.SectionLabel('外观')
          Column() {
            this.NavRow('深色模式', this.colorModeLabel(), (): void => {
              this.page = 'appearance';
            })
            this.CardDivider()
            this.ToggleRow('网页强制深色', 'forceDarkWebContents')
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 2, bottom: 2 })
          .borderRadius(12)
          .backgroundColor($r('app.color.surface_secondary'))

          this.SectionLabel('高级')
          Column() {
            this.ToggleRow('启用 JavaScript', 'javascriptEnabled')
            this.CardDivider()
            this.ToggleRow('预加载网页', 'preloadPages')
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 2, bottom: 2 })
          .borderRadius(12)
          .backgroundColor($r('app.color.surface_secondary'))

          if (this.chromiumVersion.length > 0) {
            Text(`Chromium ${this.chromiumVersion}`)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 24, bottom: 8 })
          }

          this.SectionLabel('诊断信息')
          Column() {
            this.DiagRow('UI 构建', 'v7 · 系统点光源')
            this.CardDivider()
            this.DiagRow('设备 API', this.diagApi)
            this.CardDivider()
            this.DiagRow('材质支持', this.diagMaterialSupport)
            this.CardDivider()
            this.DiagRow('材质开关', this.diagMaterialState)
            this.CardDivider()
            this.DiagRow('算力档', this.diagMaterialLevel)
            this.CardDivider()
            this.DiagRow('应用色彩', this.diagColorScheme)
            this.CardDivider()
            this.DiagRow('系统色彩', this.diagSystemColorMode)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 2, bottom: 2 })
          .borderRadius(12)
          .backgroundColor($r('app.color.surface_secondary'))

          Blank()
            .height(24)
        }
        .width('100%')
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
      this.Header('清除浏览数据', true)

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
        .height(48)
        .padding({ left: 12, right: 12 })
        .borderRadius(8)
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
  }

  @Builder
  private EnginesView() {
    Column() {
      this.Header('搜索引擎', true)

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
        List({ space: 2 }) {
          ForEach(this.engines, (engine: SearchEngine) => {
            ListItem() {
              Row() {
                Text(engine.name)
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                Blank()
                if (engine.isDefault) {
                  Text('默认')
                    .fontSize(13)
                    .fontColor($r('app.color.accent_primary'))
                }
              }
              .width('100%')
              .height(52)
              .onClick(() => {
                this.chooseEngine(engine);
              })
            }
          }, (engine: SearchEngine): string => engine.id)
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private ColorModeRow(mode: ColorModeSetting, label: string) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
      Blank()
      if (this.colorModeSetting === mode) {
        Text('已选')
          .fontSize(13)
          .fontColor($r('app.color.accent_primary'))
      }
    }
    .width('100%')
    .height(48)
    .padding({ left: 12, right: 12 })
    .borderRadius(8)
    .backgroundColor(this.colorModeSetting === mode ?
      $r('app.color.surface_primary') : Color.Transparent)
    .onClick(() => {
      this.chooseColorMode(mode);
    })
  }

  @Builder
  private AppearanceView() {
    Column() {
      this.Header('深色模式', true)

      Text('深色模式下，浏览器界面和网页一起变暗。')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: 4, bottom: 12 })

      Column() {
        this.ColorModeRow('system', '跟随系统')
        Divider()
          .color($r('app.color.divider'))
          .margin({ left: 12, right: 12 })
        this.ColorModeRow('light', '浅色')
        Divider()
          .color($r('app.color.divider'))
          .margin({ left: 12, right: 12 })
        this.ColorModeRow('dark', '深色')
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      .borderRadius(12)
      .backgroundColor($r('app.color.surface_secondary'))
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Column() {
      if (this.page === 'clear') {
        this.ClearView()
      } else if (this.page === 'engines') {
        this.EnginesView()
      } else if (this.page === 'appearance') {
        this.AppearanceView()
      } else {
        this.MainView()
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, bottom: 16 })
    .backgroundColor($r('app.color.surface_primary'))
  }
}
