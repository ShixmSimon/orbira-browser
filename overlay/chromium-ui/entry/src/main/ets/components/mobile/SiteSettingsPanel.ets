/*
 * 单站"网站设置"页（方案A：从地址栏锁图标进入）。
 * 针对当前浏览的网站逐类设置权限：本地维护完整权限类型清单（初始为
 * default），用引擎 getSiteSettingsForOrigin 回包覆盖实际值；点按在
 * 允许→询问→禁止→默认 间循环并写入例外（setSiteSetting），从而让
 * "网站权限"全局列表出现该站。头部显示站点图标 + 域名 + "网站设置"。
 */
import { BrowserCommandPayload, SiteSetting, SiteSettingType, SiteSettingValue, SiteSettingsEvent } from 'engine';
import { displayUrl } from './PanelBridge';
import { glassHeaderInsetVp } from './GlassPage';
import { AuraSiteIcon } from './AuraKit';
import { requestFavicons, ingestFavicons, snapshotFavicons, faviconData } from './FaviconKit';
import {
  HdsNavigation,
  HdsNavigationTitleMode,
  hdsMaterial,
  ScrollEffectType
} from '@kit.UIDesignKit';

const VALUE_LABELS: Record<string, string> = {
  'allow': '允许',
  'ask': '询问',
  'block': '禁止',
  'default': '默认'
};

const CYCLE_ORDER: SiteSettingValue[] = ['allow', 'ask', 'block', 'default'];

// 权限类型行（显式 interface：ArkTS 禁内联对象类型）。
interface SiteTypeInfo {
  type: SiteSettingType;
  label: string;
}

// 完整权限类型清单（与"网站权限"详情页 typeLabel 保持一致）。
const ALL_TYPES: SiteTypeInfo[] = [
  { type: 'location', label: '位置' },
  { type: 'camera', label: '相机' },
  { type: 'microphone', label: '麦克风' },
  { type: 'notifications', label: '通知' },
  { type: 'javascript', label: 'JavaScript' },
  { type: 'popups', label: '弹出式窗口' },
  { type: 'sound', label: '声音' },
  { type: 'clipboard', label: '剪贴板' },
  { type: 'storageAccess', label: '存储访问' }
];

function valueLabel(value: string): string {
  return VALUE_LABELS[value] ?? value;
}

function nextValue(current: string): SiteSettingValue {
  for (let i = 0; i < CYCLE_ORDER.length; i++) {
    if (CYCLE_ORDER[i] === current) {
      return CYCLE_ORDER[(i + 1) % CYCLE_ORDER.length];
    }
  }
  return 'default';
}

@Component
export struct SiteSettingsPanel {
  @StorageLink('auraPanelSiteSettings') @Watch('onSettingsPayload') settingsJson: string = '';
  @StorageLink('auraFavicons') @Watch('onFaviconsChanged') faviconsJson: string = '';
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  onBack: () => void = (): void => {};
  onClose: () => void = (): void => {};

  // 当前站 origin（scheme://host[:port]）。aboutToAppear 从 auraCurrentUrl 解析。
  @State private origin: string = '';
  @State private settings: Map<string, SiteSettingValue> = new Map();
  @State private loading: boolean = true;
  @State private faviconMap: Map<string, string> = new Map();
  private navStack: NavPathStack = new NavPathStack();
  private scroller: Scroller = new Scroller();
  private requestSeq: number = 0;
  private requestId: number = 0;
  private retryTimer: number = -1;

