/*
 * 手机"网站权限"页。
 * getSiteSettings 列出单独设置过的网站；详情页 getSiteSettingsForOrigin
 * 逐类显示，点按在 允许→询问→禁止→默认 间切换（'default' 即删除这条单独
 * 设置）；底部可整体清除这个网站的权限和数据（resetSiteSettings）。
 */
import { BrowserCommandPayload, SiteSetting, SiteSettingType, SiteSettingValue } from 'engine';
import { displayUrl } from './PanelBridge';
import { glassHeaderInsetVp } from './GlassPage';
import { AuraSiteIcon } from './AuraKit';
import { requestFavicons, ingestFavicons, snapshotFavicons, faviconData } from './FaviconKit';
import {
  HdsNavigation,
  HdsNavigationTitleMode,
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  hdsMaterial,
  ScrollEffectType
} from '@kit.UIDesignKit';

interface SiteSettingsPayload {
  requestId?: number;
  items?: SiteSetting[];
}

// 引擎 getPrefs('defaultSiteSettings') 回包：每类的当前值与有效档位。
// 敏感权限（相机/麦克风/位置）的 choices 不含 allow——引擎拒绝写入
// 全局默认允许，界面必须按这个列表显示，否则会给出无效的"允许"档。
interface DefaultRuleItem {
  type: string;
  setting: string;
  managed: boolean;
  choices: string[];
}

interface DefaultRulesPayload {
  items: DefaultRuleItem[];
}

const VALUE_LABELS: Record<string, string> = {
  'allow': '允许',
  'ask': '询问',
  'block': '禁止',
  'default': '默认'
};

const CYCLE_ORDER: SiteSettingValue[] = ['allow', 'ask', 'block', 'default'];

function typeLabel(type: string): string {
  const labels: Record<string, string> = {
    'location': '位置',
    'camera': '相机',
    'microphone': '麦克风',
    'notifications': '通知',
    'javascript': 'JavaScript',
    'popups': '弹出式窗口',
    'sound': '声音',
    'clipboard': '剪贴板',
    'storageAccess': '存储访问'
  };
  const label = labels[type];
  return label !== undefined ? label : type;
}

function valueLabel(value: string): string {
  const label = VALUE_LABELS[value];
  return label !== undefined ? label : value;
}

function nextValue(current: string): SiteSettingValue {
  for (let i = 0; i < CYCLE_ORDER.length; i++) {
    if (CYCLE_ORDER[i] === current) {
      return CYCLE_ORDER[(i + 1) % CYCLE_ORDER.length];
    }
  }
  return 'default';
}

function originHost(origin: string): string {
  return displayUrl(origin);
}

@Component
export struct SitePermissionsPanel {
  @StorageLink('auraPanelSiteSettings') @Watch('onSettingsPayload') settingsJson: string = '';
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  onBack: () => void = (): void => {};
  onClose: () => void = (): void => {};

  @State private page: string = 'list';
  // 1.0.160：详情页走真路由栈（NavPathStack + HdsNavDestination），列表是
  // Navigation 内容常驻挂载 —— 详情返回时滚动位置天然保留，转场走系统原生
  // push-pop（同 SettingsPanel 1.0.159）。
  private pathStack: NavPathStack = new NavPathStack();
  // 渐变模糊滚动效果按官方要求 bindToScrollable：列表与详情各一个。
  private listScroller: Scroller = new Scroller();
  private detailScroller: Scroller = new Scroller();
  @State private listItems: SiteSetting[] = [];
  @State private origins: string[] = [];
  @State private detailOrigin: string = '';
  @State private detailItems: SiteSetting[] = [];
  @State private loading: boolean = true;
  private requestSeq: number = 0;
  private listRequestId: number = 0;
  private detailRequestId: number = 0;
  private retryTimer: number = -1;
  // 站点图标：引擎回包统一落 'auraFavicons'（AuraShell 转存），本页只从该键读取。
  @StorageLink('auraFavicons') @Watch('onFaviconsChanged') faviconsJson: string = '';
  @State private faviconMap: Map<string, string> = new Map();
  // 默认规则：以引擎 prefs('defaultSiteSettings') 为真值——它同时给出每类
  // 的有效档位 choices（相机/麦克风/位置不含 allow），界面据此显示，避免
  // 给出会被引擎拒绝的"允许"档。AuraShell 把该 pref 转写到这个 key。
  @StorageLink('auraDefaultSiteSettings') @Watch('onDefaultRulesChanged') defaultRulesJson: string = '';
  @State private defaultRuleItems: DefaultRuleItem[] = [];
  @State private defaultRulesExpanded: boolean = false;
  private defaultRuleRequestTimer: number = -1;

