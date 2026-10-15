/*
 * 手机扩展程序页（参考外壳扩展）。
 * 契约："手机上没有能用的 chrome://extensions，外壳自己画一页"。
 * 数据流：getExtensionActions / getExtensionDetails -> 对应事件
 * （AuraShell 转存到 'auraPanelExtensions' / 'auraPanelExtensionDetails'）；
 * 变更类事件的回音通过 'auraPanelEvent' 的 kind 过滤。
 */
import { curves } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { BrowserCommandPayload, ExtensionActionItem, ExtensionDetailsEvent, ExtensionSiteAccess } from 'engine';
import { GlassPage, glassHeaderInsetVp } from './GlassPage';

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

// getDeveloperMode 的回音（AuraShell 转存到 'auraDeveloperMode'）。
// revision 由 AuraShell 填，只为保证回包字节必变、@Watch 必触发。
interface DeveloperModePayload {
  enabled?: boolean;
  available?: boolean;
  revision?: number;
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
  // 开发者模式（标题栏右侧开关）：引擎 profile pref 的回音，AuraShell 转存。
  @StorageLink('auraDeveloperMode') @Watch('onDeveloperModePayload') developerModeJson: string = '';
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
  // 详情页的扩展信息（引擎列表项本来就有下发，打开详情时随 item 带入）。
  @State private detailVersion: string = '';
  @State private detailDescription: string = '';
  @State private detailAuthor: string = '';
  // 详情页「允许用户脚本」：只有声明了 userScripts 权限的扩展才显示
  // （脚本猫这类用户脚本管理器正是如此）；不开它，用户脚本跑不了。
  @State private detailUserScriptsAvailable: boolean = false;
  @State private detailUserScriptsAllowed: boolean = false;
  // 标题栏「开发者模式」开关：profile 级设置（加载未打包的前提），
  // 状态永远以引擎为准——setDeveloperMode 成功后引擎会回 developerMode 事件。
  @State private developerMode: boolean = false;
  @State private developerModeAvailable: boolean = true;
  // 列表 ↔ 详情的横向滑入（1.0.152）：+1 = 详情从右侧进来，-1 = 列表从左侧
  // 回来，0 = 就位。animateTo + 弹簧曲线驱动（见 openDetail 注释）。
  @State private pageShift: number = 0;
  // 位移基准 = 面板宽（vp）。测量不到时给个手机常见值兜底。
  @State private viewportWidthVp: number = 0;
  // 开发者模式总闸的快照：关闭总闸那一刻各扩展的开关状态（id -> 原开关值），
  // 用于重新打开总闸时逐个恢复。非 UI 状态，用普通字段（改动不必触发刷新）。
  private enabledSnapshot: Record<string, boolean> = {};
  private requestSeq: number = 0;
  private retryTimer: number = -1;

