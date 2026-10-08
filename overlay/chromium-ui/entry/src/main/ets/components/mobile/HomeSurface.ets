/*
 * 手机主页（新标签页覆盖层）。
 * 当前标签停在 chrome://newtab 时，AuraShell 在本层之上铺出它：产品名、
 * 搜索框（与地址栏共用同一套"搜索或网址"规则）和常用网站（getTopSites，
 * 引擎按访问习惯生成）。
 */
import { BrowserCommandPayload, TopSite } from 'engine';
import { common } from '@kit.AbilityKit';
import { normalizeAddress } from './ShellUtils';
import { ScanService } from './ScanService';

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
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  @State private topSites: TopSite[] = [];
  @State private query: string = '';
  private requestSeq: number = 0;

  aboutToAppear(): void {
    this.reloadTopSites();
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
    } catch (error) {
    }
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

      Text('Aura')
        .fontSize(34)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))

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

      if (this.topSites.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.topSites, (site: TopSite) => {
            Column({ space: 7 }) {
              Text(initialOf(site))
                .fontSize(22)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .textAlign(TextAlign.Center)
                .width(54)
                .height(54)
                .borderRadius(15)
                .backgroundColor($r('app.color.surface_secondary'))
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
