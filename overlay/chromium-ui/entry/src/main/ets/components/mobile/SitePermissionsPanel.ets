/*
 * 手机"网站权限"页（参考外壳扩展）。
 * getSiteSettings 列出单独设置过的网站；详情页 getSiteSettingsForOrigin
 * 逐类显示，点按在 允许→询问→禁止→默认 间切换（'default' 即删除这条单独
 * 设置）；底部可整体清除这个网站的权限和数据（resetSiteSettings）。
 */
import { BrowserCommandPayload, SiteSetting, SiteSettingType, SiteSettingValue } from 'engine';
import { displayUrl } from './PanelBridge';
import { GlassPage, glassHeaderInsetVp } from './GlassPage';

interface SiteSettingsPayload {
  requestId?: number;
  items?: SiteSetting[];
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

  aboutToAppear(): void {
    // Seed from storage first: a @StorageLink does not fire @Watch for its
    // initial value, and a byte-identical engine reply raises no change
    // either, so a re-opened panel would otherwise stay on "loading".
    this.onSettingsPayload();
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
  }

  private reloadList(): void {
    this.loading = true;
    this.requestSeq += 1;
    this.listRequestId = this.requestSeq;
    this.onCommand({ command: 'getSiteSettings', requestId: this.requestSeq });
  }

  private refreshDetail(): void {
    this.requestSeq += 1;
    this.detailRequestId = this.requestSeq;
    this.onCommand({ command: 'getSiteSettingsForOrigin', requestId: this.requestSeq, origin: this.detailOrigin });
  }

  private onSettingsPayload(): void {
    if (this.settingsJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.settingsJson) as SiteSettingsPayload;
      const items = payload.items ?? [];
      if (payload.requestId === this.listRequestId) {
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
        this.loading = false;
      } else if (payload.requestId === this.detailRequestId) {
        this.detailItems = items.filter((item: SiteSetting): boolean => item.origin === this.detailOrigin);
      }
    } catch (error) {
      this.loading = false;
    }
  }

  private openDetail(origin: string): void {
    this.detailOrigin = origin;
    this.detailItems = [];
    this.page = 'detail';
    this.refreshDetail();
  }

  private backToList(): void {
    this.page = 'list';
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

  // 标题栏（含圆形玻璃返回钮）交给 GlassPage：标题栏要落在 Navigation 标题栏
  // 区域，HarmonyOS 7 之后沉浸光感才在自绘圆钮上生效。
  private titleText(): string {
    return this.page === 'detail' ? originHost(this.detailOrigin) : '网站权限';
  }

  private handleTitleBack(): void {
    if (this.page === 'detail') {
      this.backToList();
    } else {
      this.onBack();
    }
  }

  build() {
    GlassPage({
      title: this.titleText(),
      scrollers: [this.listScroller, this.detailScroller],
      onBack: (): void => {
        this.handleTitleBack();
      }
    }) {
    Column() {
      // 列表/详情两个视图**常驻挂载**、用可见性切换：if/else 换分支会销毁重建，
      // 从详情返回列表时滚动位置归零。Visibility.None 保留实例，滚动位置留住。
      Column() {
      if (this.origins.length === 0) {
          Column() {
            Text(this.loading ? '加载中…' : '还没有单独设置过权限的网站')
              .fontSize(15)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll(this.listScroller) {
            Column() {
              Column() {
                ForEach(this.origins, (origin: string, index: number) => {
                  Column() {
                    Row({ space: 12 }) {
                      Image($r('app.media.aura_globe'))
                        .width(22)
                        .height(22)
                        .fillColor($r('app.color.icon_primary'))
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
          .align(Alignment.TopStart)
        }
      }
      .width('100%')
      .height('100%')
      .visibility(this.page === 'list' ? Visibility.Visible : Visibility.None)

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
        .align(Alignment.TopStart)
      }
      .width('100%')
      .height('100%')
      .visibility(this.page === 'detail' ? Visibility.Visible : Visibility.None)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, bottom: 16 })
    .backgroundColor($r('app.color.page_background'))
    }
  }
}
