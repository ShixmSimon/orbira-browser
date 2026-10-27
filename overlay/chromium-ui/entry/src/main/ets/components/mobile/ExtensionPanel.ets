/*
 * 手机扩展程序页。
 * 契约："手机上没有能用的 chrome://extensions，外壳自己画一页"。
 * 数据流：getExtensionActions / getExtensionDetails -> 对应事件
 * （AuraShell 转存到 'auraPanelExtensions' / 'auraPanelExtensionDetails'）；
 * 变更类事件的回音通过 'auraPanelEvent' 的 kind 过滤。
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { BrowserCommandPayload, ExtensionActionItem, ExtensionDetailsEvent, ExtensionSiteAccess } from 'engine';
import { glassHeaderInsetVp } from './GlassPage';
import { ExtIconCache } from './ExtIconCache';
import {
  HdsNavigation,
  HdsNavigationTitleMode,
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  hdsMaterial,
  ScrollEffectType
} from '@kit.UIDesignKit';

// extensionInstallFailed 没有官方接口，按契约字段从事件上取。
interface ExtensionNoticePayload {
  message?: string;
  reason?: string;
}

interface PanelEventPayload {
  kind?: string;
  message?: string;
  reason?: string;
  // extensionCommandFailed：哪条命令失败的（notFound 的含义随命令不同）。
  command?: string;
  // extensionReloadLanded：重载之后引擎观察到的状态。
  enabled?: boolean;
  blocked?: boolean;
  stuckReloading?: boolean;
  pathExists?: boolean;
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
  // A' 面板页化（Phase 3）：改由 AppStorage 读取（overlay onBrowserStateChanged 已同步）。
  @StorageLink('auraCurrentUrl') currentUrl: string = '';

  @State private items: ExtensionActionItem[] = [];
  @State private page: string = 'list';
  @State private detailId: string = '';
  @State private detailName: string = '';
  @State private detailPermissions: string[] = [];
  @State private detailSiteAccess: string = '';
  @State private detailSiteAccessChangeable: boolean = false;
  @State private detailMissing: boolean = false;
  @State private installing: boolean = false;
  // 重新载入命令是否已发出、还在等引擎回执（extensionReloadLanded）。
  // 不参与渲染，故不用 @State。
  private reloadPending: boolean = false;
  // 详情页的扩展信息（引擎列表项本来就有下发，打开详情时随 item 带入）。
  @State private detailVersion: string = '';
  @State private detailDescription: string = '';
  @State private detailAuthor: string = '';
  // 详情页「扩展选项」是否可点：manifest 注册的 options 页 URL（引擎随列表项
  // 下发）。空 = 没有选项页，点下去只能等引擎回 notFound——此时就地提示，
  // 不收起面板（收起=让开网页层，但游标页根本不会开，等于"点了没反应"）。
  @State private detailOptionsUrl: string = '';
  // 详情页「允许运行用户脚本」：只有声明了 userScripts 权限的扩展才显示
  // （脚本猫这类用户脚本管理器正是如此）；不开它，用户脚本跑不了。
  @State private detailUserScriptsAvailable: boolean = false;
  @State private detailUserScriptsAllowed: boolean = false;
  // 标题栏「开发者模式」开关：profile 级设置（加载未打包的前提），
  // 状态永远以引擎为准——setDeveloperMode 成功后引擎会回 developerMode 事件。
  @State private developerMode: boolean = false;
  @State private developerModeAvailable: boolean = true;
  // 1.0.157：真 Navigation 路由栈（GlassPage 内嵌原生 Navigation+NavPathStack）。
  // 列表为 home route，详情为 navDestination('detail')，系统自动走鸿蒙7层级转场。
  @State private pathStack: NavPathStack = new NavPathStack();
  @State private pageTitle: string = '扩展程序';
  // 开发者模式总闸的快照：关闭总闸那一刻各扩展的开关状态（id -> 原开关值），
  // 用于重新打开总闸时逐个恢复。非 UI 状态，用普通字段（改动不必触发刷新）。
  private enabledSnapshot: Record<string, boolean> = {};
  private requestSeq: number = 0;
  private retryTimer: number = -1;
  // 图标迟到兜底：引擎启停扩展后 iconPngBase64 异步重生成，常晚于回包到达，
  // 若不补拉图标会卡在空态（装机反馈：开发者模式开关后要退出重进才见图标）。
  // 带次数上限防死循环。
  private iconCatchupTimer: number = -1;
  private iconRetryCount: number = 0;
  // 解码失败的图标串（引擎偶发给坏串）：这些 id 不再画 Image，退化成字母块。
  @State private brokenIconIds: string[] = [];
  // 图标位图缓存：base64 在应用层解成 PixelMap 再交给 Image（比直接把
  // data: URL 给 Image 稳——解码失败我们能立刻知道，且位图拿到手就不怕引擎
  // 之后把 iconPngBase64 清空）。Map 不是 @State，靠 iconPixelsVersion 触发重绘。
  private iconPixels: Map<string, image.PixelMap> = new Map();
  private iconPixelSource: Map<string, string> = new Map();
  @State private iconPixelsVersion: number = 0;

  aboutToAppear(): void {
    // Seed from storage first: a @StorageLink does not fire @Watch for its
    // initial value, and a byte-identical engine reply raises no change
    // either, so a re-opened panel would otherwise lose the list.
    this.onExtensionsPayload();
    this.onDeveloperModePayload();
    this.reload();
    // 图标持久缓存：异步读盘，回来后给当前列表补一次（引擎还没重新生成完的
    // 空图标直接用上次的）。
    const host = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    ExtIconCache.hydrate(host).then((): void => {
      // 1.0.241：重开后从磁盘缓存补回的 base64 也要重新解成 PixelMap（否则只能
      // 走 data: URL 回退；且不清 broken 标记时，上次卡住的坏图会残留）。
      this.items = this.mergeIconCache(this.items);
      this.decodeIcons(this.items);
    });
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
    if (this.iconCatchupTimer !== -1) {
      clearTimeout(this.iconCatchupTimer);
      this.iconCatchupTimer = -1;
    }
  }

  // 启用的扩展若图标仍为空，说明引擎侧图标还没重生成完 → 稍后补拉一次。
  // 有图标进来即清零计数；连续补拉仍无图标（扩展本身就没有图标）则停手。
  private scheduleIconCatchup(): void {
    let missing = false;
    this.items.forEach((entry: ExtensionActionItem): void => {
      if (entry.userEnabled && entry.iconPngBase64.length === 0) {
        missing = true;
      }
    });
    if (!missing) {
      this.iconRetryCount = 0;
      return;
    }
    this.iconRetryCount += 1;
    if (this.iconRetryCount > 5) {
      return;
    }
    if (this.iconCatchupTimer !== -1) {
      clearTimeout(this.iconCatchupTimer);
    }
    this.iconCatchupTimer = setTimeout((): void => {
      this.iconCatchupTimer = -1;
      this.reload();
    }, 700);
  }

  private reload(): void {
    this.requestSeq += 1;
    // 显式要 96px 的方形图标（省略时引擎按 32px 给，放到 40vp 的行里会糊）。
    this.onCommand({
      command: 'getExtensionActions',
      requestId: this.requestSeq,
      iconSizePx: 96
    });
  }

  private onExtensionsPayload(): void {
    if (this.extensionsJson.length === 0) {
      return;
    }
    try {
      this.items = this.mergeIconCache(JSON.parse(this.extensionsJson) as ExtensionActionItem[]);
      this.scheduleIconCatchup();
      this.decodeIcons(this.items);
    } catch (error) {
    }
  }

  // 把每项的图标 base64 解成 PixelMap（异步）。解好的位图常驻内存，引擎之后
  // 把 iconPngBase64 清空也不影响显示。
  private decodeIcons(list: ExtensionActionItem[]): void {
    for (const entry of list) {
      const raw = entry.iconPngBase64;
      if (raw.length === 0) {
        continue;
      }
      // 1.0.241：只要拿到非空图标就撤销该 id 的「坏图」标记——引擎启停扩展后
      // 会异步重生成图标，空窗里可能回过一次解不开的串把 id 标成 broken；若不再
      // 给重试机会，图标会一直只显示字母块、直到重开面板才恢复（装机反馈
      // 「图标时有时无、退出重进才恢复」的根因之一）。每来一份新非空 base64 都
      // 清一次，让下方解码 / data: URL 回退重新尝试，自己愈合。
      if (this.iconBroken(entry.id)) {
        this.clearIconBroken(entry.id);
      }
      if (this.iconPixels.has(entry.id) && this.iconPixelSource.get(entry.id) === raw) {
        continue;
      }
      this.decodeOne(entry.id, raw);
    }
  }

  private async decodeOne(id: string, raw: string): Promise<void> {
    try {
      const helper = new util.Base64Helper();
      const bytes = helper.decodeSync(raw);
      const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
      const source = image.createImageSource(buffer as ArrayBuffer);
      const pixel = await source.createPixelMap({
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      this.iconPixels.set(id, pixel);
      this.iconPixelSource.set(id, raw);
      if (this.iconBroken(id)) {
        const kept: string[] = [];
        for (const item of this.brokenIconIds) {
          if (item !== id) {
            kept.push(item);
          }
        }
        this.brokenIconIds = kept;
      }
      this.iconPixelsVersion += 1;
    } catch (error) {
      this.markIconBroken(id);
    }
  }

  private pixelMapOf(id: string): image.PixelMap | undefined {
    return this.iconPixels.get(id);
  }

  // 图标空窗兜底：引擎给过一次的图标都存进 ExtIconCache（落盘持久）。回包里
  // iconPngBase64 为空的项直接用缓存补上，非空的顺手记一笔——开关扩展时
  // 图标不再时有时无。
  private mergeIconCache(list: ExtensionActionItem[]): ExtensionActionItem[] {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    return list.map((entry: ExtensionActionItem): ExtensionActionItem => {
      if (entry.iconPngBase64.length > 0) {
        ExtIconCache.put(entry.id, entry.iconPngBase64, context);
        return entry;
      }
      const cached = ExtIconCache.get(entry.id);
      if (cached.length === 0) {
        return entry;
      }
      // 逐字段重建（ArkTS 禁止对象展开）。
      const patched: ExtensionActionItem = {
        id: entry.id,
        name: entry.name,
        iconPngBase64: cached,
        badgeText: entry.badgeText,
        badgeColor: entry.badgeColor,
        enabled: entry.enabled,
        pinned: entry.pinned,
        userEnabled: entry.userEnabled,
        disableReasons: entry.disableReasons,
        hasPopup: entry.hasPopup,
        optionsUrl: entry.optionsUrl,
        version: entry.version,
        description: entry.description,
        author: entry.author
      } as ExtensionActionItem;
      return patched;
    });
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
        this.pageTitle = '扩展程序';
        if (this.pathStack.size() > 1) {
          this.pathStack.pop();
        }
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
      // 重新载入是否落地改由 extensionReloadLanded 报告：重载调用没有返回值，
      // 只有引擎观察到的状态才可信（本事件在别的场合也会发）。
      this.reloadPending = false;
      this.reload();
      if (this.page === 'detail' && this.detailId.length > 0) {
        this.requestSeq += 1;
        this.onCommand({ command: 'getExtensionDetails', requestId: this.requestSeq, id: this.detailId });
      }
    } else if (kind === 'extensionReloadReceived') {
      // 引擎回执：命令确实到达了 native。重载是否真的落地，由随后的
      // extensionReloadLanded 用观察到的状态说明。
      this.getUIContext().getPromptAction().showToast({
        message: '引擎已收到重载请求',
        duration: 1500
      });
    } else if (kind === 'extensionReloadLanded') {
      // 落地回执：重载调用没有返回值，只能用引擎观察到的状态说话，据此区分
      // 「真的重载了」与「被某一支静默 return 挡下」。
      this.reloadPending = false;
      let landed: string;
      if (payload.enabled === true) {
        landed = '已重新载入';
      } else if (payload.blocked === true) {
        landed = '重载未执行：扩展在黑名单中';
      } else if (payload.stuckReloading === true) {
        landed = '重载未执行：上一次重载未结束';
      } else if (payload.pathExists !== true) {
        landed = '重载未执行：安装目录已不存在';
      } else {
        landed = '重载未执行：扩展未回到启用状态';
      }
      this.getUIContext().getPromptAction().showToast({
        message: landed,
        duration: 2500
      });
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
        // openExtensionOptions 的 notFound 是"没有选项页"，不是扩展不存在。
        message = String(payload.command ?? '') === 'openExtensionOptions'
          ? '该扩展没有选项页。'
          : '扩展不存在或已被移除。';
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
    // popup 挂在浏览器**窗口层**（引擎 ExtensionPopup::ShowPopupAtShellRect，
    // 拿不到锚点时落到窗口底部中央），http(s)、chrome:// 与
    // chrome-extension:// 页都能承载它——唯独主页不行：外壳的 HomeSurface
    // 盖层铺满全屏，会把 popup 压在底下，点了像没反应。所以只在主页
    // （新标签页）请求 HomeSurface 让位（auraPopupHomeHold），返回键、离开
    // 主页或兜底超时（AuraShell 的 onPopupHomeHoldChanged，10 分钟，只在
    // popup 关闭事件丢失时才轮到它）时恢复；其余场景一律放行。
    // 1.0.148 起守卫只管真有 popup 的扩展（item.hasPopup，引擎按
    // action.default_popup 下发）；没有 popup 的（调姬助手这类）一直放行。
    if (item.hasPopup && this.isNewTabUrl(this.currentUrl)) {
      AppStorage.setOrCreate('auraPopupHomeHold', Date.now());
    }
    // The extension's popup panel is drawn by native above the web layer --
    // under this full-screen page. Dismiss the page so the popup is
    // visible; reopen the extensions page to see list changes.
    this.onClose();
    this.onCommand({ command: 'runExtensionAction', id: item.id });
  }

  // 与 MobileBrowserOverlay.isNewTabUrl 同一份判据（引擎换 URL 写法时一起改）。
  private isNewTabUrl(url: string): boolean {
    return url.startsWith('chrome://newtab') ||
      url.startsWith('chrome://new-tab-page') ||
      url.startsWith('chrome://new-tab-page-third-party') ||
      url.startsWith('chrome-native://newtab');
  }

  // 扩展的选项页：引擎 ExtensionTabUtil::OpenOptionsPage 新开标签页打开
  // manifest 注册的 options 页——走导航而不是 popup，主页上也能进。
  // ⚠️ 选项页画在**网页层**，本页是全屏面板、会把它整个盖住：必须像
  // runExtension 那样先 onClose（收起本页回浏览器）再发命令，否则新标签页
  // 开在面板背后，表现为「点击无反应」。没有选项页的扩展（detailOptionsUrl
  // 为空）引擎只会回 notFound，而面板收起后就没人显示失败文案了——就地
  // 提示、不收起。
  private openOptionsPage(): void {
    if (this.detailId.length === 0) {
      return;
    }
    if (this.detailOptionsUrl.length === 0) {
      this.getUIContext().getPromptAction().showToast({
        message: '该扩展没有选项页',
        duration: 1500
      });
      return;
    }
    this.onClose();
    this.onCommand({ command: 'openExtensionOptions', id: this.detailId });
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
    this.detailOptionsUrl = item.optionsUrl ?? '';
    this.detailUserScriptsAvailable = false;
    this.detailUserScriptsAllowed = false;
    // 1.0.157：改用真 Navigation 路由栈（GlassPage 内嵌原生 Navigation+NavPathStack）。
    // 详情作为 navDestination('detail') 推入，系统自动走鸿蒙7层级转场（干净减速、零过冲）。
    this.page = 'detail';
    this.pageTitle = item.name;
    this.pathStack.pushPathByName('detail', item.id);
    this.requestSeq += 1;
    this.onCommand({ command: 'getExtensionDetails', requestId: this.requestSeq, id: item.id });
  }

  // 详情 → 列表：pop 路由栈回到列表（系统自动反向转场，原生无回弹）。
  private closeDetail(): void {
    this.page = 'list';
    this.pageTitle = '扩展程序';
    if (this.pathStack.size() > 0) {
      this.pathStack.pop();
    }
  }

  // navDestination('detail') 的内容构建器：必须作为本组件成员 @Builder 直接被
  // HdsNavigation.navDestination 引用（编译器静态内联）—— 经 prop/箭头中转会
  // 导致 builder UI 不组装 → 白屏。子页用 HdsNavDestination 并带自己的 HDS
  // 标题栏（avoidLayoutSafeArea 处理状态栏避让），系统走原生鸿蒙层级转场。
  @Builder
  private buildDetailDestination(_name: string, _param: Object): void {
    HdsNavDestination() {
      Column() {
        this.DetailView()
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height('100%')
    .titleBar({
      content: {
        title: { mainTitle: this.detailName },
        backIcon: {
          icon: $r('sys.symbol.chevron_backward'),
          isEnabled: true,
          action: (): void => {
            this.closeDetail();
          }
        }
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
      this.closeDetail();
      return true;
    })
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

  // 重新载入：Chromium 的 reloadExtension —— 重新读取扩展文件并重启它
  // （chrome://extensions 卡片上的刷新按钮；改完未打包扩展的代码后回到干净状态）。
  // 1.0.180 起详情页入口暂时隐藏（见 build 里该处注释），此方法与
  // extensionReloadLanded 回执一并保留，入口放回即恢复。
  private reloadExtension(): void {
    if (this.detailId.length === 0) {
      return;
    }
    this.reloadPending = true;
    this.onCommand({ command: 'reloadExtension', id: this.detailId });
    // 重载成功后详情页数据往往不变、列表的刷新发生在底层看不见，没有提示就会
    // 被当成"点了没反应"；重载是否真的落地，由 extensionReloadLanded 用引擎
    // 观察到的状态说明。失败则由 extensionCommandFailed 弹对话框说明原因。
    this.getUIContext().getPromptAction().showToast({
      message: '正在重新载入扩展…',
      duration: 2000
    });
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
    // 1.0.243：首字母块不再永远画在底层。真实扩展图标普遍带透明区域
    // （云形/爪形/异形 logo），底层灰底+字母会从透明处透出来——装机反馈
    // 「扩展页面图标后显示首字母」即此观感。改为：位图或 data:URL 可用时
    // 不画字母块，全部来源失败（引擎无图标+缓存无+上份串解不开）才退化。
    // 1.0.160：停用（开发者模式关闭）的扩展图标置灰 + 压暗 —— 与桌面 Chrome
    // chrome://extensions 的停用态一致；此前停用也显示全彩图标，分不清启停。
    Stack({ alignContent: Alignment.Center }) {
      if (!(this.iconPixelsVersion >= 0 && this.pixelMapOf(item.id) !== undefined) &&
        !(iconSource(item).length > 0 && !this.iconBroken(item.id))) {
        Text(extensionInitial(item.name))
          .width(size)
          .height(size)
          .borderRadius(size / 4)
          .backgroundColor($r('app.color.surface_secondary'))
          .fontSize(size / 2.2)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .textAlign(TextAlign.Center)
          .opacity(item.userEnabled ? 1 : 0.45)
      }

      // 版本号参与条件：位图解好时靠它触发重绘（Map 本身不是 @State）。
      if (this.iconPixelsVersion >= 0 && this.pixelMapOf(item.id) !== undefined) {
        Image(this.pixelMapOf(item.id))
          .width(size)
          .height(size)
          .borderRadius(size / 4)
          .grayscale(item.userEnabled ? 0 : 1)
          .opacity(item.userEnabled ? 1 : 0.45)
      } else if (iconSource(item).length > 0 && !this.iconBroken(item.id)) {
        // 位图还没解好（或解不动）时先用 data: URL；Image 解不开 →
        // onError 标 broken，下次重绘翻到字母块；新非空 base64 到达时
        // decodeIcons 会撤销 broken 给重试机会（1.0.241 自愈机制）。
        Image(iconSource(item))
          .width(size)
          .height(size)
          .borderRadius(size / 4)
          .grayscale(item.userEnabled ? 0 : 1)
          .opacity(item.userEnabled ? 1 : 0.45)
          .onError((): void => {
            this.markIconBroken(item.id);
          })
      }
    }
    .width(size)
    .height(size)
    .clip(true)
  }

  private iconBroken(id: string): boolean {
    return this.brokenIconIds.indexOf(id) >= 0;
  }

  private markIconBroken(id: string): void {
    if (this.iconBroken(id)) {
      return;
    }
    this.brokenIconIds.push(id);
    // 重新赋值触发 @State 更新（ArkUI 对数组原地修改不重渲染）。
    this.brokenIconIds = this.brokenIconIds.slice();
  }

  // 撤销坏图标记（1.0.241）：新非空 base64 到达时调用，给解码/回退一次重试机会。
  private clearIconBroken(id: string): void {
    if (!this.iconBroken(id)) {
      return;
    }
    const kept: string[] = [];
    for (const item of this.brokenIconIds) {
      if (item !== id) {
        kept.push(item);
      }
    }
    this.brokenIconIds = kept;
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
    // 1.0.157c：改自持 HdsNavigation 后，列表自身补回左右留白
    //（原 GlassPage 时代由 body 外层 Column 提供）。
    .padding({ left: 16, right: 16 })
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

            // 「允许运行用户脚本」：桌面详情页同款开关。只有声明了 userScripts
            // 权限的扩展才出现（引擎侧同一道闸门）；不开它用户脚本跑不了。
            // 1.0.151：开发者模式是总闸——关闭时整个条置灰不可拨（此前能拨，
            // 拨了才回"当前策略不允许这个操作"，等于挖个坑给人跳）。
            if (this.detailUserScriptsAvailable) {
              Row({ space: 12 }) {
                Column({ space: 3 }) {
                  Text('允许运行用户脚本')
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

            // 重新载入入口暂时隐藏（1.0.180）：用户反馈点它「不能用」——
            // 重载是读盘重启扩展，对常规装机用户没有可感效果，留着只会被
            // 当成坏按钮。机制全部保留（reloadExtension 命令与 native 处理器、
            // 本文件的 reloadExtension() 方法、extensionReloadLanded 回执），
            // 需要时把下面这块整段放回即可：
            //   Column() { Row({space:12}) { chromium_reload 图标 +
            //   「重新载入 / 重新读取扩展文件并重启」+ aura_chevron }
            //   .onClick(() => this.reloadExtension()) }
            //   .borderRadius(16).backgroundColor(card_background)
            //   .clip(true).margin({ top: 26 })

            // 扩展选项：chrome://extensions 卡片「详情」里的选项页——
            // 新开标签页直达 manifest 注册的 options 页，不经过 popup 守卫，
            // 主页上也能进（脚本猫的「我的脚本」这类完整界面就在这里）。
            Column() {
              Row({ space: 12 }) {
                Image($r('app.media.chromium_settings'))
                  .width(22)
                  .height(22)
                  .fillColor($r('app.color.icon_primary'))

                Column({ space: 3 }) {
                  Text('扩展选项')
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                  Text('新开标签页打开该扩展的选项页')
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .onClick(() => {
                this.openOptionsPage();
              })
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor($r('app.color.card_background'))
            .clip(true)
            .margin({ top: 12 })

            Button('卸载扩展')
              .width('100%')
              .height(46)
              .fontSize(16)
              .fontColor($r('app.color.danger'))
              .backgroundColor($r('app.color.card_background'))
              .borderRadius(16)
              .margin({ top: 12 })
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

  build() {
    // 1.0.157：面板自己持有 HdsNavigation + NavPathStack，详情页经由 navDestination
    // 直接引用本组件成员 buildDetailDestination 推入 —— 系统默认走原生鸿蒙7层级转场
    // （干净减速、零过冲、无回弹，无需任何额外转场配置）。
    // 列表页在底层保持挂载，返回时自动恢复滚动位置。
    HdsNavigation(this.pathStack) {
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          this.ListView()
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
    }
    .titleBar({
      content: {
        title: { mainTitle: '扩展程序' },
        backIcon: {
          icon: $r('sys.symbol.chevron_backward'),
          isEnabled: true,
          action: (): void => {
            this.onBack();
          }
        },
        menu: undefined,
        stackBuilder: (): void => this.DeveloperModeToggle()
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
    .bindToScrollable([this.listScroller])
    .backgroundColor($r('app.color.page_background'))
    .navDestination(this.buildDetailDestination)
    .width('100%')
    .height('100%')
  }
}
