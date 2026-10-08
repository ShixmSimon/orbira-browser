/*
 * 手机主页（新标签页覆盖层）。
 * 当前标签停在 chrome://newtab 时，AuraShell 在本层之上铺出它：产品名、
 * 搜索框（与地址栏共用同一套"搜索或网址"规则）和常用网站（getTopSites，
 * 引擎按访问习惯生成）。
 */
import { BrowserCommandPayload, FaviconImage, TopSite } from 'engine';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { normalizeAddress } from './ShellUtils';
import { ScanService } from './ScanService';

const TOP_SITE_RETRY_MS: number = 1500;
const MAX_TOP_SITE_RETRIES: number = 3;

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

@Component
export struct HomeSurface {
  @StorageLink('auraTopSites') @Watch('onTopSitesChanged') topSitesJson: string = '';
  @StorageLink('auraFavicons') @Watch('onFaviconsChanged') faviconsJson: string = '';
  // 无痕会话：主页换成无痕的标题与说明，常用网站也不再列（那是普通 profile
  // 的访问习惯，跟这个会话无关）。
  @Prop incognito: boolean = false;
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  @State private topSites: TopSite[] = [];
  @State private query: string = '';
  // url -> data URL, from getFavicons; sites without one keep the letter
  // avatar placeholder.
  @State private favicons: Map<string, string> = new Map();
  private requestSeq: number = 0;
  private retryTimer: number = -1;
  private retryCount: number = 0;

  aboutToAppear(): void {
    // 种子解析：@StorageLink 的初值不会触发 @Watch，而且引擎回的 JSON 与已存
    // 的那份逐字节相同时也不会有变更通知 —— 从网页回到主页时组件是新建的，
    // 只靠 @Watch 就永远等不到，常用网站会整排消失（实测）。
    this.onTopSitesChanged();
    this.onFaviconsChanged();
    this.reloadTopSites();
    this.scheduleRetry();
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

  // 长按删除：只把这一条加进引擎的黑名单（removeTopSite），下次 getTopSites
  // 就不会再出现；顺手把本地列表也去掉，不用等回包。
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
      const remaining: TopSite[] = [];
      for (const item of this.topSites) {
        if (item.url !== site.url) {
          remaining.push(item);
        }
      }
      this.topSites = remaining;
      this.getUIContext().getPromptAction().showToast({ message: '已移除', duration: 1500 });
    }).catch((error: Error): void => {
    });
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

  build() {
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
        Text(this.incognito ? '无痕浏览' : 'Aura')
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

      if (this.topSites.length > 0 && !this.incognito) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.topSites, (site: TopSite) => {
            Column({ space: 7 }) {
              if (this.faviconFor(site).length > 0) {
                Image(this.faviconFor(site))
                  .width(54)
                  .height(54)
                  .borderRadius(15)
                  .objectFit(ImageFit.Cover)
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
            .onClick(() => {
              this.openSite(site);
            })
            .gesture(LongPressGesture({ repeat: false })
              .onAction((): void => {
                this.confirmRemoveSite(site);
              }))
          }, (site: TopSite): string => site.url)
        }
        .width('100%')
        .margin({ top: 18 })
      }

      Blank()
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24 })
    .backgroundColor($r('app.color.surface_primary'))
  }
}