  aboutToAppear(): void {
    // 取当前页 origin：优先 AppStorage 的当前 URL（锁图标在浏览态，必为最新页）。
    const cur = (AppStorage.get('auraCurrentUrl') as string) ?? '';
    this.origin = this.originOf(cur);
    // 先吃一次已有回包/图标，避免首帧空白。
    this.onFaviconsChanged();
    this.onSettingsPayload();
    this.refresh();
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1;
      if (this.loading) {
        this.refresh();
      }
    }, 1500);
  }

  aboutToDisappear(): void {
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  private originOf(url: string): string {
    const m = url.match(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^/?#]+/);
    return m ? m[0] : url;
  }

  private refresh(): void {
    if (this.origin.length === 0) {
      this.loading = false;
      return;
    }
    this.loading = true;
    this.requestSeq += 1;
    this.requestId = this.requestSeq;
    this.onCommand({ command: 'getSiteSettingsForOrigin', requestId: this.requestSeq, origin: this.origin });
  }

  private onSettingsPayload(): void {
    if (this.settingsJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.settingsJson) as SiteSettingsEvent;
      if (payload.requestId !== this.requestId) {
        return;
      }
      // 初始化完整类型清单（default），再用回包覆盖实际值。
      const map: Map<string, SiteSettingValue> = new Map();
      ALL_TYPES.forEach((t: SiteTypeInfo): void => {
        map.set(t.type, 'default');
      });
      (payload.items ?? []).forEach((item: SiteSetting): void => {
        if (item.origin === this.origin && map.has(item.type)) {
          map.set(item.type, item.setting);
        }
      });
      this.settings = map;
      this.requestSiteFavicons();
      this.loading = false;
    } catch (error) {
      this.loading = false;
    }
  }

  private onFaviconsChanged(): void {
    ingestFavicons(this.faviconsJson);
    this.faviconMap = snapshotFavicons();
    this.requestSiteFavicons();
  }

  private requestSiteFavicons(): void {
    if (this.origin.length === 0) {
      return;
    }
    requestFavicons([this.origin], this.onCommand);
  }

  private cycle(type: SiteSettingType): void {
    const current = this.settings.get(type) ?? 'default';
    const value = nextValue(current);
    // 乐观更新：立即翻转，再重新拉取确认。
    const map = new Map(this.settings);
    map.set(type, value);
    this.settings = map;
    this.onCommand({ command: 'setSiteSetting', origin: this.origin, type: type, setting: value });
    setTimeout((): void => {
      this.refresh();
    }, 400);
  }

  private confirmReset(): void {
    AlertDialog.show({
      title: '清除这个网站的权限和数据？',
      message: `${displayUrl(this.origin)} 的权限设置和网站存储的数据都会删除。`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '清除',
        fontColor: '#E24B4A',
        action: (): void => {
          this.onCommand({ command: 'resetSiteSettings', origin: this.origin });
          this.onBack();
        }
      }
    });
  }

  build() {
    HdsNavigation(this.navStack) {
      Column() {
        if (this.origin.length === 0) {
          Column() {
            Text(this.loading ? '加载中…' : '当前页面没有可设置的网站')
              .fontSize(15)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll(this.scroller) {
            Column() {
              // 头部：站点信息。必须在 Scroll 内容层里——外层 Column 顶部直达
              // 屏幕物理边缘（ignoreLayoutSafeArea TOP），只有这里的
              // glassHeaderInsetVp() 内缩能把内容压到标题栏之下（顶部内缩铁律）。
              Row({ space: 12 }) {
                AuraSiteIcon({ url: this.origin, iconData: faviconData(this.origin, this.faviconMap) })
                Column({ space: 2 }) {
                  Text(displayUrl(this.origin))
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text('网站设置')
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })

              Column() {
                ForEach(ALL_TYPES, (t: SiteTypeInfo, index: number) => {
                  Column() {
                    Row() {
                      Text(t.label)
                        .fontSize(16)
                        .fontColor($r('app.color.text_primary'))
                      Blank()
                      Text(valueLabel(this.settings.get(t.type) ?? 'default'))
                        .fontSize(14)
                        .fontColor((this.settings.get(t.type) ?? 'default') === 'block'
                          ? $r('app.color.danger') : $r('app.color.accent_primary'))
                      Image($r('app.media.aura_chevron'))
                        .width(16)
                        .height(16)
                        .fillColor($r('app.color.icon_secondary'))
                        .opacity(0.65)
                        .margin({ left: 6 })
                    }
                    .width('100%')
                    .constraintSize({ minHeight: 56 })
                    .padding({ left: 16, right: 16 })
                    .onClick(() => {
                      this.cycle(t.type);
                    })

                    if (index < ALL_TYPES.length - 1) {
                      Divider()
                        .color($r('app.color.divider'))
                        .margin({ left: 16 })
                    }
                  }
                  .width('100%')
                }, (t: SiteTypeInfo): string => t.type)
              }
              .width('100%')
              .borderRadius(16)
              .backgroundColor($r('app.color.card_background'))
              .clip(true)

              Text('点按一项在 允许 → 询问 → 禁止 → 默认 之间切换；"默认"会删除这条单独设置。')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .margin({ top: 12, left: 4 })

              Button('清除这个网站的权限和数据')
                .width('100%')
                .height(46)
                .fontSize(16)
                .fontColor($r('app.color.danger'))
                .backgroundColor($r('app.color.card_background'))
                .borderRadius(16)
                .margin({ top: 20 })
                .onClick(() => {
                  this.confirmReset();
                })
            }
            .width('100%')
            // 大标题带：滚动内容穿过大标题时逐渐虚化（见 GlassPage 文件头）。
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
    .titleBar({
      content: {
        title: { mainTitle: '网站设置' },
        backIcon: {
          icon: $r('sys.symbol.chevron_backward'),
          isEnabled: true,
          action: (): void => {
            this.onBack();
          }
        },
        menu: undefined
      },
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: false
    })
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(false)
    .mode(NavigationMode.Stack)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .bindToScrollable([this.scroller])
    .backgroundColor($r('app.color.page_background'))
    .width('100%')
    .height('100%')
  }
}