  aboutToAppear(): void {
    // Seed from storage first: a @StorageLink does not fire @Watch for its
    // initial value, and a byte-identical engine reply raises no change
    // either, so a re-opened panel would otherwise stay on "loading".
    // 站点图标同理：先吃一次已有回包，否则首帧全是占位色块。
    this.onFaviconsChanged();
    this.onDefaultRulesChanged();
    // 先吃上次缓存的列表：新页面的 listRequestId 从 0 起，与缓存回包的
    // requestId 不等，正常校验会丢弃它并闪一下"加载中"。缓存态跳过校验。
    this.onSettingsPayload(true);
    this.reloadDefaultRules();
    this.reloadList();
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1;
      if (this.loading && this.page === 'list') {
        this.reloadList();
      }
    }, 1500);
  }

  aboutToDisappear(): void {
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    if (this.defaultRuleRequestTimer !== -1) {
      clearTimeout(this.defaultRuleRequestTimer);
      this.defaultRuleRequestTimer = -1;
    }
  }

  private reloadDefaultRules(): void {
    this.onCommand({ command: 'getPrefs' });
  }

  private reloadList(): void {
    this.loading = true;
    this.requestSeq += 1;
    this.listRequestId = this.requestSeq;
    this.onCommand({ command: 'getSiteSettings', requestId: this.requestSeq });
  }

  private onDefaultRulesChanged(): void {
    if (this.defaultRulesJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.defaultRulesJson) as DefaultRulesPayload;
      if (Array.isArray(payload.items)) {
        this.defaultRuleItems = payload.items;
      }
    } catch (error) {
    }
  }

  private ruleValue(type: string): string {
    for (const item of this.defaultRuleItems) {
      if (item.type === type) {
        return item.setting;
      }
    }
    return 'ask';
  }

  private ruleChoices(type: string): string[] {
    for (const item of this.defaultRuleItems) {
      if (item.type === type) {
        return item.choices;
      }
    }
    return [];
  }

  private setDefaultRule(type: string, setting: string): void {
    this.onCommand({
      command: 'setDefaultSiteSetting',
      type: type as SiteSettingType,
      setting: setting as SiteSettingValue
    });
    // 引擎写入命令没有回包，稍后重新拉取 prefs 确认真实生效值；
    // 若被策略拒绝或档位无效，界面会回到引擎的真实状态。
    if (this.defaultRuleRequestTimer !== -1) {
      clearTimeout(this.defaultRuleRequestTimer);
    }
    this.defaultRuleRequestTimer = setTimeout((): void => {
      this.defaultRuleRequestTimer = -1;
      this.reloadDefaultRules();
    }, 400);
  }

  private refreshDetail(): void {
    this.requestSeq += 1;
    this.detailRequestId = this.requestSeq;
    this.onCommand({ command: 'getSiteSettingsForOrigin', requestId: this.requestSeq, origin: this.detailOrigin });
  }

  private onSettingsPayload(fromCache: boolean = false): void {
    if (this.settingsJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.settingsJson) as SiteSettingsPayload;
      const items = payload.items ?? [];
      if (fromCache || payload.requestId === this.listRequestId) {
        this.listItems = items;
        const seen: Record<string, boolean> = {};
        const hosts: string[] = [];
        items.forEach((item: SiteSetting): void => {
          if (!seen[item.origin]) {
            seen[item.origin] = true;
            hosts.push(item.origin);
          }
        });
        hosts.sort();
        this.origins = hosts;
        this.requestSiteFavicons();
        this.loading = false;
      } else if (payload.requestId === this.detailRequestId) {
        // 详情回包的 origin 是 url::Origin::Serialize()（https 默认端口 443
        // 被省略，如 "https://m.baidu.com"），而列表传给详情的 origin 是
        // ContentSettingsPattern 字符串（含端口，如 "https://m.baidu.com:443"）
        // —— 字符串严格相等必不成立，按 origin 过滤会把回包整个滤空。
        // requestId 匹配已保证这是详情请求自己的回包（引擎只回该 origin
        // 的逐类生效值），直接采用。
        this.detailItems = items;
      }
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
    this.requestSiteFavicons();
  }

  // 把当前可见网站的 origin 交给共享 FaviconKit 合批请求（去重 + 攒拍）。
  private requestSiteFavicons(): void {
    requestFavicons(this.origins, this.onCommand);
  }

  private openDetail(origin: string): void {
    this.detailOrigin = origin;
    this.detailItems = [];
    this.page = 'detail';
    this.pathStack.pushPathByName('detail', origin);
    this.refreshDetail();
  }

  private backToList(): void {
    this.page = 'list';
    if (this.pathStack.size() > 0) {
      this.pathStack.pop();
    }
    this.reloadList();
  }

  private cycle(item: SiteSetting): void {
    const value = nextValue(item.setting);
    this.onCommand({
      command: 'setSiteSetting',
      origin: item.origin,
      type: item.type,
      setting: value
    });
    // Optimistic: flip the row now, then confirm with a fresh fetch.
    const updated = value;
    const rows: SiteSetting[] = [];
    this.detailItems.forEach((row: SiteSetting): void => {
      rows.push(row.origin === item.origin && row.type === item.type ?
        { origin: row.origin, type: row.type, setting: updated } : row);
    });
    this.detailItems = rows;
    setTimeout((): void => {
      this.refreshDetail();
    }, 400);
  }

  private confirmReset(): void {
    AlertDialog.show({
      title: '清除这个网站的权限和数据？',
      message: `${originHost(this.detailOrigin)} 的权限设置和网站存储的数据都会删除。`,
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
          this.onCommand({ command: 'resetSiteSettings', origin: this.detailOrigin });
          this.backToList();
        }
      }
    });
  }

  private countFor(origin: string): number {
    let count = 0;
    this.listItems.forEach((item: SiteSetting): void => {
      if (item.origin === origin) {
        count += 1;
      }
    });
    return count;
  }

  @Builder
  private DefaultRules() {
    Column() {
      // 折叠行：默认收起只占一行，点开才列出全部类型。
      Row() {
        Text('默认规则（新网站）')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Image($r('app.media.aura_chevron'))
          .width(16)
          .height(16)
          .fillColor($r('app.color.icon_secondary'))
          .rotate({ angle: this.defaultRulesExpanded ? 0 : 90 })
      }
      .width('100%')
      .constraintSize({ minHeight: 44 })
      .onClick(() => {
        this.defaultRulesExpanded = !this.defaultRulesExpanded;
      })

      if (this.defaultRulesExpanded) {
        Column({ space: 8 }) {
          ForEach(this.defaultRuleItems, (item: DefaultRuleItem): void => {
            Row() {
              Text(typeLabel(item.type))
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
              ForEach(item.choices, (choice: string): void => {
                Text(valueLabel(choice))
                  .fontSize(12)
                  .fontColor(this.ruleValue(item.type) === choice ?
                    $r('app.color.accent_primary') : $r('app.color.text_secondary'))
                  .padding({ left: 8, right: 8, top: 5, bottom: 5 })
                  .borderRadius(8)
                  .backgroundColor(this.ruleValue(item.type) === choice ?
                    $r('app.color.surface_secondary') : Color.Transparent)
                  .onClick(() => {
                    if (!item.managed) {
                      this.setDefaultRule(item.type, choice);
                    }
                  })
              }, (choice: string): string => choice)
            }
            .width('100%')
            .constraintSize({ minHeight: 40 })
          }, (item: DefaultRuleItem): string => item.type)
          if (this.defaultRuleItems.length === 0) {
            Text('正在读取默认规则…')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }
          Text('对没有单独设置的网站生效；已单独设过的网站以该网站的设置为准。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
        .width('100%')
        .padding({ top: 4, bottom: 8 })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 12 })
  }

  build() {
    // 1.0.160：弃 GlassPage，自持 HdsNavigation + NavPathStack（同
    // SettingsPanel 1.0.159）。列表是 Navigation 内容、常驻挂载 —— 详情
    // 返回时滚动位置天然保留（旧 Visibility 双视图方案保实例但转场是硬切）；
    // 详情作为 NavDestination 推入，走系统原生 push-pop。
    HdsNavigation(this.pathStack) {
      Column() {
        if (this.origins.length === 0) {
          Column() {
            Text(this.loading ? '加载中…' : '还没有单独设置过权限的网站')
              .fontSize(15)
              .fontColor($r('app.color.text_secondary'))
            this.DefaultRules()
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll(this.listScroller) {
            Column() {
              this.DefaultRules()
              Column() {
                ForEach(this.origins, (origin: string, index: number) => {
                  Column() {
                    Row({ space: 12 }) {
                      AuraSiteIcon({ url: origin, iconData: faviconData(origin, this.faviconMap) })
                      Column({ space: 2 }) {
                        Text(originHost(origin))
                          .fontSize(16)
                          .fontWeight(FontWeight.Medium)
                          .fontColor($r('app.color.text_primary'))
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width('100%')
                        Text(`${this.countFor(origin)} 项自定义设置`)
                          .fontSize(12)
                          .fontColor($r('app.color.text_secondary'))
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)

                      Image($r('app.media.aura_chevron'))
                        .width(16)
                        .height(16)
                        .fillColor($r('app.color.icon_secondary'))
                        .opacity(0.65)
                    }
                    .width('100%')
                    .constraintSize({ minHeight: 60 })
                    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                    .onClick(() => {
                      this.openDetail(origin);
                    })

                    if (index < this.origins.length - 1) {
                      Divider()
                        .color($r('app.color.divider'))
                        .margin({ left: 50 })
                    }
                  }
                  .width('100%')
                }, (origin: string): string => origin)
              }
              .width('100%')
              .borderRadius(16)
              .backgroundColor($r('app.color.card_background'))
              .clip(true)
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
        title: { mainTitle: '网站权限' },
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
        // 官方渐变模糊滚动效果 + 沉浸光感材质（与 GlassPage 同一套）。
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
    .bindToScrollable([this.listScroller, this.detailScroller])
    .backgroundColor($r('app.color.page_background'))
    .navDestination(this.buildDetailDestination)
    .width('100%')
    .height('100%')
  }

  // 1.0.160：详情页 destination（真路由栈推入）。
  @Builder
  private buildDetailDestination(name: string, _param: Object): void {
    if (name !== 'detail') {
      HdsNavDestination() {
        Column().width('100%').height('100%')
      }
    } else {
      HdsNavDestination() {
      Column() {
        Scroll(this.detailScroller) {
          Column() {
            if (this.detailItems.length === 0) {
              Text('这个网站还没有单独设置过权限。')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .margin({ top: 8 })
            } else {
              Column() {
                ForEach(this.detailItems, (item: SiteSetting, index: number) => {
                  Column() {
                    Row() {
                      Text(typeLabel(item.type))
                        .fontSize(16)
                        .fontColor($r('app.color.text_primary'))
                      Blank()
                      Text(valueLabel(item.setting))
                        .fontSize(14)
                        .fontColor(item.setting === 'block' ? $r('app.color.danger') : $r('app.color.accent_primary'))
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
                      this.cycle(item);
                    })

                    if (index < this.detailItems.length - 1) {
                      Divider()
                        .color($r('app.color.divider'))
                        .margin({ left: 16 })
                    }
                  }
                  .width('100%')
                }, (item: SiteSetting): string => `${item.type}:${item.setting}`)
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
            }

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
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height('100%')
    .titleBar({
      content: {
        title: { mainTitle: originHost(this.detailOrigin) },
        backIcon: {
          icon: $r('sys.symbol.chevron_backward'),
          isEnabled: true,
          action: (): void => {
            this.backToList();
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
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .hideBackButton(false)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .bindToScrollable([this.detailScroller])
    .backgroundColor($r('app.color.page_background'))
    .onBackPressed((): boolean => {
      this.backToList();
      return true;
    })
    }
  }
}