  aboutToAppear(): void {
    // Seed from storage first: a @StorageLink does not fire @Watch for its
    // initial value, and a byte-identical engine reply raises no change
    // either, so a re-opened panel would otherwise lose the list.
    this.onExtensionsPayload();
    this.onDeveloperModePayload();
    this.reload();
    // 开发者模式的当前值：开关在标题栏，打开面板就问一次引擎。
    this.onCommand({ command: 'getDeveloperMode' });
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

  private onDeveloperModePayload(): void {
    if (this.developerModeJson.length === 0) {
      return;
    }
    try {
      const mode = JSON.parse(this.developerModeJson) as DeveloperModePayload;
      this.developerMode = mode.enabled === true;
      this.developerModeAvailable = mode.available !== false;
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
      this.detailUserScriptsAvailable = details.userScriptsAvailable === true;
      this.detailUserScriptsAllowed = details.userScriptsAllowed === true;
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
      const reason = String(payload.reason ?? '');
      const raw = String(payload.message ?? '');
      // 按 reason 说人话：引擎回的 reason 是机器名，兜底文案「扩展没有执行
      // 这个操作」对读者什么忙都帮不上（装机反馈）。
      let message: string;
      if (reason === 'notCrx') {
        message = '只支持 .crx 或 .zip 文件。';
      } else if (reason === 'other') {
        message = '请先打开一个网页，再安装扩展。';
      } else if (reason === 'notFound') {
        message = '文件不存在或已被移走。';
      } else if (reason === 'loadUnpackedFailed') {
        message = raw.length > 0 ? raw : '这个目录加载不了，确认里边有 manifest.json。';
      } else {
        message = raw.length > 0 ? raw : '无法从该文件安装扩展。';
      }
      AlertDialog.show({
        title: '安装失败',
        message: message,
        confirm: {
          value: '好的',
          action: (): void => {
          }
        }
      });
    } else if (kind === 'extensionCommandFailed') {
      // 安装类命令失败也要解除「正在安装」：loadUnpackedExtension 被拒
      // （developerModeOff / noManifest 等）走的是这条回包。
      this.installing = false;
      const reason = String(payload.reason ?? '');
      const raw = String(payload.message ?? '');
      let message: string;
      if (reason === 'developerModeOff') {
        message = '请先打开右上角的「开发者模式」开关。';
      } else if (reason === 'noManifest') {
        message = '所选目录里没有 manifest.json，不是扩展目录。';
      } else if (reason === 'badPath') {
        message = '所选路径不合法。';
      } else if (reason === 'notCrx') {
        message = '只支持 .crx 或 .zip 文件。';
      } else if (reason === 'notAllowed') {
        message = raw.length > 0 ? raw : '当前策略不允许这个操作。';
      } else if (reason === 'notAvailable') {
        message = '这个系统不支持该功能。';
      } else if (reason === 'stillDisabled') {
        message = '扩展没能启用，请重试。';
      } else if (reason === 'notFound') {
        message = '扩展不存在或已被移除。';
      } else {
        message = raw.length > 0 ? raw : '扩展没有执行这个操作。';
      }
      AlertDialog.show({
        title: '操作未完成',
        message: message,
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
    // 1.0.124：扩展的 popup 由原生画在**网页层**（脚本猫这类点一下就弹面板的
    // 扩展正是如此）。当前标签页不是真网页时——新标签页被外壳主页层盖着、
    // chrome:// 页也没地方锚——弹出来的面板根本看不见，点了像没反应。
    // 1.0.148：守卫收窄到**真有 popup 的扩展**（item.hasPopup，引擎按
    // action.default_popup 下发）。没有 popup 的（调姬助手这类点按打开
    // options 页或直接开网页）不依赖网页上下文，放行——否则从主页点
    // 它们也会被「先打开网页」误拦。
    // 注意这条守卫只管点扩展项：设置里打开扩展列表（管理/启停/详情）不
    // 依赖当前标签页，不该被拦。
    if (item.hasPopup && !this.isWebPageUrl(this.currentUrl)) {
      this.getUIContext().getPromptAction().showToast({
        message: '先打开一个网页，再打开扩展面板',
        duration: 3000
      });
      return;
    }
    // The extension's popup panel is drawn by native in the web layer --
    // under this full-screen page. Dismiss the page so the popup is
    // visible; reopen the extensions page to see list changes.
    this.onClose();
    this.onCommand({ command: 'runExtensionAction', id: item.id });
  }

  // 与外壳同一个判据：只有 http(s) 才算能让原生 popup 落地的真网页。
  private isWebPageUrl(url: string): boolean {
    return url.startsWith('http://') || url.startsWith('https://');
  }

  private toggleExtension(item: ExtensionActionItem, enabled: boolean): void {
    // 乐观更新：先改本地列表再发命令（装机反馈：等回包重拉列表时 UI 迟一
    // 拍）。数组整体换新对象才触发刷新；回包后 reload 以引擎为准，写不进去
    // 的（企业策略）会被回包列表纠正回来。
    // 逐字段重建：ArkTS 禁止对象展开（arkts-no-spread）。
    this.items = this.items.map((entry: ExtensionActionItem): ExtensionActionItem => {
      if (entry.id !== item.id) {
        return entry;
      }
      const updated: ExtensionActionItem = {
        id: entry.id,
        name: entry.name,
        iconPngBase64: entry.iconPngBase64,
        badgeText: entry.badgeText,
        badgeColor: entry.badgeColor,
        enabled: entry.enabled,
        pinned: entry.pinned,
        userEnabled: enabled,
        disableReasons: entry.disableReasons,
        hasPopup: entry.hasPopup,
        optionsUrl: entry.optionsUrl,
        version: entry.version,
        description: entry.description,
        author: entry.author
      };
      return updated;
    });
    this.onCommand({ command: 'setExtensionEnabled', id: item.id, enabled: enabled });
  }

  private openDetails(item: ExtensionActionItem): void {
    this.detailId = item.id;
    this.detailName = item.name;
    this.detailPermissions = [];
    this.detailSiteAccess = '';
    this.detailSiteAccessChangeable = false;
    this.detailMissing = false;
    // 版本/描述/作者随列表项带入（引擎在 extensionActions 里就下发了），
    // 不必等详情回包——回包只有权限和站点访问。
    this.detailVersion = item.version ?? '';
    this.detailDescription = item.description ?? '';
    this.detailAuthor = item.author ?? '';
    this.detailUserScriptsAvailable = false;
    this.detailUserScriptsAllowed = false;
    // 与设置面板的二级页同款开法：先落到"屏外右侧"渲染一帧，下一拍再由
    // animateTo 弹簧滑回 0 —— 见 openDetail/closeDetail 的注释（.transition()
    // 在这台真机上不产生可见动画，openPanel 早踩过同一个坑）。
    this.pageShift = 1;
    this.page = 'detail';
    setTimeout((): void => {
      animateTo({ curve: curves.springMotion(0.48, 0.84) }, (): void => {
        this.pageShift = 0;
      });
    }, 32);
    this.requestSeq += 1;
    this.onCommand({ command: 'getExtensionDetails', requestId: this.requestSeq, id: item.id });
  }

  // 详情 → 列表：往左滑出（forward=false 的反向）。
  private closeDetail(): void {
    this.pageShift = -1;
    setTimeout((): void => {
      animateTo({ curve: curves.springMotion(0.48, 0.84) }, (): void => {
        this.pageShift = 0;
      });
      this.page = 'list';
    }, 32);
  }

  private setSiteAccess(mode: ExtensionSiteAccess): void {
    this.onCommand({ command: 'setExtensionSiteAccess', id: this.detailId, mode: mode });
  }

  private setDeveloperMode(enabled: boolean): void {
    // 乐观更新：拨动瞬间就变，不等引擎回包（装机反馈：回包链路上 UI
    // 迟一拍，退出重进才见新状态）。回包之后仍以引擎为准——企业策略
    // 把写入收回时，developerMode 事件带回来的值会把这里盖回去。
    this.developerMode = enabled;
    this.onCommand({ command: 'setDeveloperMode', enabled: enabled });
    // 1.0.151：开发者模式是总闸——关掉时把扩展全停（未打包扩展在开发者
    // 模式关闭下本就不该跑，引擎也会拒），打开时按快照把原来开着的恢复。
    this.applyDeveloperModeCascade(enabled);
  }

  // 开发者模式总闸的级联：关→全停并记快照；开→按快照恢复。
  // 快照是「读者自己拨过的状态」（userEnabled），不是引擎的 enabled
  // （那是当前网页是否用得上，两回事）。
  private applyDeveloperModeCascade(developerModeOn: boolean): void {
    if (developerModeOn) {
      // 恢复：对每个扩展下发"回到快照值"。没快照记录的（首次进入就是
      // 关闭态）保持不动。
      this.items.forEach((entry: ExtensionActionItem): void => {
        const wanted = this.enabledSnapshot[entry.id];
        if (wanted === undefined) {
          return;
        }
        if (entry.userEnabled === wanted) {
          return;
        }
        this.onCommand({ command: 'setExtensionEnabled', id: entry.id, enabled: wanted });
      });
      return;
    }
    // 关闭：先记快照，再把当前开着的全部停掉。
    const snapshot: Record<string, boolean> = {};
    this.items.forEach((entry: ExtensionActionItem): void => {
      snapshot[entry.id] = entry.userEnabled;
    });
    this.enabledSnapshot = snapshot;
    this.items.forEach((entry: ExtensionActionItem): void => {
      if (!entry.userEnabled) {
        return;
      }
      this.onCommand({ command: 'setExtensionEnabled', id: entry.id, enabled: false });
    });
  }

  private openMoreSettings(): void {
    // The engine's real chrome://extensions page, same as 更多设置.
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
      // .zip 一并支持：引擎对 zip 走「解压安装」（和桌面拖放一个路子），
      // 未打包扩展分发基本就是 zip 包。
      options.fileSuffixFilters = ['.crx', '.zip'];
      const uris: string[] = await new picker.DocumentViewPicker(context).select(options);
      if (uris.length === 0) {
        return;
      }
      const source = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
      // 目标文件名要带对扩展名：引擎按扩展名分流（.zip → ZipFileInstaller，
      // .crx → CrxInstaller）。URI 里一般带着文件名，取不到就按 .crx 试。
      const isZip = uris[0].toLowerCase().indexOf('.zip') >= 0;
      const destPath = `${context.filesDir}/imported-extension.${isZip ? 'zip' : 'crx'}`;
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

  // 标题栏右侧「开发者模式」开关（HDS stackBuilder 槽）。桌面
  // chrome://extensions 同款位置；常驻标题栏，滚到页面底部也能拨。
  // 状态永远以引擎为准：拨动只发命令，回音由 developerMode 事件带回来。
  @Builder
  private DeveloperModeToggle() {
    // Blank 在前 + width('100%')：HDS 的 stackBuilder 是标题行上的覆盖槽，
    // 容器默认 left-aligned，开关会紧贴标题文字（真机反馈"和标题重叠"）。
    // 占满槽宽再用弹性空位把开关推到最右，才是桌面 chrome://extensions
    // 的同款位置。
    Row({ space: 8 }) {
      Blank()
      Text('开发者模式')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
      Toggle({ type: ToggleType.Switch, isOn: this.developerMode })
        .enabled(this.developerModeAvailable)
        .onChange((isOn: boolean) => {
          this.setDeveloperMode(isOn);
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    // 右侧留 16vp：与左侧返回钮的边距对称（装机反馈：right:4 太贴屏缘）。
    .padding({ right: 16 })
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

  // 标题栏交给 Navigation（HarmonyOS 7 之后只有 Navigation 标题栏 / 底部
  // TabBar / 弹窗类还在沉浸光感的生效范围内）。标题与返回目标都随 page 变。

  @Builder
  private ListView() {
    Column() {
      Scroll(this.listScroller) {
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

                    // 1.0.151：开发者模式关闭时启停开关一并置灰（总闸关着，
                    // 未打包扩展本就不该跑，拨了也是被拒）。
                    Toggle({ type: ToggleType.Switch, isOn: item.userEnabled })
                      .enabled(this.developerMode)
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
              // 键并入 userEnabled：只拿 id 当键的话，启停后同键复用旧组件，
              // Toggle 的 isOn 停在旧值（ref/04 铁律）。
              }, (item: ExtensionActionItem): string => `${item.id}-${item.userEnabled ? 1 : 0}`)
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
              // 加号而非下载箭头：「添加」分组里的安装入口，下载图形会让人
              // 以为是去下载扩展（装机反馈）。
              Image($r('app.media.aura_plus'))
                .width(22)
                .height(22)
                .fillColor($r('app.color.icon_primary'))

              Column({ space: 3 }) {
                Text(this.installing ? '正在安装…' : '从文件安装')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('选择已下载的 .crx 或 .zip 文件')
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
            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            .onClick(() => {
              this.installFromFile();
            })
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)

          // 「加载未打包」去向：1.0.147 装机反馈——zip 安装已覆盖分发场景，
          // 调试用目录加载走「原生扩展页」里的桌面版入口（那里本来就有），
          // 原生页不再单列一行。引擎侧 loadUnpackedExtension 命令保留，
          // 原生扩展页照常可用。
          Text('更多')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ top: 20, bottom: 10 })

          Column() {
            Row({ space: 12 }) {
              // 外跳箭头而非齿轮：这一行打开的是内核自带扩展管理界面（跳出去），
              // 齿轮是「设置项」的语义，放这儿词不达意（装机反馈）。
              Image($r('app.media.aura_open_in_new'))
                .width(22)
                .height(22)
                .fillColor($r('app.color.icon_primary'))

              // 1.0.154：主标题改「原生扩展页」，副标题说明它就是内核自带界面，
              // 与「从文件安装」同一行式（主 16 / 副 12）保持视觉一致。
              Column({ space: 3 }) {
                Text('原生扩展页')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('打开 Chromium 内核扩展管理界面')
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
            // 双行文案（主 16 + 副 12）：不写死 56，用上下 padding 撑开，
            // 与「从文件安装」一致的留白节奏，避免副标题被裁。
            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            .onClick(() => {
              this.openMoreSettings();
            })
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)
          .margin({ top: 12 })

          Text('点按扩展打开它的面板或设置；点"i"查看详情，权限、网站访问和卸载都在里边。扩展能读取和更改你访问的网页，只安装你信任的扩展。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ top: 14 })
        }
        .width('100%')
        // 大标题带：滚动内容穿过「扩展程序」大标题时逐渐虚化（见 GlassPage 文件头）。
        .padding({ top: glassHeaderInsetVp() })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
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
      Scroll(this.detailScroller) {
        Column() {
          if (this.detailMissing) {
            Text('这个扩展已经不在了。')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 20 })
          } else {
            // 扩展信息：版本/描述/作者随列表项带入（引擎 extensionActions
            // 本来就下发），没有内容的行不占位。
            if (this.detailVersion.length > 0 || this.detailDescription.length > 0 ||
              this.detailAuthor.length > 0) {
              Column({ space: 8 }) {
                if (this.detailVersion.length > 0) {
                  Row({ space: 12 }) {
                    Text('版本')
                      .fontSize(13)
                      .fontColor($r('app.color.text_secondary'))
                      .width(48)
                    Text(this.detailVersion)
                      .fontSize(13)
                      .fontColor($r('app.color.text_primary'))
                      .layoutWeight(1)
                  }
                  .width('100%')
                }
                if (this.detailDescription.length > 0) {
                  Row({ space: 12 }) {
                    Text('描述')
                      .fontSize(13)
                      .fontColor($r('app.color.text_secondary'))
                      .width(48)
                    Text(this.detailDescription)
                      .fontSize(13)
                      .fontColor($r('app.color.text_primary'))
                      .layoutWeight(1)
                  }
                  .width('100%')
                }
                if (this.detailAuthor.length > 0) {
                  Row({ space: 12 }) {
                    Text('作者')
                      .fontSize(13)
                      .fontColor($r('app.color.text_secondary'))
                      .width(48)
                    Text(this.detailAuthor)
                      .fontSize(13)
                      .fontColor($r('app.color.text_primary'))
                      .layoutWeight(1)
                  }
                  .width('100%')
                }
              }
              .width('100%')
              .padding(16)
              .borderRadius(16)
              .backgroundColor($r('app.color.card_background'))
              .clip(true)
            }

            // 「允许用户脚本」：桌面详情页同款开关。只有声明了 userScripts
            // 权限的扩展才出现（引擎侧同一道闸门）；不开它用户脚本跑不了。
            // 1.0.151：开发者模式是总闸——关闭时整个条置灰不可拨（此前能拨，
            // 拨了才回"当前策略不允许这个操作"，等于挖个坑给人跳）。
            if (this.detailUserScriptsAvailable) {
              Row({ space: 12 }) {
                Column({ space: 3 }) {
                  Text('允许用户脚本')
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.developerMode ?
                      $r('app.color.text_primary') : $r('app.color.text_secondary'))
                    .opacity(this.developerMode ? 1 : 0.5)
                  Text(this.developerMode ?
                    '让这个扩展运行用户脚本（脚本管理器类扩展必开）' :
                    '打开标题栏的「开发者模式」后才能设置')
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Toggle({ type: ToggleType.Switch, isOn: this.detailUserScriptsAllowed })
                  .enabled(this.developerMode)
                  .onChange((isOn: boolean) => {
                    // 不本地改状态：引擎 setExtensionUserScriptsAllowed 成功
                    // 后回一份最新详情（含新 allowed 值），以引擎为准。
                    this.onCommand({
                      command: 'setExtensionUserScriptsAllowed',
                      id: this.detailId,
                      enabled: isOn
                    });
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
              .borderRadius(16)
              .backgroundColor($r('app.color.card_background'))
              .clip(true)
              .margin({ top: 12 })
              .opacity(this.developerMode ? 1 : 0.5)
            }

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
        // 大标题带：滚动内容穿过扩展名大标题时逐渐虚化（见 GlassPage 文件头）。
        .padding({ top: glassHeaderInsetVp() })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      // Scroll centers content shorter than the viewport by default (the
      // universal `align` attribute defaults to Alignment.Center), which
      // showed up as a big gap under the header. Pin it to the top.
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
  }

  private listScroller: Scroller = new Scroller();
  private detailScroller: Scroller = new Scroller();

  // 位移基准 = 面板实际宽（vp），量不到时按常见手机宽兜底（360）。
  private pageWidthVp(): number {
    return this.viewportWidthVp > 16 ? this.viewportWidthVp : 360;
  }

  build() {
    GlassPage({
      title: this.page === 'detail' ? this.detailName : '扩展程序',
      scrollers: [this.listScroller, this.detailScroller],
      // 开发者模式开关进标题栏右侧（桌面 chrome://extensions 同款位置）。
      titleBarAction: (): void => this.DeveloperModeToggle(),
      onBack: (): void => {
        if (this.page === 'detail') {
          this.closeDetail();
        } else {
          this.onBack();
        }
      }
    }) {
    Column() {
      if (this.page === 'detail') {
        // 点"i"进详情要有过渡（装机反馈：无动画像闪变）。位移由 pageShift
        // 驱动、animateTo 起弹簧 —— 与设置面板二级页同一套机制。
        // ⚠️ 别改用 .transition()：真机上不产生可见动画（openPanel 注释里
        // 记过这个坑，1.0.149 用 .transition() 就是没生效）。
        Column() {
          this.DetailView()
        }
        .width('100%')
        .height('100%')
        .translate({ x: this.pageShift * this.pageWidthVp() })
        .opacity(1 - Math.abs(this.pageShift) * 0.2)
      } else {
        Column() {
          this.ListView()
        }
        .width('100%')
        .height('100%')
        .translate({ x: this.pageShift * this.pageWidthVp() })
        .opacity(1 - Math.abs(this.pageShift) * 0.2)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    // 量一次面板宽，给二级页横滑当位移基准。
    .onAreaChange((oldValue: Area, newValue: Area): void => {
      const measuredWidth: number = Number(newValue.width);
      if (measuredWidth > 16 && Math.abs(measuredWidth - this.viewportWidthVp) > 0.5) {
        this.viewportWidthVp = measuredWidth;
      }
    })

    }
  }
}
