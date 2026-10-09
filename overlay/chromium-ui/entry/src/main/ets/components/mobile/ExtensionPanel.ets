/*
 * 手机扩展程序页（参考外壳扩展）。
 * 契约："手机上没有能用的 chrome://extensions，外壳自己画一页"。
 * 数据流：getExtensionActions / getExtensionDetails -> 对应事件
 * （AuraShell 转存到 'auraPanelExtensions' / 'auraPanelExtensionDetails'）；
 * 变更类事件的回音通过 'auraPanelEvent' 的 kind 过滤。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { BrowserCommandPayload, ExtensionActionItem, ExtensionDetailsEvent, ExtensionSiteAccess } from 'engine';

// extensionInstallFailed 没有官方接口，按契约字段从事件上取。
interface ExtensionNoticePayload {
  message?: string;
  reason?: string;
}

interface PanelEventPayload {
  kind?: string;
  message?: string;
  reason?: string;
}

function extensionInitial(name: string): string {
  const trimmed = name.trim();
  return trimmed.length > 0 ? trimmed.substring(0, 1).toUpperCase() : '?';
}

function iconSource(item: ExtensionActionItem): string {
  if (item.iconPngBase64.length === 0) {
    return '';
  }
  return item.iconPngBase64.startsWith('data:') ?
    item.iconPngBase64 : `data:image/png;base64,${item.iconPngBase64}`;
}

@Component
export struct ExtensionPanel {
  @StorageLink('auraPanelExtensions') @Watch('onExtensionsPayload') extensionsJson: string = '';
  @StorageLink('auraPanelExtensionDetails') @Watch('onDetailsPayload') detailsJson: string = '';
  @StorageLink('auraPanelEvent') @Watch('onPanelEvent') panelEventJson: string = '';
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  onBack: () => void = (): void => {};
  onClose: () => void = (): void => {};
  // The active tab's URL when the page opened: the native install-confirm
  // dialog renders in the tab's web layer, and a new-tab page is covered by
  // the shell's home surface -- the tab must be parked elsewhere first.
  currentUrl: string = '';

  @State private items: ExtensionActionItem[] = [];
  @State private page: string = 'list';
  @State private detailId: string = '';
  @State private detailName: string = '';
  @State private detailPermissions: string[] = [];
  @State private detailSiteAccess: string = '';
  @State private detailSiteAccessChangeable: boolean = false;
  @State private detailMissing: boolean = false;
  @State private installing: boolean = false;
  private requestSeq: number = 0;
  private retryTimer: number = -1;

  aboutToAppear(): void {
    // Seed from storage first: a @StorageLink does not fire @Watch for its
    // initial value, and a byte-identical engine reply raises no change
    // either, so a re-opened panel would otherwise lose the list.
    this.onExtensionsPayload();
    this.reload();
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1;
      if (this.items.length === 0) {
        this.reload();
      }
    }, 1500);
  }

  aboutToDisappear(): void {
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  private reload(): void {
    this.requestSeq += 1;
    this.onCommand({ command: 'getExtensionActions', requestId: this.requestSeq });
  }

  private onExtensionsPayload(): void {
    if (this.extensionsJson.length === 0) {
      return;
    }
    try {
      this.items = JSON.parse(this.extensionsJson) as ExtensionActionItem[];
    } catch (error) {
    }
  }

  private onDetailsPayload(): void {
    if (this.detailsJson.length === 0) {
      return;
    }
    try {
      const details = JSON.parse(this.detailsJson) as ExtensionDetailsEvent;
      if (String(details.id) !== this.detailId) {
        return;
      }
      if (details.error === 'notFound') {
        this.detailMissing = true;
        this.page = 'list';
        this.reload();
        return;
      }
      this.detailPermissions = details.permissions ?? [];
      this.detailSiteAccess = String(details.siteAccess ?? '');
      this.detailSiteAccessChangeable = details.siteAccessChangeable === true;
      this.detailMissing = false;
    } catch (error) {
    }
  }

  private onPanelEvent(): void {
    if (this.panelEventJson.length === 0) {
      return;
    }
    let payload: PanelEventPayload | null = null;
    try {
      payload = JSON.parse(this.panelEventJson) as PanelEventPayload;
    } catch (error) {
      return;
    }
    if (!payload) {
      return;
    }
    const kind = String(payload.kind ?? '');
    if (kind === 'extensionActionsChanged') {
      this.installing = false;
      this.reload();
      if (this.page === 'detail' && this.detailId.length > 0) {
        this.requestSeq += 1;
        this.onCommand({ command: 'getExtensionDetails', requestId: this.requestSeq, id: this.detailId });
      }
    } else if (kind === 'extensionInstallFailed') {
      this.installing = false;
      const message = String(payload.message ?? '');
      AlertDialog.show({
        title: '安装失败',
        message: message.length > 0 ? message : '无法从该文件安装扩展。',
        confirm: {
          value: '好的',
          action: (): void => {
          }
        }
      });
    } else if (kind === 'extensionCommandFailed') {
      const message = String(payload.message ?? '');
      AlertDialog.show({
        title: '操作未完成',
        message: message.length > 0 ? message : '扩展没有执行这个操作。',
        confirm: {
          value: '好的',
          action: (): void => {
          }
        }
      });
    }
  }

  private runExtension(item: ExtensionActionItem): void {
    if (!item.userEnabled) {
      return;
    }
    // The extension's popup panel is drawn by native in the web layer --
    // under this full-screen page. Dismiss the page so the popup is
    // visible; reopen the extensions page to see list changes.
    this.onClose();
    this.onCommand({ command: 'runExtensionAction', id: item.id });
  }

  private toggleExtension(item: ExtensionActionItem, enabled: boolean): void {
    this.onCommand({ command: 'setExtensionEnabled', id: item.id, enabled: enabled });
  }

  private openDetails(item: ExtensionActionItem): void {
    this.detailId = item.id;
    this.detailName = item.name;
    this.detailPermissions = [];
    this.detailSiteAccess = '';
    this.detailSiteAccessChangeable = false;
    this.detailMissing = false;
    this.page = 'detail';
    this.requestSeq += 1;
    this.onCommand({ command: 'getExtensionDetails', requestId: this.requestSeq, id: item.id });
  }

  private setSiteAccess(mode: ExtensionSiteAccess): void {
    this.onCommand({ command: 'setExtensionSiteAccess', id: this.detailId, mode: mode });
  }

  private openMoreSettings(): void {
    // The engine's real chrome://extensions page, same as Lumie's 更多设置.
    this.onCommand({ command: 'navigate', url: 'chrome://extensions/' });
    this.onClose();
  }

  private confirmUninstall(): void {
    AlertDialog.show({
      title: '卸载扩展',
      message: `确定要卸载"${this.detailName}"吗？它的数据会被一并清除。`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '卸载',
        fontColor: '#E24B4A',
        action: (): void => {
          // confirm: false -- the shell asked; Chromium's own dialog would be
          // invisible on a page that is not a web page.
          this.onCommand({ command: 'uninstallExtension', id: this.detailId, confirm: false });
        }
      }
    });
  }

  private async installFromFile(): Promise<void> {
    if (this.installing) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.crx'];
      const uris: string[] = await new picker.DocumentViewPicker(context).select(options);
      if (uris.length === 0) {
        return;
      }
      const source = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
      const destPath = `${context.filesDir}/imported-extension.crx`;
      fs.copyFileSync(source.fd, destPath);
      fs.closeSync(source);
      this.installing = true;
      // Chromium draws the install-confirm dialog in the active tab's web
      // layer -- under every shell overlay. A full-screen page covers it,
      // and a new-tab page is covered by the home surface too. Dismiss this
      // page, park a new-tab on the extensions WebUI, then hand the file to
      // the engine so the dialog lands on visible content.
      this.getUIContext().getPromptAction().showToast({
        message: '请在弹出的窗口中确认安装',
        duration: 3000
      });
      this.onClose();
      if (this.currentUrl.startsWith('chrome://newtab') ||
        this.currentUrl.startsWith('chrome://new-tab-page')) {
        this.onCommand({ command: 'navigate', url: 'chrome://extensions/' });
      }
      this.onCommand({ command: 'installExtensionFromFile', path: destPath });
    } catch (error) {
      console.error('Extension install from file failed:', error);
      this.installing = false;
    }
  }

  @Builder
  private ExtensionIcon(item: ExtensionActionItem, size: number) {
    if (iconSource(item).length > 0) {
      Image(iconSource(item))
        .width(size)
        .height(size)
        .borderRadius(size / 4)
    } else {
      Text(extensionInitial(item.name))
        .width(size)
        .height(size)
        .borderRadius(size / 4)
        .backgroundColor($r('app.color.surface_secondary'))
        .fontSize(size / 2.2)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .textAlign(TextAlign.Center)
    }
  }

  @Builder
  private Header(title: string, showBack: boolean) {
    Row() {
      Button({ type: ButtonType.Circle }) {
        Image($r('app.media.chromium_back'))
          .width(22)
          .height(22)
          .fillColor($r('app.color.icon_primary'))
      }
      .width(44)
      .height(44)
      .accessibilityText('返回')
      .onClick(() => {
        if (showBack) {
          this.page = 'list';
        } else {
          this.onBack();
        }
      })

      Text(title)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ left: 12 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      Blank()
    }
    .width('100%')
    .height(56)
  }

  @Builder
  private ListView() {
    Column() {
      this.Header('扩展程序', false)

      Scroll() {
        Column() {
          Text(this.items.length > 0 ? `已安装 · ${this.items.length}` : '已安装')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ top: 6, bottom: 10 })

          if (this.items.length > 0) {
            Column() {
              ForEach(this.items, (item: ExtensionActionItem, index: number) => {
                Column() {
                  Row({ space: 12 }) {
                    this.ExtensionIcon(item, 40)

                    Column({ space: 3 }) {
                      Row({ space: 6 }) {
                        Text(item.name)
                          .fontSize(15)
                          .fontWeight(FontWeight.Medium)
                          .fontColor($r('app.color.text_primary'))
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }

                      Text(item.userEnabled ?
                        (item.hasPopup ? '点按打开面板' :
                          (item.optionsUrl.length > 0 ? '点按打开设置' : '点按运行')) :
                        '已停用')
                        .fontSize(12)
                        .fontColor($r('app.color.text_secondary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    Toggle({ type: ToggleType.Switch, isOn: item.userEnabled })
                      .onChange((isOn: boolean) => {
                        this.toggleExtension(item, isOn);
                      })

                    Button({ type: ButtonType.Circle }) {
                      Text('i')
                        .fontSize(14)
                        .fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.text_secondary'))
                        .textAlign(TextAlign.Center)
                        .width(22)
                        .height(22)
                        .borderRadius(11)
                        .border({ width: 1.2, color: $r('app.color.icon_secondary') })
                    }
                    .width(40)
                    .height(40)
                    .backgroundColor(Color.Transparent)
                    .accessibilityText('扩展详情')
                    .onClick(() => {
                      this.openDetails(item);
                    })
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                  .onClick(() => {
                    this.runExtension(item);
                  })

                  if (index < this.items.length - 1) {
                    Divider()
                      .color($r('app.color.divider'))
                      .margin({ left: 52 })
                  }
                }
                .width('100%')
              }, (item: ExtensionActionItem): string => item.id)
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor($r('app.color.card_background'))
            .clip(true)
          }

          Text('添加')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ top: 20, bottom: 10 })

          Column() {
            Row({ space: 12 }) {
              Text('+')
                .fontSize(20)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .textAlign(TextAlign.Center)
                .width(40)
                .height(40)
                .borderRadius(10)
                .backgroundColor($r('app.color.surface_secondary'))
                .border({ width: 1, color: $r('app.color.icon_secondary') })

              Column({ space: 3 }) {
                Text(this.installing ? '正在安装…' : '从文件安装')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('选择已下载的 .crx 文件')
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
            .padding({ left: 16, right: 14, top: 10, bottom: 10 })
            .onClick(() => {
              this.installFromFile();
            })
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)

          Column() {
            Row({ space: 12 }) {
              Image($r('app.media.chromium_settings'))
                .width(22)
                .height(22)
                .fillColor($r('app.color.icon_primary'))
              Text('更多设置')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Blank()
              Image($r('app.media.aura_chevron'))
                .width(16)
                .height(16)
                .fillColor($r('app.color.icon_secondary'))
                .opacity(0.65)
            }
            .width('100%')
            .height(56)
            .padding({ left: 16, right: 14 })
            .onClick(() => {
              this.openMoreSettings();
            })
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)
          .margin({ top: 12 })

          Text('点按扩展打开它的面板或设置；点"i"管理网站访问和移除。扩展能读取和更改你访问的网页，只安装你信任的扩展。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ top: 14 })
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
  private SiteAccessRow(mode: ExtensionSiteAccess, label: string) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
      Blank()
      if (this.detailSiteAccess === mode) {
        Text('✓')
          .fontSize(16)
          .fontColor($r('app.color.accent_primary'))
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16 })
    .borderRadius(10)
    .backgroundColor(this.detailSiteAccess === mode ?
      $r('app.color.surface_secondary') : Color.Transparent)
    .onClick(() => {
      this.setSiteAccess(mode);
    })
  }

  @Builder
  private DetailView() {
    Column() {
      this.Header(this.detailName, true)

      Scroll() {
        Column() {
          if (this.detailMissing) {
            Text('这个扩展已经不在了。')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 20 })
          } else {
            Text('权限')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .margin({ top: 6, bottom: 10 })

            if (this.detailPermissions.length > 0) {
              Column() {
                ForEach(this.detailPermissions, (line: string, index: number) => {
                  Column() {
                    Text(line)
                      .fontSize(13)
                      .fontColor($r('app.color.text_primary'))
                      .width('100%')
                    if (index < this.detailPermissions.length - 1) {
                      Divider()
                        .color($r('app.color.divider'))
                        .margin({ top: 9, bottom: 9 })
                    }
                  }
                  .width('100%')
                }, (line: string, index: number): string => `${index}-${line}`)
              }
              .width('100%')
              .padding(16)
              .borderRadius(16)
              .backgroundColor($r('app.color.card_background'))
              .clip(true)
            } else {
              Text('加载中…')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .padding(16)
                .borderRadius(16)
                .backgroundColor($r('app.color.card_background'))
            }

            if (this.detailSiteAccessChangeable) {
              Text('网站访问')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .margin({ top: 20, bottom: 10 })

              Column({ space: 4 }) {
                this.SiteAccessRow('onClick', '点按时')
                this.SiteAccessRow('specificSites', '特定网站')
                this.SiteAccessRow('allSites', '所有网站')
              }
              .width('100%')
              .padding(6)
              .borderRadius(16)
              .backgroundColor($r('app.color.card_background'))
              .clip(true)

              Text('"所有网站"让扩展读取和更改你在任何网站上的数据。')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .margin({ top: 8 })
            }

            Button('卸载扩展')
              .width('100%')
              .height(46)
              .fontSize(16)
              .fontColor($r('app.color.danger'))
              .backgroundColor($r('app.color.card_background'))
              .borderRadius(16)
              .margin({ top: 26 })
              .onClick(() => {
                this.confirmUninstall();
              })
          }
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

  build() {
    Column() {
      if (this.page === 'detail') {
        this.DetailView()
      } else {
        this.ListView()
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, bottom: 16 })
    .backgroundColor($r('app.color.page_background'))
  }
}
