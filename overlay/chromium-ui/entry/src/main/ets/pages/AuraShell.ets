/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { common, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { inputMethod } from '@kit.IMEKit';
import { ShellUiPrefs } from '../utils/appearance/ShellUiPrefs';
import { SearchEnginesPrefs } from '../utils/appearance/SearchEnginesPrefs';
import { IncognitoSwitch, SavedTab } from '../utils/IncognitoSwitch';
import { WebWindow, PictureInPictureSurface } from 'engine';
import { MobileBrowserOverlay, TOP_BAR_EXTENT_VP, CHROME_DOCK_EXTENT_VP, CHROME_DOCK_FLOAT_MARGIN_VP, dockCoveredHeightVp } from '../components/mobile/MobileBrowserOverlay';
import { MobileBackRouter } from '../components/mobile/MobileBackRouter';
import { HomeSurface } from '../components/mobile/HomeSurface';
import { CurrentTabCastSession } from '../components/mobile/CurrentTabCastSession';
import {
  buildContextMenuModel,
  ContextMenuModel,
  parseContextMenuModel,
  showContextMenuSheet,
  updateContextMenuModel
} from '../components/mobile/ContextMenuSheet';
import { BrowserOnboarding } from '../components/onboarding/BrowserOnboarding';
import {
  AuxiliaryWindowState,
  BrowserCommandPayload,
  BrowserRuntimeEvent,
  BrowserStateSnapshot,
  BrowserTabState,
  DeveloperModeEvent
} from 'engine';
import { CHROMIUM_HOME_URL } from 'engine';
import { HuaweiKnockShareSession, HuaweiShareAdapter } from 'engine';
import { HarmonyFilePickerAdapter, HarmonyFilePickerResult } from 'engine';
import { PermissionRequestAdapter, PermissionRequestResultPayload } from 'engine';
import {
  AboutInfoEvent,
  AutocompleteResultsEvent,
  BookmarkExportDoneEvent,
  BookmarkImportDoneEvent,
  BrowserCommandChannel,
  DownloadListEvent,
  DownloadNotifier,
  DownloadUpdatedEvent,
  ExtensionActionsEvent,
  ExtensionDetailsEvent,
  ExtensionReloadLandedEvent,
  FaviconsEvent,
  HistoryResultsEvent,
  BookmarkListEvent,
  PageFullscreenChangedEvent,
  PasswordCommandResultEvent,
  PasswordRevealedEvent,
  PasswordsExportedEvent,
  PasswordsImportedEvent,
  PrefsEvent,
  PullToRefreshEvent,
  RecentBookmarksEvent,
  RecentlyClosedEvent,
  SavedPasswordsEvent,
  SearchEngine,
  SearchEnginesEvent,
  ShellDownloadDirectory,
  SiteSettingsEvent,
  TabThumbnailsEvent,
  TopSitesEvent,
  shellEvent
} from 'engine';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SystemPrintAdapter } from 'engine';
import { ChromiumSystemAction, SystemIntegrationAdapter } from 'engine';
import { PwaWindowLauncher } from '../utils/PwaWindowLauncher';
import {
  AUXILIARY_WINDOW_MARGIN_VP,
  AuxiliaryWindowView,
  layoutAuxiliaryWindow,
  ScreenSizeVp
} from 'engine';
import { BrowserProfileState } from '../utils/profile/BrowserProfileService';

// extensionInstallFailed / extensionCommandFailed have no shell-service
// interface; they carry Chromium's own sentence for the reader to show.
interface ExtensionNoticePayload {
  message?: string;
  reason?: string;
  // extensionCommandFailed: which command failed -- notFound means different
  // things per command (no options page vs no such extension).
  command?: string;
}

// 上手兜底触发位移（vp）：手指在页面区划过这么多、且引擎全程没动过顶栏比例，
// 才由外壳接手——收 dock，或把已被收起的顶栏放回来（见 onSwipeControlsTouch）。
// 取得比顶栏高度小，避免"要划很久才有反应"。
const SWIPE_TRIGGER_VP: number = 28;
// 判据：引擎是否在本次手势里自己动过顶栏比例（动过说明页面真的在滚 → 让位）。
const CONTROLS_RATIO_EPS: number = 0.02;
// 键盘避让区报的 bottomRect 比「页面该留出的高度」小一截。实测标定（同一键盘、
// 同一页面尺寸）：补 44 → 页内固定底栏第一行表情完整、第二行被挡；补 70 → 两行
// 完整但离键盘还差半个表情（搜狐、贴吧同一量级，约 15vp）。取 85。
// ⚠️ 这是按实测标定的常数：各站页面自身底部留白不同，个别站点仍可能差几 vp。
const KEYBOARD_INSET_EXTRA_VP: number = 85;

// 引擎原生新标签页的几种 URL 形态。引擎自己 newTab 用的是 chrome://newtab/
// （aura_shell_runtime_bridge.cc 里 NavigateOnUiThread(GURL("chrome://newtab/"))），
// 但 Chromium 的 WebUI 别名、以及部分版本用的 chrome-native:// 都可能出现——
// 与 MobileBrowserOverlay.isNewTabUrl 保持同一份判据（历史上两边只认了一种，
// 引擎换一种写法就会「盖不住原生新标签页」）。
function isNewTabUrl(url: string): boolean {
  return url.startsWith('chrome://newtab') ||
    url.startsWith('chrome://new-tab-page') ||
    url.startsWith('chrome-native://newtab');
}

const EMPTY_BROWSER_STATE: BrowserStateSnapshot = {
  version: 1,
  mobileUi: false,
  uiFamily: '',
  ready: false,
  tabCount: 0,
  activeTabIndex: -1,
  sidePanelVisible: false,
  sidePanelEntryId: '',
  focusedTarget: 'webContents',
  activationEpoch: 0,
  tabs: [],
  url: CHROMIUM_HOME_URL,
  domain: '',
  title: 'Orbira',
  loading: false,
  canGoBack: false,
  canGoForward: false,
  isPwaWindow: false,
  pwaAppId: '',
  pwaStartUrl: ''
};

@Entry
@Component
struct AuraShell {
  @StorageLink('auraRoutingRevision') @Watch('onRoutingRevisionForThemeReload') routingRevision: number = 0;
  @StorageLink('auraThemeReloadPending') themeReloadPending: boolean = false;
  @StorageLink('auraStartupConfig') startupConfigText: string = '';
  @StorageLink('auraStartUrl') startUrl: string = CHROMIUM_HOME_URL;
  @StorageLink('auraAppVisible') @Watch('onAppVisibleChanged') appVisible: boolean = true;
  // 上滑时隐藏状态栏: address bar collapses -> the status bar hides with it
  // and the page fills the screen (the 外观 toggle). Hysteresis keeps
  // the system bar from flapping at the collapse boundary.
  @StorageLink('auraBrowserControlsRatio') @Watch('onControlsRatioMoved') scrolledRatio: number = 1;
  @StorageLink('auraHideStatusBarOnScroll') @Watch('onHideStatusBarPrefChanged') hideStatusBarOnScroll: boolean = false;
  // 滚动时隐藏地址栏（设置-外观）：默认开；关掉时 minTop 抬到顶栏全高，
  // 顶栏常显、不随滚动收起（引擎把 ratio 锁在 1）。
  @StorageLink('auraHideTopBarOnScroll') @Watch('onHideTopBarPrefChanged') hideTopBarOnScroll: boolean = true;
  // 地址栏编辑态（MobileBrowserOverlay 同步）：编辑时控件被钉住，上滑兜底让位。
  @StorageLink('auraAddressEditing') addressEditing: boolean = false;
  // “滚动时隐藏底部栏”（dock）：默认开（两栏跟手同收）；关掉后 dock 常驻，
  // 页面底部为它让出高度（见 applyDockViewportInset）。
  @StorageLink('auraHideDockOnScroll') @Watch('onHideDockPrefChanged') hideDockOnScroll: boolean = true;
  // 1.0.91 主页风格与 Chrome 风格 dock 位置；变化时重发浏览器控件 inset。
  @StorageLink('auraHomeStyle') @Watch('onHomeStyleChanged') homeStyle: string = 'minimal';
  @StorageLink('auraDockPosition') @Watch('onDockPositionChanged') dockPosition: string = 'bottom';
  // 网页外链是否交给本机应用打开（知乎/B站等 scheme）。默认开；关掉后
  // externalUrlRequested 一律走 fallbackUrl，留在浏览器里。
  @StorageLink('auraExternalAppLinks') externalAppLinks: boolean = true;
  // 扩展 popup 让位：主页（新标签页）上点扩展时由 ExtensionPanel 置值，
  // 让 HomeSurface 暂时让位给原生 popup；返回键、离开主页、或收到引擎的
  // extensionPopupClosed 事件（popup widget 销毁）时清零恢复。native 侧
  // ExtensionPopupCloseWatcher 监听 popup widget 销毁并派发该事件，所以
  // 关闭后主页立即回来（1.0.175）——这条才是日常路径，popup 想开多久开多久。
  // 定时器不是「自动关闭」而是最后防线：只在上面几条都没能触发的极端情况
  // （比如 popup widget 泄漏、事件丢失）下把主页层放回来，否则 HomeSurface
  // 会永久让位、主页磁贴再也出不来。10 分钟远超任何正常驻留时长，日常不会
  // 碰到（1.0.175 定 8 秒时误按「页面很快就该 done」来设，实际是 popup 的
  // 存活时长，于是开着看内容的 popup 到点就被主页盖住，1.0.208 修正）。
  @StorageLink('auraPopupHomeHold') @Watch('onPopupHomeHoldChanged') popupHomeHold: number = 0;
  private popupHoldTimer: number = -1;

  private onPopupHomeHoldChanged(): void {
    hilog.info(0x0000, 'ExtPanel', 'popupHomeHold -> %{public}d', this.popupHomeHold);
    if (this.popupHomeHold > 0) {
      if (this.popupHoldTimer !== -1) {
        clearTimeout(this.popupHoldTimer);
      }
      this.popupHoldTimer = setTimeout((): void => {
        this.popupHoldTimer = -1;
        if (this.popupHomeHold > 0) {
          AppStorage.setOrCreate('auraPopupHomeHold', 0);
        }
        // 10 分钟：见字段注释。这里恢复的是「主页层」，popup 本身由用户或
        // 引擎关闭，走到这一支说明关闭事件没送达。
      }, 600000);
    } else if (this.popupHoldTimer !== -1) {
      clearTimeout(this.popupHoldTimer);
      this.popupHoldTimer = -1;
    }
  }
  private statusBarHiddenByScroll: boolean = false;
  // 网页自己进了全屏（video / requestFullscreen）。引擎把页面铺满自己的区域，
  // 外围的状态栏与条带要让开：隐藏系统栏 + 控件高度清零（见 setPageFullscreen）。
  private pageFullscreen: boolean = false;
  // 1.0.103：顶栏是否已「完全收起」（贴状态栏底模式的静息态）。视口底部内距按它
  // 追加 topSafe 补偿——否则滚到页尾最后 ~topSafe 够不到（见 applyDockViewportInset
  // 与 computeTopBarHiddenForInset）。
  private topBarHiddenForInset: boolean = false;
  // 键盘避让高度（EntryAbility 写；RESIZE 模式为 0，不重复扣减）。键盘弹起时底部
  // 内距必须换成它——setViewportInsets 是替换式，留着 dock 的值会把键盘 inset
  // 盖掉，页内固定底栏（评论输入条等）会跑到键盘后面被遮。
  @StorageLink('auraKeyboardVp') @Watch('onKeyboardVpChanged') keyboardVpForInset: number = 0;
  @StorageLink('auraThemeFontId') themeFontId: string = '';
  @StorageLink('auraThemeFontRevision') themeFontRevision: number = 0;
  @StorageLink('auraOnboardingReady') onboardingReady: boolean = false;
  @StorageLink('auraOnboardingComplete') onboardingComplete: boolean = false;
  @StorageLink('auraProfileId') profileId: string = 'local';
  @StorageLink('auraProfileKind') profileKind: string = 'local';
  @StorageLink('auraSyncMode') syncMode: string = 'off';
  // 无痕会话：EntryAbility 从启动 want 里读出来（进/出无痕都靠重启应用，见
  // utils/IncognitoSwitch.ets）。置位时 WebWindow 挂到 incognito 这个
  // profile 上，用的是一整套独立的用户数据目录。
  @StorageLink('auraIncognito') incognito: boolean = false;
  // v8a diagnostic: the last ArkTS-level crash (written by EntryAbility's
  // crash recorder). Non-empty switches the shell into the crash report
  // page, which keeps the normal UI off the screen so a crash loop can be
  // read and copied out instead of repeated.
  @State private crashReport: string = '';
  @State private browserState: BrowserStateSnapshot = EMPTY_BROWSER_STATE;
  // 从主页（快捷方式/搜索框）发起导航后，把主页浮层按住到新页面真正画出来：
  // URL 一离开 chrome://newtab 就撤浮层的话，会露出垫在下面的引擎原生新
  // 标签页（白底磁贴，实测会闪一下）。loading true->false 即加载完成；
  // 回到主页立即放手；8 秒超时兜底（页面卡死时不再捂着主页）。
  @State private homeHold: boolean = false;
  private homeHoldSawLoading: boolean = false;
  private homeHoldTimer: number = -1;
  // 兜底定时器的续命次数（加载中不撤防，见 holdHomeForPaint 注释）。
  private homeHoldExtensions: number = 0;
  // 「秒开页」的快速撤防确认（见 onBrowserState 的 homeHold 分支）。
  private homeHoldQuickTimer: number = -1;
  // 1.0.68：「主页键」立即铺主页层（1.0.68）：按下后引擎要过一两帧才 commit URL，这
  // 一两帧里引擎已清成白底 → "回主页闪一下"（真机反馈）。按下即挂 HomeSurface
  // 盖住，URL 落成 chrome://newtab 后（或 1.2s 兜底）撤防。
  @State private homeReturnCover: boolean = false;
  // 「回主页又弹回原网页」的自愈重试：兜底撤防时若引擎还没把 tab 带回新标签
  // 页，重发一次 home。只重试一次，防引擎真不可用时永久捂住主页层。
  private homeRetryDone: boolean = false;
  private homeReturnTimer: number = -1;
  // 1.0.120：导航预热层。跳去某个真网址时（冷启动的「网址主页」/ 主页键的
  // 自定义主页），引擎会把画面清掉、而新页要一两帧才画出来，中间露的就是引擎
  // 底板（#3A3A3A，浅色下观感即「闪黑」——真机反馈）。这里铺一块与外壳同色
  // 的底顶住，等目标页**首帧真的提交**再淡出。
  // 1.0.121 修正：1.0.120 在「url 一变」就撤防，撤在了首帧之前，等于没盖住；
  // 现在改用「见过 loading 且已结束」判据（与 homeHold 同一套），并对已缓存
  // 的瞬时提交补一段首帧宽限。
  @State private navCover: boolean = false;
  private navCoverTimer: number = -1;
  // 起防那一刻的 url：只有 url 离开了它，才算新页面已切换过来（主页键从某个
  // 网页跳自定义主页时，起防瞬间 url 本来就不是 newtab，必须靠这个判据）。
  private navCoverFromUrl: string = '';
  // 要去的那个网址：url 直接等于它也算到了（原地按主页键重载时 url 不变，
  // 只靠「离开 fromUrl」会一直挂到兜底，白盖 1.6s）。
  private navCoverTargetUrl: string = '';
  // 1.0.121：navCover 期间是否见过 loading（= 目标页确实在加载，等它结束才
  // 算画出来）。与 homeHoldSawLoading 同一套判据。
  private navCoverSawLoading: boolean = false;
  // 1.0.121：首帧宽限定器——url 已切到目标却没报过 loading 时，等一小会儿
  // 让渲染器上帧再撤防（见 onBrowserState 的 navCover 分支）。
  private navCoverGraceTimer: number = -1;
  // 兜底续命次数（仍在加载时不撤防，见 armNavCover 注释）。
  private navCoverExtensions: number = 0;
  // 1.0.124：主页键（自定义网址主页）导航落地后主动收一次输入法。
  // 很多站点的搜索框带 autofocus（cn.bing.com 的 sb_form_q 就是
  // `type="search" ... autofocus`），页面一提交就自己抢焦点、把键盘顶起来
  // —— 用户只是按了个主页键，却被塞了一个键盘。这是网页自身行为，外壳挡
  // 不住它聚焦，只能在导航落地后把键盘收回去。
  // 时机复用 navCover 的落地判据（首帧宽限结束 = 新页真画出来了），不另起
  // 一套定时器，免得两处判据漂移。
  private navCoverHideIme: boolean = false;
  private imeHideTimers: number[] = [];
  // 1.0.108：回主页后补发「控件全展开」的延时定时器（见 restoreTopControlsForHome）。
  private homeControlsTimer: number = -1;
  // 引擎原生新标签页落地的**标题**（中文包是「新建标签页」）。导航失败时引擎
  // 画面上停着它、而 state.url 报的是失败的待定地址，只能靠标题认人
  // （见 isNewTabPage）。
  private newTabTitleSeen: string = '';
  @StorageLink('auraBrowserCommandText') browserCommandText: string = '';
  @StorageLink('auraBrowserCommandRevision') browserCommandRevision: number = 0;
  @State private auxiliaryWindows: AuxiliaryWindowView[] = [];
  @State private screenSizeVp: ScreenSizeVp = { width: 0, height: 0 };
  @State private activeAuxiliaryWidget: number = 0;
  @State private auxiliaryDismissWidget: number = 0;
  @State private auxiliaryDismissRevision: number = 0;
  private readonly currentTabCastSession: CurrentTabCastSession = new CurrentTabCastSession();
  private readonly knockShareSession: HuaweiKnockShareSession = new HuaweiKnockShareSession();
  private launchingPwaWidgets: number[] = [];
  // One-shot: the tabs saved on the way into incognito come back once.
  private savedTabsChecked: boolean = false;

  aboutToAppear(): void {
    this.startKnockShare();
    this.useSystemDownloadDirectory();
    this.readCrashReport();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context) {
      // 同步读：首帧就把徽标设成上次退出时的标签数，恢复会话期间不再跳动。
      this.savedTabCountContext = context;
      const tabCountSeed: number = ShellUiPrefs.loadLastTabCountSync(context);
      this.tabBadgeHold = tabCountSeed;
      this.lastSavedTabCount = tabCountSeed;
      ShellUiPrefs.loadHideStatusBar(context).then((value: boolean): void => {
        AppStorage.setOrCreate('auraHideStatusBarOnScroll', value);
      });
      ShellUiPrefs.loadHideTopBar(context).then((value: boolean): void => {
        AppStorage.setOrCreate('auraHideTopBarOnScroll', value);
      });
      ShellUiPrefs.loadHideDock(context).then((value: boolean): void => {
        AppStorage.setOrCreate('auraHideDockOnScroll', value);
      });
      ShellUiPrefs.loadExternalAppLinks(context).then((value: boolean): void => {
        AppStorage.setOrCreate('auraExternalAppLinks', value);
      });
      ShellUiPrefs.loadHomeStyle(context).then((value: string): void => {
        AppStorage.setOrCreate('auraHomeStyle', value);
      });
      ShellUiPrefs.loadDockPosition(context).then((value: string): void => {
        AppStorage.setOrCreate('auraDockPosition', value);
      });
      // 1.0.111「网址主页」：自定义主页网址（空 = 内置新标签页）。
      ShellUiPrefs.loadHomeUrl(context).then((value: string): void => {
        AppStorage.setOrCreate('auraHomeUrl', value);
      });
      // 1.0.119「启动页」：冷启动默认打开网址主页还是内置启动页。
      ShellUiPrefs.loadStartupPage(context).then((value: string): void => {
        AppStorage.setOrCreate('auraStartupPage', value);
      });
      // 1.0.120「自定义网址」：多组网址列表（设置面板显示条数/勾选项用）。
      ShellUiPrefs.loadHomeUrls(context).then((list: string[]): void => {
        AppStorage.setOrCreate('auraHomeUrls', ShellUiPrefs.joinUrlList(list));
        if (AppStorage.get('auraHomeUrl') === '' && list.length > 0) {
          AppStorage.setOrCreate('auraHomeUrl', list[0]);
        }
      });
      // 1.0.190「桌面版网站」站点名单与全局 UA 默认：启动期灌入 AppStorage，
      // 供 WebWindow 在导航前推导桌面 UA、设置面板展示/管理。
      ShellUiPrefs.loadDesktopSites(context).then((list: string[]): void => {
        AppStorage.setOrCreate('auraDesktopSites', ShellUiPrefs.joinUrlList(list));
      });
      // 单站「回到移动版」例外名单：与桌面站名单同路持久化，启动期灌进 AppStorage，
      // 供 WebWindow 导航前推导 UA、菜单切换时增删。
      ShellUiPrefs.loadMobileSites(context).then((list: string[]): void => {
        AppStorage.setOrCreate('auraMobileSites', ShellUiPrefs.joinUrlList(list));
      });
      ShellUiPrefs.loadUaDefault(context).then((value: string): void => {
        AppStorage.setOrCreate('auraUaDefault', value);
      });
    }
    // 1.0.121：冷启动预热（见 navCover 注释）。
    this.armNavCover(this.startUrl ?? '');
  }

  // 1.0.121：要跳去某个真网址（冷启动的网址主页 / 主页键的自定义主页）→ 起防，
  // 铺一层同色底顶住，等目标页首帧提交再淡出。
  private armNavCover(target: string): void {
    if (target.length === 0 || isNewTabUrl(target)) {
      this.navCover = false;
      return;
    }
    this.navCover = true;
    this.navCoverSawLoading = false;
    this.navCoverExtensions = 0;
    this.navCoverHideIme = false;
    // 记下起防时的 url：撤防判据是「url 离开了它」，而不是「url 不是 newtab」
    // —— 从网页按主页键时，起防那一刻 url 本来就不是 newtab，用后者会立刻撤防。
    this.navCoverFromUrl = this.browserState.url ?? '';
    this.navCoverTargetUrl = target;
    this.armNavCoverTimer(1600);
  }

  private armNavCoverTimer(ms: number): void {
    if (this.navCoverTimer >= 0) {
      clearTimeout(this.navCoverTimer);
    }
    this.navCoverTimer = setTimeout((): void => {
      this.navCoverTimer = -1;
      if (!this.navCover) {
        return;
      }
      // 仍在加载就续命：github 这类连不上的站点要 20s+ 才 commit，固定撤防会把
      // 引擎底板露出好几秒。封顶 8 次（≈14s）防引擎卡死时永远盖着。
      if (this.browserState.loading && this.navCoverExtensions < 8) {
        this.navCoverExtensions += 1;
        this.armNavCoverTimer(1600);
        return;
      }
      this.releaseNavCover();
    }, ms);
  }

  private releaseNavCover(): void {
    if (!this.navCover) {
      return;
    }
    this.navCover = false;
    this.navCoverSawLoading = false;
    if (this.navCoverTimer >= 0) {
      clearTimeout(this.navCoverTimer);
      this.navCoverTimer = -1;
    }
    if (this.navCoverGraceTimer >= 0) {
      clearTimeout(this.navCoverGraceTimer);
      this.navCoverGraceTimer = -1;
    }
    // 1.0.124：主页键来的这一趟，落地即收键盘（见 navCoverHideIme 注释）。
    if (this.navCoverHideIme) {
      this.navCoverHideIme = false;
      this.hideImeAfterHomeNav();
    }
  }

  // 1.0.124：收起输入法。主页键跳去自定义主页时，目标页的搜索框可能带
  // autofocus（cn.bing.com 就是），页面一落地就把键盘顶起来。这里在落地后
  // 连收几次，把"页面自己抢焦点"抬起的键盘按回去。
  // 分几拍是必要的：autofocus 的触发点在不同站点上落得或早或晚（有的在
  // 首帧前、有的等脚本跑完），单次收不住。
  // 硬边界：一旦用户自己进了地址栏编辑态（主动要输入），立刻停手 —— 不能
  // 跟用户抢键盘。
  private hideImeAfterHomeNav(): void {
    [0, 180, 420].forEach((delay: number): void => {
      this.imeHideTimers.push(setTimeout((): void => {
        if (this.addressEditing) {
          this.clearImeHideTimers();
          return;
        }
        try {
          inputMethod.getController().hideTextInput().catch((): void => {});
        } catch (error) {
        }
      }, delay));
    });
  }

  private clearImeHideTimers(): void {
    this.imeHideTimers.forEach((timer: number): void => clearTimeout(timer));
    this.imeHideTimers = [];
  }

  // 首帧宽限：判定「已经到了」之后不立刻撤防，再捂一小会儿让渲染器把真实首帧
  // 画出来。撤在首帧之前露出的就是引擎底板（#3A3A3A）= 用户看到的「闪黑」。
  // 幂等：已在宽限中就不重复起；期间 loading 若又起来，撤防会走上面的
  // sawLoading 分支重新计时。
  private armNavCoverGrace(): void {
    if (this.navCoverGraceTimer >= 0 || !this.navCover) {
      return;
    }
    this.navCoverGraceTimer = setTimeout((): void => {
      this.navCoverGraceTimer = -1;
      this.releaseNavCover();
    }, 260);
  }

  private onControlsRatioMoved(): void {
    this.updateStatusBarForScroll(this.scrolledRatio);
    this.syncDockInsetForControlsMove();
    // 引擎开始产比例 = 页面真的在滚 → 把 dock 交还引擎驱动，否则触摸收起的
    // dock 会在页面恢复滚动后卡在收起位（见 onSwipeControlsTouch）。
    if (this.swipeDockTaken && !this.swipeDockDriving) {
      this.releaseSwipeDock();
    }
  }

  // 切主题后的一次性重载：多数站点只在新页面加载时才读配色（必应、百度实测
  // 都要刷一次才跟），而引擎要在新配置到达后才知道换色 —— 所以不能切完就
  // reload，要等"携带新配色的配置真正下发"这一刻（路由 revision 翻新）。
  // 这条 revision 也会被折叠/旋转/窗口变化顶起来，靠 pending 标志只认切主题
  // 那一次；标志挂空了就什么都不做。兜底在 SettingsPanel（配置没到则定时补发）。
  private onRoutingRevisionForThemeReload(): void {
    if (!this.themeReloadPending) {
      return;
    }
    AppStorage.setOrCreate('auraThemeReloadPending', false);
    this.executeBrowserCommand({ command: 'reload' });
  }

  // 主页风格变化：Chrome 风格无独立顶栏、dock 常驻，需重发浏览器控件 inset。
  private onHomeStyleChanged(): void {
    this.sendBrowserControls();
    this.applyDockViewportInset();
  }

  // dock 位置（顶/底）变化：同样重发 inset。
  private onDockPositionChanged(): void {
    this.sendBrowserControls();
    this.applyDockViewportInset();
  }

  private onHideStatusBarPrefChanged(): void {
    if (!this.hideStatusBarOnScroll) {
      this.applyStatusBarHidden(false);
      this.statusBarHiddenByScroll = false;
    } else {
      this.updateStatusBarForScroll(this.scrolledRatio);
    }
    // 1.0.104（用户反馈「这个开关有时候不起作用」）：该开关同时决定
    // sendBrowserControls 下发的几何（minTop 分流：顶置/底置的收起终点是
    // 物理顶还是状态栏底），原先只在「滚动隐藏地址栏」变化时重发 —— 单独拨
    // 这个开关时引擎几何要等下一次别的重发（换风格/换 dock 位置/重启）才跟上，
    // 表现为时灵时不灵、甚至在切 dock 位置时突然生效、垫底整条消失。改为一拨
    // 即重发。
    this.sendBrowserControls();
    // 视口底部内距跟着重算（底置 dock 的底距、以及页尾死角都与收起终点相关，
    // 直接重算重发，不走带滞回的 syncDockInsetForControlsMove）。
    this.applyDockViewportInset();
  }

  // “滚动时隐藏地址栏”开关变化：重发浏览器控件高度（minTop = 全高即常显），
  // 并立即把顶栏动画展开/交还给滚动。
  private onHideTopBarPrefChanged(): void {
    this.sendBrowserControls();
    // 切档前先把 dock 交还引擎，避免触摸值压着比例（见 releaseSwipeDock）。
    if (this.swipeDockTaken) {
      this.releaseSwipeDock();
    }
    if (!this.hideTopBarOnScroll) {
      // 刚切入「地址栏常驻」：dock 的触摸驱动从当前可见度续上，避免跳变。
      const seeded: number = Math.min(Math.max(this.scrolledRatio, 0), 1);
      this.touchDockHidden = (1 - seeded) * Math.max(1,
        dockCoveredHeightVp(Number(AppStorage.get('auraBottomSafeVp') ?? 0)));
      this.setTouchDockRatio(seeded);
    }
    // 必须**直接重发**，不能只交给 syncDockInsetForControlsMove()：那条路只在
    // 「完全收起」标志翻转时才发，而 Chrome 底置档的 computeTopBarHiddenForInset()
    // 恒返回 false（见上），标志永远不翻转 —— 于是这个开关改了、applyDockViewportInset
    // 里读它的分支（底置 dockCover、顶置 topBarPushVp）却全按旧值算，页面内距不更新。
    // 用户实测：Chrome 底置 + 地址栏固定（本开关关着）时页面没抬高，就是这条。
    this.topBarHiddenForInset = this.computeTopBarHiddenForInset();
    this.applyDockViewportInset();
  }

  // 把顶栏的 browser controls（高度 + 收起许可）发给引擎：启动、设置开关
  // 切换、启动后的兜底重发共用这一份。
  private sendBrowserControls(): void {
    if (this.pageFullscreen) {
      // 网页全屏：控件区整体让位 —— top/minTop/bottom 全 0 且直接切 hidden，
      // 页面铺满整屏（此前不发这条，状态栏那一条始终占着，视频只能缩着放）。
      this.executeBrowserCommand({
        command: 'setBrowserControls',
        top: 0,
        minTop: 0,
        bottom: 0
      });
      this.executeBrowserCommand({
        command: 'setBrowserControlsState',
        state: 'hidden',
        animate: false
      });
      return;
    }
    const topSafe = Number(AppStorage.get('auraTopSafeVp') ?? 0);
    if (this.homeStyle === 'chrome') {
      // 1.0.99：顶置回传统通栏几何（用户三图定案，看得是状态栏/网页/地址栏相对
      // 位置）：不滚动=状态栏→通宽地址栏→网页（网页从条带下缘开始）；滚动=地址栏
      // 整条消失、网页顶到状态栏。即简约 TopAddressBar 同款引擎几何——
      //  · top 预留「48+topSafe」，网页顶边从条带下缘开始；
      //  · 开「滚动隐藏地址栏」时 minTop=0，收起后网页同步顶到状态栏，条带整条
      //    离屏无残留（引擎原产 controlsRatio 驱动，跟手）；
      //  · 1.0.98 的 top=0「纯外壳悬浮」浮胶囊形态被真机反馈否决（「怎么把悬浮
      //    胶囊地址栏还给我改了」），回退；浮胶囊只留底置（1.0.93 定案）。
      // 底置保持 1.0.98：top=0/bottom=0 网页铺满物理屏幕，dock 悬浮，滚动隐藏
      // 走触摸驱动（引擎底置无 ratio，onChromeBottomDockTouch）。
      if (this.dockPosition === 'top') {
        const top = CHROME_DOCK_EXTENT_VP + topSafe;
        const collapsing: boolean = this.hideTopBarOnScroll;
        // 1.0.101：同简约分支——「上滑时隐藏状态栏」关着时收起下限=topSafe，
        // 收起后网页停在状态栏底（那一条由外壳常驻垫底显示页面底色）。
        this.executeBrowserCommand({
          command: 'setBrowserControls',
          top: top,
          // 1.0.128：与简约分支同式还原收起下限——「上滑时隐藏状态栏」关着 → topSafe
          // （收起后网页停在状态栏底，那一条由外壳常驻垫底显示页面底色）；开着 → 0
          // （沉浸、网页铺满物理顶）。1.0.117 压成 0 是为绕「顶置收起时底部固定条被切」，
          // 那条裁切真因是引擎 shrink=true 扣了视口，已由 shrink=false 修掉（视口恒满高）。
          minTop: collapsing ? (this.hideStatusBarOnScroll ? 0 : topSafe) : top,
          bottom: 0
        });
        this.executeBrowserCommand({
          command: 'setBrowserControlsState',
          state: collapsing ? 'both' : 'shown',
          animate: true
        });
      } else {
        // 1.0.102：底置也留状态栏垫底——网页顶边停在 topSafe（外壳常驻垫底的
        // 下边）。1.0.98 的 top=0「网页铺满物理顶、状态栏区即网页」被真机反馈
        // 否决（「Chrome风格地址栏在下的时候状态栏没有垫底层」）。
        // 1.0.104（用户反馈「上滑时隐藏状态栏对地址栏在下有时不起作用 / 从上切到
        // 下垫底层会消失」）：1.0.103 写成「开着该开关时 top=minTop=0」——比例被
        // 锁死在 1，引擎根本不产 ratio：状态栏图标永远不隐（updateStatusBarForScroll
        // 只在 ratio≤0.1 时动手）、静息态网页也永远铺到物理顶（垫底自然没了），
        // 而偏偏这个几何又依赖别的事件重发，才有时灵时不灵。
        // 现在改成与顶置同一套：top **恒为 topSafe**（静息=网页停在状态栏底、
        // 垫底照旧），minTop=0 允许引擎按滚动收起——上滑收起完成时网页铺满物理
        // 屏幕、状态栏图标一起隐（底置没有顶栏可让，所以不挂 hideTopBarOnScroll），
        // 回到页顶再展开。关着该开关时维持常驻停靠（minTop=topSafe，比例锁 1）。
        const bottomCollapsing: boolean = this.hideStatusBarOnScroll;
        this.executeBrowserCommand({
          command: 'setBrowserControls',
          top: topSafe,
          minTop: bottomCollapsing ? 0 : topSafe,
          bottom: 0
        });
        this.executeBrowserCommand({
          command: 'setBrowserControlsState',
          state: bottomCollapsing ? 'both' : 'shown',
          animate: true
        });
      }
      return;
    }
    // 同样不因状态栏显隐改变 top：视口高度恒定，状态栏显隐不再牵动页面位移。
    // 1.0.101：收起下限按「上滑时隐藏状态栏」分流（真机反馈：开「滚动隐藏地址
    // 栏」后上滑，网页顶到物理顶、搜索栏与状态栏图标重叠）：
    //  · 隐藏状态栏=ON → minTop=0：收起后网页贴物理顶（沉浸）——用户明确此
    //    开关打开时才用这种方式；
    //  · 隐藏状态栏=OFF（默认）→ minTop=topSafe：收起后网页顶边停在状态栏底
    //    （引擎 ratio 下限=minTop/top，offset=top*ratio 在收起终点=topSafe）；
    //    状态栏那一条由外壳常驻垫底显示页面底色（MobileBrowserOverlay.build）。
    const top = TOP_BAR_EXTENT_VP + topSafe;
    const collapsing: boolean = this.hideTopBarOnScroll;
    // 1.0.128（引擎改 shrinkRendererSize=false 后的还原）：1.0.117 把收起下限从 topSafe
    // 压成 0 是为了绕「底部固定条被切」——那条裁切的真因是引擎 shrink=true 时
    // `renderer 视口高 = H − offset`（1.0.112 注释：控件高度在渲染前就从 renderer 尺寸里
    // 扣掉、控件滑走才长回）。引擎恒不 shrink 后视口**恒为满高**，底部那一截不再被扣，
    // 于是下限可以收回引擎本意值：
    //  · 「上滑时隐藏状态栏」关着（默认）→ minTop=topSafe：收起终点 offset=topSafe，
    //    网页顶边停在状态栏底（引擎 bridge 的收起判据下限本来就是 topSafe/(条高+topSafe)，
    //    见 computeTopBarHiddenForInset 与 MBO.topBarRatioFloor），那一条由外壳常驻垫底显示页面底色；
    //  · 开着 → minTop=0：网页铺满物理顶（沉浸），状态栏图标随之隐（updateStatusBarForScroll）。
    // 常显档仍需 minTop=top 才锁得住（1.0.116 教训不变）。
    // ⚠️ 本值必须与 MBO.topBarRatioFloor() 成对：改一处不同步另一处 → 条带提前隐入/垫层错位。
    const immersive: boolean = this.hideStatusBarOnScroll;
    const minTop: number = collapsing ? (immersive ? 0 : topSafe) : top;
    this.executeBrowserCommand({
      command: 'setBrowserControls',
      top: top,
      minTop: minTop,
      bottom: 0
    });
    this.executeBrowserCommand({
      command: 'setBrowserControlsState',
      state: this.hideTopBarOnScroll ? 'both' : 'shown',
      animate: true
    });
  }

  // 进入主页时把顶栏强制展开。
  // 根因（用户实测「偶尔通过后退回到主页时，主页不显示工具栏」）：从网页后退
  // 回 chrome://newtab 时，引擎的 browser controls 可能仍停在收起态
  // （ratio 0）；而新标签页没有可滚动内容，引擎不会自己把它放回来 —— 顶栏与
  // dock 就一直停在收起位置。这里在 url 落到新标签页的那一帧显式要求 shown，
  // 并把外壳的 ratio 复位（顶栏位移 + 状态栏恢复都挂在它上面）。
  private restoreTopControlsForHome(): void {
    this.executeBrowserCommand({
      command: 'setBrowserControlsState',
      state: 'shown',
      animate: true
    });
    this.lastControlsRatio = 1;
    AppStorage.setOrCreate('auraBrowserControlsRatio', 1);
    // 1.0.98：chrome 风格的 dock 位移挂触摸键，主页回归一并复位，避免上次在
    // 网页里上滑隐藏后回到主页 dock 不回来。
    AppStorage.setOrCreate('auraChromeBottomRatio', 1);
    // 1.0.108（真机录屏逐帧实测）：导航途中引擎还会吐一个"半收起"的中间比例，
    // 把上面这发 shown 盖掉——顶置条带上跳约 45vp 后卡住不回位（用户报「点主页
    // 会往上跳」）。260ms 后补发一发，把引擎的控件 offset 真正拨回全展开；
    // 主页无滚动、画面被 HomeSurface 盖住，重发不会产生可见的页面瞬移。
    if (this.homeControlsTimer !== -1) {
      clearTimeout(this.homeControlsTimer);
    }
    this.homeControlsTimer = setTimeout((): void => {
      this.homeControlsTimer = -1;
      this.executeBrowserCommand({
        command: 'setBrowserControlsState',
        state: 'shown',
        animate: true
      });
      this.lastControlsRatio = 1;
      AppStorage.setOrCreate('auraBrowserControlsRatio', 1);
      AppStorage.setOrCreate('auraChromeBottomRatio', 1);
    }, 260);
  }

  // “滚动时隐藏底部栏”开关变化：dock 常驻时把它永久盖住的高度报给引擎，
  // 页面末尾才能滚到它上方；随滚动收起时还原为 0。
  private onHideDockPrefChanged(): void {
    // 关掉「滚动时隐藏底部栏」后 dock 常驻，触摸值不再有意义，先交还引擎。
    if (!this.hideDockOnScroll && this.swipeDockTaken) {
      this.releaseSwipeDock();
    }
    this.applyDockViewportInset();
  }

  // 键盘避让高度变化：弹起/收起都要重发底部内距（弹起换成键盘高，收起回到 dock）。
  private onKeyboardVpChanged(): void {
    this.applyDockViewportInset();
  }

  // 底部视口内距。四条几何：
  //  · dock 常驻（不随滚动收起）→ 留 dockCoveredHeightVp（dock 高度 + 安全区），
  //    否则页面最后一行永远被 dock 盖住；
  //  · dock 随滚动收起 → **0（网页铺满物理底边）**。1.0.97 改：原先这里留
  //    auraBottomSafeVp，网页视口下方那一条露出的是引擎 surface 的不透明底板
  //    （不是网页延伸），与页面形成一条可见色带（用户两次反馈「最下端小白条
  //    位置有一条不透明」）。铺满后系统手势条浮在网页上——这是既定取舍：
  //    1.0.86「必应页脚最后一行被手势条压住」的问题由用户拍板选「铺满去带」。
  //  · Chrome 顶置 / 简约：**补常量 `topSafe`**（1.0.131；仅「地址栏可随滚动收起」
  //    且非沉浸档）。引擎侧真机制：命令 setViewportInsets 只做
  //    `view->SetInsets(TLBR(0,0,bottom,0))`；而 minTop（patch 里
  //    GetTopControlsMinHeight → GetAuraShellTopControlsMinHeight）会让 renderer 视口
  //    底部恒少一截 → 页面底部内容够不到 / 下方露引擎底板 #383838（bing 实测 139px）。
  //    把同量补回即可。
  //    ⚠️ 1.0.130 试过「按 (48+topSafe)×ratio 连续补」，实测失败：收起时 ratio→0 令补偿
  //    归零（收起态退化），且每帧 resize → 跳动 + 卡顿。**补偿必须是常量，不能跟 ratio。**
  //    1.0.112 撤销补 topSafe 的原因已失效：当时引擎 shrinkRendererSize=true，控件高度
  //    由引擎自己从 renderer 尺寸里扣，外壳再补＝重复扣（贴底元素上移、下方露底板）。
  private lastTopPushSent: number = -1;

  // 底部缺口补偿（vp）= **常量**。1.0.130 曾按「顶栏高 × ratio」连续补，实测失败：
  // 收起时 ratio→0 → 补偿归零（收起态反而退化回裁切），且每帧 resize renderer →
  // 页面跳动 + 滚动发卡、知乎收起态还多出一条空条（用户 1.0.130 实测四条）。
  // 故回退为常量：仅「地址栏可随滚动收起」且非沉浸档补 topSafe。常显档实测底部本来
  // 就正常（关闭隐藏地址栏截图底部无空条）→ 不补，免得补出空条。
  private topBarPushVp(): number {
    const topSafe = Number(AppStorage.get('auraTopSafeVp') ?? 0);
    if (topSafe <= 0) {
      return 0;
    }
    if (this.homeStyle === 'chrome' && this.dockPosition === 'bottom') {
      return this.hideStatusBarOnScroll ? 0 : topSafe;   // 底置沿用 1.0.111 的常量
    }
    // 1.0.133：常显档（「滚动隐藏地址栏」关着）minTop = top = 48+topSafe —— 页面顶部
    // 常年被「状态栏 + 地址栏」占住，视口底部同样少这么多，必须补回来。
    // 用户实测确认的两处：简约「底栏关 + 地址栏也关」要在 dock 占位之外**额外**抬一份；
    // Chrome 顶置「地址栏关」也要抬。
    // （1.0.131 曾把常显档判成 0：当时那张截图是「内容一直延伸到屏幕底」，看着像正常，
    //  其实底部内容已被推出屏幕 —— 与收起档的「裁切」是同一个现象，只是没有空条。）
    // 155 线补充：1.0.3 一度把它改成 topSafe，那是因为当时 155 上游把 renderer 改成
    // 「收缩式」（顶栏显示就收缩），引擎的收缩与这里的 inset 双重抬高 → 底部空一大截。
    // 现在引擎已改回「顶栏存在即不收缩」，与 154/1.0.2 行为等价，这里必须回到 minTop
    // 全量；否则地址栏常显时页面底部少 48vp，最后一行会被 dock 盖住（1.0.3 实测）。
    if (!this.hideTopBarOnScroll) {
      return TOP_BAR_EXTENT_VP + topSafe;
    }
    return this.hideStatusBarOnScroll ? 0 : topSafe;
  }

  // （1.0.131 移除 syncTopPushInset：随 ratio 每帧重发 setViewportInsets 会频繁
  // resize renderer → 页面跳动 + 滚动发卡。补偿改回常量后无需再挂 ratio 事件。）
  private applyDockViewportInset(): void {
    if (this.pageFullscreen) {
      // 网页全屏：底部也不留任何内距，视口就是整屏。
      this.lastTopPushSent = 0;
      this.executeBrowserCommand({
        command: 'setViewportInsets',
        bottom: 0
      });
      return;
    }
    const bottomSafe = Number(AppStorage.get('auraBottomSafeVp') ?? 0);
    const topSafe = Number(AppStorage.get('auraTopSafeVp') ?? 0);
    // 与 ratio 事件同步一次标志（幂等）：设置类变更路径直接调用本函数时，
    // 也把标志刷新到当前模式。
    this.topBarHiddenForInset = this.computeTopBarHiddenForInset();
    let bottom: number;
    if (this.homeStyle === 'chrome') {
      if (this.dockPosition === 'bottom') {
        // 1.0.132「智能抬高」：底置 dock **常驻**时把页面底部抬到 dock 上边，否则
        // 最后一行 / 贴底元素被 dock 盖住。判据：「滚动隐藏地址栏」关着 = dock 常驻
        // → 抬到 dock 上边；开着 = 可收起 → 收起后铺满物理底边（1.0.111 起的行为）。
        // 155 线修的是**重发**：该档 computeTopBarHiddenForInset() 恒返回 false，
        // 旧代码在开关切换时只走 syncDockInsetForControlsMove()（不翻转就不发），
        // 于是这里的判断变了、inset 却还是旧值 —— 用户实测「地址栏在下固定时页面
        // 没抬高」正是这个。现在 onHideTopBarPrefChanged 直接 applyDockViewportInset()。
        const dockCover: number = this.hideTopBarOnScroll ? 0 : dockCoveredHeightVp(bottomSafe);
        bottom = dockCover + (this.hideStatusBarOnScroll ? 0 : topSafe);
      } else {
        // 1.0.130：补偿 = 引擎的「顶栏下推量」，随 ratio 连续（见 topBarPushVp）。
        // 1.0.129 只在「收起完成」补常量 topSafe：收起态对了（用户实测「上滑完整」），
        // 展开态没补 → 「下滑时底部固定条被裁」（1.0.129 用户实测）。
        bottom = this.topBarPushVp();
      }
    } else {
      // 简约/经典：dock 可收起（「滚动时隐藏底部栏」开）→ 页面恒铺满，dock 浮在
      // 内容之上：既没有「页面底端与 dock 之间的空档」，也没有 dock 滑走、inset
      // 归零导致的视口跳变。dock 常驻（关）→ 让出 dock 高度，否则最后一行永久被盖。
      // 备注：错误页不可滚动、dock 恒浮在页内按钮上，实测该档「重新加载」仍可点；
      // 若某些不可滚动页面出现点不到，再按 URL（chrome-error）单独让位。
      const dockAlways: number = dockCoveredHeightVp(bottomSafe);
      bottom = (this.hideDockOnScroll ? 0 : dockAlways) + this.topBarPushVp();
    }
    this.lastTopPushSent = this.topBarPushVp();
    // 键盘弹起：底部内距改用键盘高度（替换式下发，留 dock 的值会盖掉系统 inset）。
    // 避让区报的高度比「页面该留出的高度」略小（实测页内固定底栏最下面一行表情
    // 被键盘上沿切掉一半），补一条 KEYBOARD_INSET_EXTRA_VP 的余量。
    const keyboardVp: number = Number(AppStorage.get('auraKeyboardVp') ?? 0);
    if (keyboardVp > 0) {
      bottom = keyboardVp + KEYBOARD_INSET_EXTRA_VP;
    }
    this.executeBrowserCommand({
      command: 'setViewportInsets',
      bottom: bottom
    });
  }

  // 顶栏显隐态翻转时同步一次底部视口内距（幂等：只在翻转点重发）。
  private syncDockInsetForControlsMove(): void {
    const next: boolean = this.computeTopBarHiddenForInset();
    if (next !== this.topBarHiddenForInset) {
      this.topBarHiddenForInset = next;
      this.applyDockViewportInset();
    }
  }

  // 「顶栏完全收起（贴状态栏底静息）」判定，带滞回防抖。阈值与引擎对齐：
  // 引擎收起完成的判据是 renderer ratio ≤ 下限 + 0.001（见 aura_shell_runtime_bridge
  // 的 OnAuraShellTopControlsShownRatio），下限 = topSafe/(条高+topSafe)。进入取
  // 0.0005（略严于引擎，避免「视口已缩、引擎尚未 hidden」的重复扣除窗口），退出取
  // 0.001（与引擎 not-hidden 翻转点重合，防止展开瞬间多留 topSafe 露底部空档）。
  private computeTopBarHiddenForInset(): boolean {
    if (!this.isMobilePhoneUi()) {
      return false;
    }
    if (this.homeStyle === 'chrome' && this.dockPosition === 'bottom') {
      // 底置不靠这个标志（applyDockViewportInset 已直接给 topSafe）。
      return false;
    }
    if (!this.hideTopBarOnScroll || this.hideStatusBarOnScroll) {
      return false;
    }
    const topSafe = Number(AppStorage.get('auraTopSafeVp') ?? 0);
    const topVp: number = TOP_BAR_EXTENT_VP + topSafe;
    if (topSafe <= 0 || topVp <= 0) {
      return false;
    }
    const floor: number = topSafe / topVp;
    const raw: number = Number.isFinite(this.scrolledRatio) ? this.scrolledRatio : 1;
    const r: number = Math.min(Math.max(raw, 0), 1);
    if (this.topBarHiddenForInset) {
      return r < floor + 0.001;
    }
    return r <= floor + 0.0005;
  }

  // ---- 「地址栏常驻 + 滚动隐藏底栏」组合：触摸驱动的 dock ----
  // 地址栏常驻时引擎把收起比例锁死（minTop = top），dock 拿不到滚动信号；
  // dock 是纯外壳浮层，这里用页面区的触摸位移直接驱动（观察层见 build）。
  private touchDockTracking: boolean = false;
  private touchDockLastY: number = 0;
  private touchDockTravel: number = 1;
  private touchDockHidden: number = 0;
  private touchDockRatioValue: number = 1;

  private touchDockModeActive(): boolean {
    return this.isMobilePhoneUi() && !this.hideTopBarOnScroll &&
      this.hideDockOnScroll && !this.isNewTabPage();
  }

  private onDockObserverTouch(event: TouchEvent): void {
    if (!this.touchDockModeActive()) {
      return;
    }
    if (event.type === TouchType.Down) {
      const touch = event.touches.length > 0 ? event.touches[0] : undefined;
      if (touch === undefined) {
        return;
      }
      this.touchDockTracking = true;
      this.touchDockLastY = touch.y;
      this.touchDockTravel = Math.max(1,
        dockCoveredHeightVp(Number(AppStorage.get('auraBottomSafeVp') ?? 0)));
      this.touchDockHidden = (1 - this.touchDockRatioValue) * this.touchDockTravel;
      return;
    }
    if (!this.touchDockTracking) {
      return;
    }
    if (event.type === TouchType.Move) {
      const touch = event.touches.length > 0 ? event.touches[0] : undefined;
      if (touch === undefined) {
        return;
      }
      if (event.touches.length !== 1) {
        // 多指（缩放等）：不驱动 dock，只把基准跟到手。
        this.touchDockLastY = touch.y;
        return;
      }
      const dy = touch.y - this.touchDockLastY;
      this.touchDockLastY = touch.y;
      const next = Math.min(Math.max(this.touchDockHidden - dy, 0), this.touchDockTravel);
      if (Math.abs(next - this.touchDockHidden) >= 0.5) {
        this.touchDockHidden = next;
        this.setTouchDockRatio(1 - this.touchDockHidden / this.touchDockTravel);
      }
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.touchDockTracking = false;
      const settleHidden = this.touchDockHidden >= this.touchDockTravel * 0.5 ?
        this.touchDockTravel : 0;
      this.touchDockHidden = settleHidden;
      animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, (): void => {
        this.setTouchDockRatio(1 - settleHidden / this.touchDockTravel);
      });
      return;
    }
  }

  private setTouchDockRatio(ratio: number): void {
    this.touchDockRatioValue = ratio;
    AppStorage.setOrCreate('auraTouchDockRatio', ratio);
  }

  // ---- Chrome dock 的滚动隐藏：触摸驱动（1.0.95 建，1.0.98 起顶/底通用）----
  // 1.0.98：chrome 风格引擎 top=0/minTop=0（网页铺满全屏，dock 纯外壳悬浮），
  // 引擎不再产出 controlsRatio，顶/底置都改用这里：页面区触摸位移直接驱动
  // dock 离屏（与 onDockObserverTouch 同一观察层、条件互斥）。写
  // auraChromeBottomRatio → MobileBrowserOverlay 的 chromeDockRatio() →
  // GoogleDockTop/Bottom 的 translate。
  private touchChromeBottomTracking: boolean = false;
  private touchChromeBottomStartY: number = 0;
  private touchChromeBottomTravel: number = 1;
  private touchChromeBottomHidden: number = 0;

  private touchChromeBottomActive(): boolean {
    // 仅底置（1.0.99 收回）：顶置的「滚动隐藏地址栏」由引擎 controlsRatio 驱动
    // （sendBrowserControls chrome 顶置分支恢复 top 预留 + minTop=0）；底置引擎
    // 把 top 锁死不产 ratio，仍走本触摸驱动。
    return this.isMobilePhoneUi() && this.homeStyle === 'chrome' &&
      this.dockPosition === 'bottom' && this.hideTopBarOnScroll &&
      !this.addressEditing && !this.isNewTabPage() &&
      !this.homeHold && !this.homeReturnCover;
  }

  private onChromeBottomDockTouch(event: TouchEvent): void {
    if (!this.touchChromeBottomActive()) {
      this.touchChromeBottomTracking = false;
      return;
    }
    const touch = event.touches.length > 0 ? event.touches[0] : undefined;
    if (touch === undefined) {
      return;
    }
    if (event.type === TouchType.Down) {
      this.touchChromeBottomTracking = true;
      this.touchChromeBottomStartY = touch.y;
      // 底置行程 = 悬浮 dock 全高（48 + 离底留白 + 底部安全区），与
      // GoogleDockBottom 的 translate 行程一致（顶置不走本驱动，见 active 条件）。
      this.touchChromeBottomTravel = Math.max(1,
        CHROME_DOCK_EXTENT_VP + CHROME_DOCK_FLOAT_MARGIN_VP +
        Number(AppStorage.get('auraBottomSafeVp') ?? 0));
      const curRaw = Number(AppStorage.get('auraChromeBottomRatio') ?? 1);
      const cur = Number.isFinite(curRaw) ? Math.min(Math.max(curRaw, 0), 1) : 1;
      this.touchChromeBottomHidden = (1 - cur) * this.touchChromeBottomTravel;
      return;
    }
    if (!this.touchChromeBottomTracking) {
      return;
    }
    if (event.type === TouchType.Move) {
      if (event.touches.length !== 1) {
        // 多指（缩放等）：不驱动，只把基准跟到手。
        this.touchChromeBottomStartY = touch.y;
        return;
      }
      const dy = touch.y - this.touchChromeBottomStartY;
      this.touchChromeBottomStartY = touch.y;
      // 手指上滑(dy<0) → 隐藏底置 dock（hidden 增大）；下滑(dy>0) → 显示（hidden 减小）。
      const next = Math.min(Math.max(this.touchChromeBottomHidden - dy, 0), this.touchChromeBottomTravel);
      if (Math.abs(next - this.touchChromeBottomHidden) >= 0.5) {
        this.touchChromeBottomHidden = next;
        this.setTouchChromeBottomRatio(1 - this.touchChromeBottomHidden / this.touchChromeBottomTravel);
      }
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.touchChromeBottomTracking = false;
      const settleHidden = this.touchChromeBottomHidden >= this.touchChromeBottomTravel * 0.5 ?
        this.touchChromeBottomTravel : 0;
      this.touchChromeBottomHidden = settleHidden;
      animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, (): void => {
        this.setTouchChromeBottomRatio(1 - settleHidden / this.touchChromeBottomTravel);
      });
      return;
    }
  }

  private setTouchChromeBottomRatio(ratio: number): void {
    AppStorage.setOrCreate('auraChromeBottomRatio', ratio);
  }

  // ---- 页面不滚动时的手势兜底：顶栏不放、只收 dock ----
  // 顶栏显隐平时由引擎做：页面滚动 → 引擎动 browser controls，并把
  // browserControlsRatio 报给外壳。有些页面（弹登录/建议浮层、modal 锁了 body
  // 滚动、本身不足一屏）**根本不发生滚动**，引擎拿不到输入 → ratio 恒为 1。
  // 这类页面顶栏保持不动（外壳也不再主动收起：引擎的控件动画会和整屏布局的
  // 重排叠在一起），只把 dock 交给触摸驱动——dock 是浮层，位移不牵动布局。
  // 若顶栏曾由真实滚动收起、之后页面才锁滚，这里负责把它放回来。
  // 与上面 dock 触摸驱动互斥：那边要求「地址栏常驻」，这边要求「允许收起顶栏」。
  private swipeTracking: boolean = false;
  private swipeStartY: number = 0;
  private swipeRatioAtStart: number = 1;
  private swipeEngineDrove: boolean = false;
  private swipeHandled: boolean = false;
  // 「页面不滚动」时只收 dock（地址栏钉住）：dock 是浮层，「滚动时隐藏底部栏」
  // 开着时底部内距恒 0 → 位移不改变任何布局，不会出现「收起 + 整页重排」的顿挫。
  private swipeDockTaken: boolean = false;    // 已把 dock 交给触摸驱动
  private swipeDockDriving: boolean = false;  // 本次手势正在驱动
  private swipeDockStartRatio: number = 1;    // 手势起点时的 dock 比例
  private swipeDockValue: number = 1;         // 当前比例（0=收起，1=全显）
  private swipeDockTravel: number = 1;        // 收起行程（vp）

  private swipeControlsActive(): boolean {
    return this.isMobilePhoneUi() && this.hideTopBarOnScroll && !this.addressEditing &&
      !this.isNewTabPage() && !this.homeHold && !this.homeReturnCover;
  }

  private onSwipeControlsTouch(event: TouchEvent): void {
    // Chrome 底置的滚动隐藏走触摸驱动（onChromeBottomDockTouch），不适用本兜底；
    // Chrome 顶置与简约同款：地址栏由引擎比例驱动，非滚动页面仍需要本兜底。
    if (this.homeStyle === 'chrome' && this.dockPosition !== 'top') {
      return;
    }
    if (!this.swipeControlsActive()) {
      this.swipeTracking = false;
      return;
    }
    const touch = event.touches.length > 0 ? event.touches[0] : undefined;
    if (touch === undefined) {
      return;
    }
    if (event.type === TouchType.Down) {
      this.swipeTracking = true;
      this.swipeStartY = touch.y;
      this.swipeRatioAtStart = this.scrolledRatio;
      this.swipeEngineDrove = false;
      this.swipeHandled = false;
      this.swipeDockDriving = false;
      return;
    }
    if (!this.swipeTracking) {
      return;
    }
    if (event.type === TouchType.Move) {
      if (event.touches.length !== 1) {
        // 多指（缩放等）：不驱动，只把起点跟到手。
        this.swipeStartY = touch.y;
        this.swipeRatioAtStart = this.scrolledRatio;
        this.swipeHandled = false;
        return;
      }
      // 引擎自己在动 → 页面确实在滚，交还控制权，本次手势不再插手。
      if (Math.abs(this.scrolledRatio - this.swipeRatioAtStart) > CONTROLS_RATIO_EPS) {
        this.swipeEngineDrove = true;
        // 前半段可能已按「只收 dock」驱动过（引擎比例晚一两帧才到），马上交还，
        // 否则触摸值会压着引擎比例、dock 卡在中间位置。
        if (this.swipeDockTaken) {
          this.swipeDockDriving = false;
          this.releaseSwipeDock();
        }
        return;
      }
      if (this.swipeHandled || this.swipeEngineDrove) {
        return;
      }
      const up: number = this.swipeStartY - touch.y; // 正数 = 手指上滑
      // 归一化进度（0=全显，1=全隐）判定，不用引擎原始 ratio：minTop=topSafe 时
      // 收起终点的 ratio 是 topSafe/(48+topSafe)（≈0.38）而非 0，若按
      // 「ratio<=0.1 才展开」判定，内层滚动/不足一屏的页面一旦收起就再也放不出来。
      // 分母与 MobileBrowserOverlay 的顶栏 floor 保持一致。
      const topSafe: number = Number(AppStorage.get('auraTopSafeVp') ?? 0);
      const floor: number =
        (!this.hideTopBarOnScroll || this.hideStatusBarOnScroll || topSafe <= 0)
          ? 0 : topSafe / (TOP_BAR_EXTENT_VP + topSafe);
      const rawRatio: number =
        Number.isFinite(this.scrolledRatio) ? this.scrolledRatio : 1;
      const clamped: number = Math.min(Math.max(rawRatio, 0), 1);
      const span: number = 1 - floor;
      const hideProgress: number = span > 0
        ? Math.min(Math.max((1 - clamped) / span, 0), 1)
        : (1 - clamped);
      // 页面不滚动时**地址栏钉住、只收 dock**：这类页面引擎拿不到根滚动、不产
      // 比例，若由外壳 setBrowserControlsState 收放地址栏，引擎动画会和整屏布局
      // 的重排叠在一起、途中顿一下。dock 是浮层（底部内距恒 0），只改 translate，
      // 零重排——上滑收、下滑放都是平滑的，地址栏始终不动。
      if (this.swipeDockOnlyOn()) {
        // 已开始驱动就继续跟手（手指回退时 dock 也要跟着回），未开始才看阈值。
        if (this.swipeDockDriving || up >= SWIPE_TRIGGER_VP) {
          this.driveSwipeDock(up - SWIPE_TRIGGER_VP, hideProgress);
          return;
        }
        if (up <= -SWIPE_TRIGGER_VP && this.swipeDockTaken) {
          this.driveSwipeDock(up + SWIPE_TRIGGER_VP, hideProgress);
          return;
        }
      }
      // 顶栏已被真实滚动收起、之后页面又不再滚动：下滑把它放回来，否则收不回来。
      if (up <= -SWIPE_TRIGGER_VP && hideProgress >= 0.9) {
        this.swipeHandled = true;
        this.executeBrowserCommand({
          command: 'setBrowserControlsState', state: 'shown', animate: true });
      }
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.swipeTracking = false;
      this.settleSwipeDock();
    }
  }

  // 「页面不滚动」时只收 dock 的模式：简约/经典底置（Chrome 底置另有触摸驱动
  // onChromeBottomDockTouch，Chrome 顶置由引擎比例驱动，都不走这里）。
  private swipeDockOnlyOn(): boolean {
    return this.isMobilePhoneUi() && this.hideDockOnScroll &&
      this.homeStyle !== 'chrome' && !this.isNewTabPage() &&
      !this.addressEditing && !this.homeHold && !this.homeReturnCover;
  }

  // 只改 dock 的收起比例（0=收起，1=全显）。地址栏、视口内距、页面布局全不动。
  private driveSwipeDock(travelled: number, hideProgress: number): void {
    if (!this.swipeDockDriving) {
      this.swipeDockDriving = true;
      this.swipeDockTravel = Math.max(1,
        dockCoveredHeightVp(Number(AppStorage.get('auraBottomSafeVp') ?? 0)));
      // 起点取 dock 的实际位置：已由触摸收起时从当前值继续，否则由顶栏显隐进度
      // 反推（顶栏全显 → 1，全隐 → 0）。
      this.swipeDockStartRatio = this.swipeDockTaken ?
        this.swipeDockValue : Math.min(Math.max(1 - hideProgress, 0), 1);
      if (!this.swipeDockTaken) {
        this.swipeDockTaken = true;
        AppStorage.setOrCreate('auraSwipeDockRatioOn', true);
      }
    }
    const ratio: number = Math.min(Math.max(
      this.swipeDockStartRatio - travelled / this.swipeDockTravel, 0), 1);
    this.swipeDockValue = ratio;
    AppStorage.setOrCreate('auraTouchDockRatio', ratio);
  }

  // 松手：过半收到底（离屏），否则放回原位。dock 是浮层，这一步同样不动布局。
  private settleSwipeDock(): void {
    if (!this.swipeDockDriving) {
      return;
    }
    this.swipeDockDriving = false;
    const settle: number = this.swipeDockValue >= 0.5 ? 1 : 0;
    this.swipeDockValue = settle;
    animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, (): void => {
      AppStorage.setOrCreate('auraTouchDockRatio', settle);
    });
  }

  // 把 dock 交还引擎驱动（页面开始滚动 / 换页时），避免触摸值长期压着比例。
  private releaseSwipeDock(): void {
    this.swipeDockTaken = false;
    this.swipeDockDriving = false;
    this.swipeDockValue = 1;
    AppStorage.setOrCreate('auraSwipeDockRatioOn', false);
    AppStorage.setOrCreate('auraTouchDockRatio', 1);
  }

  // Collapsed address bar -> hide the status bar too; scrolling back restores
  // it. **不再**向引擎重发 setBrowserControls：保留高度与状态栏显隐无关
  // （top/minTop 是常量，见 sendBrowserControls），而同值重发同样会让引擎
  // 把顶栏控件重置为"全展开"——页面在状态栏出现的那一帧瞬移整整一条高度
  // （真机录屏实测 ≈91vp，即"出现状态栏的一瞬间跳一个界面"）。状态栏纯为
  // 系统栏图标显隐，不牵动任何布局。
  private updateStatusBarForScroll(ratio: number): void {
    if (!this.hideStatusBarOnScroll || !this.isMobilePhoneUi()) {
      return;
    }
    if (ratio <= 0.1 && !this.statusBarHiddenByScroll) {
      this.statusBarHiddenByScroll = true;
      this.applyStatusBarHidden(true);
    } else if (ratio >= 0.4 && this.statusBarHiddenByScroll) {
      this.statusBarHiddenByScroll = false;
      this.applyStatusBarHidden(false);
    }
  }

  private applyStatusBarHidden(hidden: boolean): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    // 网页全屏期间状态栏归全屏逻辑管，滚动显隐不能把它又打开。
    if (this.pageFullscreen) {
      return;
    }
    window.getLastWindow(context).then((win: window.Window): void => {
      win.setSpecificSystemBarEnabled('status', !hidden);
    }).catch((error: Error) => {
      hilog.warn(0x0000, 'AuraShell', 'Status bar toggle failed: %{public}s', JSON.stringify(error));
    });
  }

  // 网页全屏开关：进 → 藏系统栏（状态栏 + 导航条）、控件高度清零、视口铺满；
  // 出 → 按当前设置把状态栏/控件还回去。
  private setPageFullscreen(on: boolean): void {
    if (this.pageFullscreen === on) {
      return;
    }
    this.pageFullscreen = on;
    AppStorage.setOrCreate('auraPageFullscreen', on);
    this.applyFullscreenSystemBars(on);
    this.sendBrowserControls();
    this.applyDockViewportInset();
  }

  private applyFullscreenSystemBars(on: boolean): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    window.getLastWindow(context).then((win: window.Window): void => {
      try {
        if (on) {
          win.setSpecificSystemBarEnabled('status', false);
          win.setSpecificSystemBarEnabled('navigationIndicator', false);
        } else {
          win.setSpecificSystemBarEnabled('status', !this.statusBarHiddenByScroll);
          win.setSpecificSystemBarEnabled('navigationIndicator', true);
        }
      } catch (error) {
        hilog.warn(0x0000, 'AuraShell', 'Fullscreen system bar toggle failed: %{public}s',
          JSON.stringify(error));
      }
    }).catch((error: Error) => {
      hilog.warn(0x0000, 'AuraShell', 'Fullscreen window lookup failed: %{public}s',
        JSON.stringify(error));
    });
  }

  // 【已移除 sendScrollTopExtent()：保留高度只在"滚动时隐藏地址栏"开关变化
  //   时经 sendBrowserControls() 重发；状态栏显隐不再触发任何引擎指令
  //   （同值重发亦会让引擎把顶栏重置为全展开 → 页面瞬移一条高度，真机实
  //   测即"出现状态栏的一瞬间跳一个界面"）。】
  //
  // 原实现要点存档（如需重发通道，照此补回）：top = TOP_BAR_EXTENT_VP +
  // auraTopSafeVp（常量，页面顶边与条带底边按同一 ratio 缩放、天然对齐；
  // 页面能铺到屏幕顶靠的是 minTop=0，与 top 值无关；dock 不给页面留位）。

  // v8a diagnostic: read / clear / copy the crash file EntryAbility wrote.
  private crashReportPath(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    return context ? `${context.filesDir}/aura-crash.txt` : '';
  }

  private readCrashReport(): void {
    try {
      const path = this.crashReportPath();
      if (path.length === 0) {
        return;
      }
      const text = fs.readTextSync(path);
      this.crashReport = text && text.length > 0 ? text : '';
    } catch (error) {
      // No file: the ordinary first-launch case.
      this.crashReport = '';
    }
  }

  private clearCrashReport(): void {
    try {
      const path = this.crashReportPath();
      if (path.length > 0) {
        fs.unlinkSync(path);
      }
    } catch (error) {
    }
    this.crashReport = '';
  }

  private copyCrashReport(): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.crashReport);
      pasteboard.getSystemPasteboard().setData(data).catch((error: Error): void => {
        console.error('Failed to copy the crash report:', error.message);
      });
    } catch (error) {
      console.error('Failed to copy the crash report');
    }
  }

  // Downloads go to Download/<bundle>, where the Files app shows them. The
  // directory can only be had once this page is up, after Chromium started.
  private downloadNotifier: DownloadNotifier | undefined = undefined;
  // 下载列表接口（downloadList）回包的 item 常不带 filePath，而实时
  // downloadUpdated 事件才带。这里累积 id→filePath，写下载页数据时回填，
  // 使「下载页 → 安装 .crx」能拿到正确路径（下载条用实时事件无需补）。
  private downloadFilePaths: Record<string, string> = {};

  private useSystemDownloadDirectory(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.downloadNotifier = new DownloadNotifier(context);
    ShellDownloadDirectory.prepare(context).then((uri: string): void => {
      if (uri.length > 0) {
        this.executeBrowserCommand({ command: 'setDownloadDirectory', uri: uri });
      }
    });
  }

  onPageShow(): void {
    this.startKnockShare();
  }

  onPageHide(): void {
    this.knockShareSession.stop();
  }

  aboutToDisappear(): void {
    PermissionRequestAdapter.stopObservingLocation();
    this.knockShareSession.stop();
    if (this.navCoverTimer >= 0) {
      clearTimeout(this.navCoverTimer);
      this.navCoverTimer = -1;
    }
    if (this.navCoverGraceTimer >= 0) {
      clearTimeout(this.navCoverGraceTimer);
      this.navCoverGraceTimer = -1;
    }
    this.clearImeHideTimers();
    this.currentTabCastSession.stop().catch((error: Error): void => {
      console.error('Failed to stop current-tab cast session:', error);
    });
  }

  // 无痕回来之后把普通会话的标签放回去。进无痕时存下的那份在这里取用一次，
  // 取完即清（IncognitoSwitch.takeSavedTabs）；无痕会话自己不留这些标签。
  private restoreSavedTabs(): void {
    if (this.savedTabsChecked) {
      return;
    }
    this.savedTabsChecked = true;
    if (this.incognito) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.Context | undefined;
    if (!context) {
      return;
    }
    IncognitoSwitch.takeSavedTabs(context).then((tabs: SavedTab[]): void => {
      if (tabs.length === 0) {
        return;
      }
      for (const tab of tabs) {
        this.executeBrowserCommand({ command: 'newTab', url: tab.url, background: true });
      }
      // The engine starts on a new tab; the first restored one sits at index 1.
      this.executeBrowserCommand({ command: 'activateTab', index: 1 });
    });
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.crashReport.length > 0) {
        this.CrashReportView()
      } else if (!this.onboardingReady) {
        LoadingProgress()
          .width(40)
          .height(40)
          .color($r('app.color.accent_primary'))
          .align(Alignment.Center)
      } else if (!this.onboardingComplete) {
        BrowserOnboarding({
          onComplete: (state: BrowserProfileState): void => {
            this.profileId = state.profileId;
            this.profileKind = state.profileKind;
            this.syncMode = state.syncMode;
            this.onboardingComplete = state.onboardingComplete;
          }
        })
      } else {
        WebWindow({
        url: this.startUrl,
        // Incognito is its own profile directory; the ordinary session keeps
        // whatever profile the onboarding chose.
        profileId: this.incognito ? IncognitoSwitch.profileId(true) : this.profileId,
        startupConfigText: this.startupConfigText,
        routingRevision: this.routingRevision,
        appVisible: this.appVisible,
        themeFontId: this.themeFontId,
        themeFontRevision: this.themeFontRevision,
        browserCommandText: this.browserCommandText,
        browserCommandRevision: this.browserCommandRevision,
        auxiliaryDismissWidget: this.auxiliaryDismissWidget,
        auxiliaryDismissRevision: this.auxiliaryDismissRevision,
        onBrowserState: (state: BrowserStateSnapshot): void => {
          // 1.0.121 修正：1.0.120 在「url 一提交」就撤防，但渲染器此刻还没画出
          // 第一帧 —— 撤防那一下露出的正是引擎底板（#3A3A3A，暗色下观感就是
          // 闪黑）。撤防必须等页面真的画出来，沿用 homeHold 那套成熟判据：
          // ① url 已离开起防时的那个（= 新页面已切换）；② 见过 loading 且已
          // 结束（= 首帧已提交）。没见过 loading 的瞬时/缓存命中，补一段首帧
          // 宽限再撤，别撤在首帧之前。
          if (this.navCover) {
            const nowUrl: string = state.url ?? '';
            if (state.loading) {
              // 目标页正在加载：记住「见过 loading」。必须放在 url 判据**之前**：
              // 待定导航期间引擎可能还报着旧 url（GetVisibleURL 的语义），若把
              // loading 记在 url 变化的分支里就永远记不到，只能等兜底定时器。
              this.navCoverSawLoading = true;
            } else {
              // 到了吗？两种到法：url 切走了，或原地重载直接等于目标。
              // 注意「loading 刚结束」也算到 —— 但**不能**据此立刻撤防：
              // loading=false 只代表提交完成，渲染器未必已上帧，此刻撤防露出的
              // 正是引擎底板（#3A3A3A）= 用户看到的「闪黑」。所以统一走宽限：
              // 到了之后再捂一小会儿，等真实首帧画出来。
              const moved: boolean = nowUrl.length > 0 && nowUrl !== this.navCoverFromUrl;
              const landed: boolean = this.navCoverTargetUrl.length > 0 && nowUrl === this.navCoverTargetUrl;
              if (this.navCoverSawLoading || moved || landed) {
                this.armNavCoverGrace();
              }
            }
          }
          const wasNewTab: boolean = this.isNewTabPage();
          const prevUrl: string = this.browserState.url;
          this.browserState = state;
          // 关掉重复主页标签后，等标签数真的回落再放开徽标：否则会先显示
          // 恢复后的「多一个」数量，再跳回实际数量。
          if (this.badgeWaitForCount >= 0 &&
            state.tabCount === this.badgeWaitForCount) {
            this.badgeWaitForCount = -1;
            this.releaseTabBadge();
          }
          // 徽标冻结只在启动窗口内；窗口结束后把真实标签数同步落盘，
          // 供下一次冷启动的第一帧直接显示。恢复期间不写，免得把中间值存进去。
          if (this.tabBadgeHold < 0 && state.tabCount !== this.lastSavedTabCount) {
            this.lastSavedTabCount = state.tabCount;
            if (this.savedTabCountContext) {
              ShellUiPrefs.saveLastTabCountSync(this.savedTabCountContext, state.tabCount);
            }
          }
          this.maybeRestoreLastSession(state);
          // 会话恢复出来的标签是重新加载的：地址栏已经换成真网址，页面区要等
          // 首帧才有内容，中间露的是引擎底板（黑）。这段用同色底顶住。
          if (this.restoreCoverPending) {
            const restoredUrl: string = state.url ?? '';
            if (restoredUrl.length > 0 && !isNewTabUrl(restoredUrl) &&
              !restoredUrl.startsWith('chrome')) {
              this.restoreCoverPending = false;
              this.armNavCover(restoredUrl);
            }
          }
          // 换页/换标签：触摸收起的 dock 复位（否则新页面会停在收起位）。
          if (this.swipeDockTaken && (state.url ?? '') !== prevUrl) {
            this.releaseSwipeDock();
          }
          // 记下引擎原生新标签页的标题：失败导航后要靠它认出「画面还停在
          // 新标签页」（见 isNewTabPage）。
          if (isNewTabUrl(state.url ?? '')) {
            const seen = (state.title ?? '').trim();
            if (seen.length > 0) {
              this.newTabTitleSeen = seen;
            }
          }
          if (this.isNewTabPage() && !wasNewTab) {
            // 刚落到主页（含「后退回主页」这条路径）：顶栏可能还停在收起态，
            // 引擎不会自己放回来（新标签页没有可滚动内容）—— 见方法注释。
            this.restoreTopControlsForHome();
          }
          if (this.homeReturnCover && this.isNewTabPage()) {
            // 主页已真正落地：撤防（挂载条件回落到 isNewTabPage，不会闪）。
            this.releaseHomeReturnCover();
          }
        if (this.homeHold) {
          if (this.isNewTabPage()) {
            // 命令刚发出、导航尚未启动时的残留 newtab 状态**不能**据此撤防——
            // 否则 url 一翻到目标网址主页层就没了，露出引擎默认新标签页
            // （真机：失败加载时先闪 Chromium 新标签页，错误页出来才结束）。
            // 只有见过 loading 之后再回 newtab，才算"导航已落地"。
            if (this.homeHoldSawLoading) {
              this.releaseHomeHold();
            }
          } else if (state.loading) {
            this.homeHoldSawLoading = true;
          } else if (this.homeHoldSawLoading) {
            this.releaseHomeHold();
          } else if (this.homeHoldQuickTimer === -1) {
            // url 已离开主页、却一次 loading 都没见过：本地页（扩展页
            // chrome-extension://、错误页之类）秒开，中间那帧 loading=true
            // 根本不会出现。此前只有 8s 兜底能撤防 —— 真机表现就是
            // 「点扩展磁贴像没反应，要再点一次」（2026-10-21 录屏）。
            // 250ms 后再确认一次：真网址这期间必然已经 loading=true，不会误撤。
            this.homeHoldQuickTimer = setTimeout((): void => {
              this.homeHoldQuickTimer = -1;
              if (!this.homeHold || this.isNewTabPage()) {
                return;
              }
              if (!this.browserState.loading) {
                this.releaseHomeHold();
                return;
              }
              // 桌面版开着时本地页（扩展选项页等）也可能被拖到秒级才画完：
              // 期间主页全屏捂着、地址栏虽已更新但页面纹丝不动，读起来就是
              // 「点了没反应，要再点一次」（19:40 录屏）。本地页最多再捂
              // 800ms 就让位 —— 一帧过渡底色，好过「没反应」。http(s) 慢站
              // 维持原判据（等 loading 结束 / 8s 兜底续命），避免回归
              // 「失败加载先闪 Chromium 新标签页」（见 holdHomeForPaint 注释）。
              const pendingUrl: string = this.browserState.url ?? '';
              if (pendingUrl.startsWith('chrome-extension://') ||
                pendingUrl.startsWith('chrome://')) {
                this.homeHoldQuickTimer = setTimeout((): void => {
                  this.homeHoldQuickTimer = -1;
                  if (this.homeHold && !this.isNewTabPage()) {
                    this.releaseHomeHold();
                  }
                }, 800);
              }
            }, 250);
          }
        }
          if (!this.systemPermissionReported) {
            this.systemPermissionReported = true;
            this.reportSystemPermissionState();
          }
          if (state.ready) {
            this.configureBrowserControls();
            this.restoreSavedTabs();
            this.syncDesktopSites();
          }
          this.currentTabCastSession.update(state);
          this.knockShareSession.update(state);
        },
        onRuntimeEvent: (event: BrowserRuntimeEvent): void => {
          this.handleRuntimeEvent(event);
        },
        onAuxiliaryWindowState: (state: AuxiliaryWindowState): void => {
          this.handleAuxiliaryWindowState(state);
        }
        })
          .width('100%')
          .height('100%')
        if (this.isMobilePhoneUi() && this.homeSurfaceVisible()) {
          HomeSurface({
            incognito: this.incognito,
            onCommand: (command: BrowserCommandPayload): void => {
              if (command.command === 'navigate' && this.isNewTabPage()) {
                this.holdHomeForPaint();
              }
              this.executeBrowserCommand(command);
            }
          })
            .width('100%')
            .height('100%')
            // 状态栏避让进了 HomeSurface 内部（它自己读 auraTopSafeVp 做
            // 内边距）——这样 surface_primary 背景能铺满状态栏条带，首页
            // 顶部与下边同色；此前外层 padding 让条带露出垫底的引擎原生
            // 新标签页（深色下是一段灰条，用户可从截图辨认）。
        } else if (this.isMobilePhoneUi() && this.navCover) {
          // 1.0.121：导航预热层——盖住引擎清屏到新页首帧之间的那段底板
          //（见 navCover 注释）。
          this.NavCoverView()
        }
        // 触摸观察层：Transparent 全屏节点——自己收得到页面区触摸，又不阻塞
        // 下面的网页（与 bars 包裹容器同一机制）；overlay 在其上先处理，
        // modal / 条带命中时触摸到不了这里。只读，不消费。
        // 两个用途，启用条件互斥（各自方法内部判断）：
        //  · onDockObserverTouch：「地址栏常驻 + 收起 dock」组合，用位移驱动 dock。
        //  · onSwipeControlsTouch：页面不滚动（弹窗锁滚 / 短页面）时，上滑兜底
        //    收放顶栏——引擎拿不到滚动输入，只能外壳补这一刀。
        Column()
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.Transparent)
          .onTouch((event: TouchEvent): void => {
            this.onDockObserverTouch(event);
            this.onSwipeControlsTouch(event);
            this.onChromeBottomDockTouch(event);
          })
        if (this.isMobilePhoneUi()) {
          MobileBrowserOverlay({
            browserState: this.browserState,
            // 恢复会话期间冻结标签计数，避免徽标从 1 逐个涨到实际数量。
            badgeTabCount: this.tabBadgeHold,
            // 引擎其实停在自己的新标签页（失败导航）时告诉顶栏层，让它按主页
            // 处理（不画地址栏、菜单显示"新标签页"、顶部不留条带命中区）。
            engineHomeCover: this.engineHomeCovered(),
            incognito: this.incognito,
            onCommand: (command: BrowserCommandPayload): void => {
              // Back is asked of the page before it is asked of the tab. A
              // <dialog>, a popover, fullscreen or a page with a CloseWatcher
              // of its own expects back to close that rather than leave the
              // page, which is what back does in every other browser. The
              // engine answers backHandled; only a no goes on to the tab.
              if (command.command === 'back') {
                this.executeBrowserCommand({
                  command: 'handleBack', requestId: ++this.backRequestId });
                return;
              }
              if (command.command === 'homeSurface') {
                // 1.0.125：强行回内置主页层，**绕过** 1.0.111「网址主页」拦截。
                // 「自定义主页布局」按钮走这条——它要在内置主页上开布局弹层，
                // 若走 'home' 会被劫持去导航自定义网址（bing），弹层背后不是主页、
                // 调位置条看不到效果。这里直接铺 homeReturnCover 并令引擎回到内置
                // 新标签页，使内置主页层常驻可见（与「无网址主页」时的主页键一致）。
                this.beginHomeReturnCover();
                this.executeBrowserCommand({ command: 'home' });
                return;
              }
              if (command.command === 'home') {
                // 1.0.125：主页键**跟随「启动页」设置**（与冷启动同源），不再只看
                // auraHomeUrl。启动页='homeUrl' 且设了网址主页 → 打开该网址；
                // 否则（启动页='builtin'，或没设网址主页）→ 回内置主页。
                // 这样「主页设置」里的「启动页」开关成为主页行为的唯一开关：
                // 用户把启动页切到「内置启动页」，主页键就不再被锁死在网址上。
                // （1.0.111 旧逻辑只看 auraHomeUrl，导致启动页切回 builtin 后
                //  主页键仍去网址，给人"锁死"的错觉。）
                const startupPage: string = (AppStorage.get('auraStartupPage') as string) ?? 'builtin';
                const customHome: string = (AppStorage.get('auraHomeUrl') as string) ?? '';
                if (startupPage === 'homeUrl' && customHome.length > 0) {
                  // 1.0.121：主页键去的是真实网址（不是 chrome://newtab）。导航
                  // 一发出引擎就把画面清了，而新页要一两帧才画出来 —— 中间露的
                  // 就是引擎底板（#3A3A3A，暗色下观感即「闪黑」；真机反馈）。
                  // 铺一层与外壳同色的 navCover 顶住，等新页首帧提交再淡出
                  //（见 armNavCover）。不用 HomeSurface：那是内置主页界面，
                  // 从网页点主页键时它会闪一整屏主页再跳走，比纯色底更跳。
                  this.armNavCover(customHome);
                  // 1.0.124：目标页可能 autofocus 抢键盘，落地后收一次
                  //（见 navCoverHideIme 注释）。只认主页键这条路径——地址栏
                  // 提交导航是用户自己敲的，不收。
                  this.navCoverHideIme = true;
                  this.executeBrowserCommand({ command: 'navigate', url: customHome });
                  return;
                }
                // 主页键：立刻把主页层铺上，盖住引擎回主页那一瞬的白底
                //（见 homeReturnCover 注释）。
                this.beginHomeReturnCover();
              }
              // 1.0.142：从内置主页（引擎原生新标签页）的地址栏提交一个网址时，
              // 导航未提交前引擎会停在原生新标签页（满屏磁贴、地址栏显示"X 正在加载"），
              // 直到失败页提交才切走 —— 即用户报的"先闪磁贴页再出错误页"。离开主页去真
              // 网址时铺 navCover 同色底顶住，加载中（含失败）一直盖着，目标页/错误页首帧
              // 提交再淡出，与主页键去自定义网址同一套覆盖机制。仅在当前就在主页时补防，
              // 普通网页间跳转不动（保留 Fix F 旧页 ghost 行为）。
              if (command.command === 'navigate') {
                const navUrl: string = command.url ?? '';
                if (navUrl.length > 0 && !isNewTabUrl(navUrl) && this.isNewTabPage()) {
                  this.armNavCover(navUrl);
                }
              }
              this.executeBrowserCommand(command);
            }
          })
        }
        if (this.auxiliaryWindows.length > 0) {
          this.AuxiliaryWindowLayer()
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.browser_canvas'))
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      this.onScreenSizeChanged(Number(newValue.width), Number(newValue.height));
    })
  }

  // v8a diagnostic: the crash report page. Plain components only -- it must
  // render even when nothing else can. Copy hands the text to the clipboard
  // so it can be pasted out; clear removes the record and lets the shell run
  // normally again (a fresh crash writes a fresh record).
  @Builder
  private CrashReportView() {
    Column({ space: 14 }) {
      Text('上次启动发生异常')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text('下面是最近一次异常的信息，复制后发给开发者；清除后即可继续使用。')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
      Scroll() {
        Text(this.crashReport)
          .fontSize(11)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.TopStart)
      .padding(12)
      .borderRadius(8)
      .backgroundColor($r('app.color.surface_secondary'))
      Row({ space: 12 }) {
        Button('复制错误信息')
          .fontSize(15)
          .layoutWeight(1)
          .height(46)
          .onClick((): void => {
            this.copyCrashReport();
          })
        Button('清除并继续')
          .fontSize(15)
          .layoutWeight(1)
          .height(46)
          .onClick((): void => {
            this.clearCrashReport();
          })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .backgroundColor($r('app.color.surface_primary'))
  }

  // Close the topmost modal window on back, the way a phone dismisses a
  // dialog. Chromium's windows carry their own Cancel and Stop buttons, so
  // the shell no longer adds a close button of its own; this is the one
  // system gesture that still means "dismiss".
  onBackPress(): boolean {
    for (let index = this.auxiliaryWindows.length - 1; index >= 0; index--) {
      const view = this.auxiliaryWindows[index];
      if (view.modal) {
        this.requestAuxiliaryWindowDismiss(view.state.widget);
        return true;
      }
    }
    // The browser chrome unwinds first: address editing, the tab menu, a
    // full-screen shell page, then page history. Only when there is nothing
    // of ours left does the gesture fall through to leaving the app.
    const overlayBack = MobileBackRouter.handler;
    if (overlayBack && overlayBack()) {
      return true;
    }
    return false;
  }

  // The 60-second password window dies in the background: the engine watches
  // the lock screen itself, but the shell must report app backgrounding.
  // The watch itself hangs on the appVisible storage link declared above.
  private onAppVisibleChanged(): void {
    if (!this.appVisible) {
      this.executeBrowserCommand({ command: 'passwordAuthReset' });
    }
  }

  private startKnockShare(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    this.knockShareSession.start(context).catch((error: Error): void => {
      console.error(`Failed to start HarmonyOS knock share: ${error.message}`);
    });
  }

  // Each auxiliary window is drawn at its own size, clamped to the screen, and
  // hangs from the top centre. Nothing wraps the XComponent: its box is exactly
  // the size the window reported, because the surface size is fed back to the
  // widget as its bounds and anything added here would shrink it every round.
  //
  // Only a modal window -- the media source picker -- gets a scrim that blocks
  // the page. A non-modal one, such as the "sharing your screen / stop" bar,
  // covers only its own box and the page around it stays usable.
  @Builder
  private AuxiliaryWindowLayer() {
    if (this.auxiliaryWindows.some((view: AuxiliaryWindowView): boolean => view.modal)) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.modal_scrim'))
        .hitTestBehavior(HitTestMode.Block)
    }
    ForEach(this.auxiliaryWindows, (view: AuxiliaryWindowView) => {
      Stack() {
        if (view.state.pictureInPicture === true) {
          PictureInPictureSurface({
            componentId: view.state.componentId,
            widget: view.state.widget
          })
            .width('100%')
            .height('100%')
        } else {
          XComponent({
            id: view.state.componentId,
            type: XComponentType.SURFACE,
            libraryname: 'web_engine'
          })
            .id(view.state.componentId)
            .width('100%')
            .height('100%')
            // A SURFACE XComponent's own background is opaque black by default,
            // and it shows through wherever the buffer is transparent. Popups
            // paint their margin transparent (rounded corners, the arrow, the
            // shadow), so without this each one sat in a black rectangle.
            .backgroundColor(Color.Transparent)
            // A popup anchored to the page -- the autofill list under a field
            // -- is not activatable in Chromium either. Taking focus here moved
            // it off the page's XComponent, which closed the keyboard the user
            // was typing with and could leave it unable to reopen.
            .focusable(view.state.anchored !== true)
            .defaultFocus(view.state.widget === this.activeAuxiliaryWidget)
        }
      }
      // Read through this.auxiliaryWindows rather than `view`: the item is keyed
      // by component id so that a resize does not recreate the surface, which
      // means the builder keeps the `view` it was first given.
      .width(this.auxiliaryWidthVp(view.state.widget))
      .height(this.auxiliaryHeightVp(view.state.widget))
      .position({
        x: this.auxiliaryLeftVp(view.state.widget),
        y: this.auxiliaryTopVp(view.state.widget)
      })
      // Popups Chromium anchors to the page draw their own shadow and border.
      .shadow(view.state.anchored === true || view.state.pictureInPicture === true ? { radius: 0 } :
        { radius: 16, color: $r('app.color.shadow'), offsetY: 4 })
      // Default, not Block: Block keeps the touch test away from this Stack's
      // own children, and the Stack is not a touch target itself, so every
      // press inside the window came back "Touch test result is empty" and
      // never reached the XComponent -- the Stop button did nothing. Default
      // lets the XComponent take the press and still keeps it from the page
      // beneath this box.
    }, (view: AuxiliaryWindowView): string => view.state.componentId)
  }

  private findAuxiliaryWindow(widget: number): AuxiliaryWindowView | undefined {
    return this.auxiliaryWindows.find(
      (view: AuxiliaryWindowView): boolean => view.state.widget === widget);
  }

  private auxiliaryWidthVp(widget: number): number {
    return this.findAuxiliaryWindow(widget)?.widthVp ?? 0;
  }

  private auxiliaryHeightVp(widget: number): number {
    return this.findAuxiliaryWindow(widget)?.heightVp ?? 0;
  }

  private auxiliaryLeftVp(widget: number): number {
    return this.findAuxiliaryWindow(widget)?.leftVp ?? 0;
  }

  private auxiliaryTopVp(widget: number): number {
    return this.findAuxiliaryWindow(widget)?.topVp ?? AUXILIARY_WINDOW_MARGIN_VP;
  }

  private onScreenSizeChanged(width: number, height: number): void {
    if (width <= 0 || height <= 0 ||
      (width === this.screenSizeVp.width && height === this.screenSizeVp.height)) {
      return;
    }
    this.screenSizeVp = { width: width, height: height };
    // A rotation or a window resize changes the clamp, so every window is laid
    // out again against the new screen.
    this.auxiliaryWindows = this.auxiliaryWindows.map(
      (view: AuxiliaryWindowView): AuxiliaryWindowView => this.layoutAuxiliary(view.state, view.modal, view));
  }

  private layoutAuxiliary(
    state: AuxiliaryWindowState,
    modal: boolean,
    previous?: AuxiliaryWindowView
  ): AuxiliaryWindowView {
    const ui = this.getUIContext();
    // Before the first layout pass there is no screen size yet; the window's
    // own size stands in, and onScreenSizeChanged clamps it once one arrives.
    const screen: ScreenSizeVp = this.screenSizeVp.width > 0 ? this.screenSizeVp : {
      width: ui.px2vp(state.width) + 2 * AUXILIARY_WINDOW_MARGIN_VP,
      height: ui.px2vp(state.height) * 2
    };
    return layoutAuxiliaryWindow(state, modal, screen,
      (px: number): number => ui.px2vp(px), previous);
  }

  // Commands are batched rather than written straight to the state pair, so
  // that two sent from one handler both arrive. See BrowserCommandChannel.
  private readonly commandChannel: BrowserCommandChannel =
    new BrowserCommandChannel((text: string): void => {
      this.browserCommandText = text;
      this.browserCommandRevision += 1;
    });

  private executeBrowserCommand(command: BrowserCommandPayload): void {
    // 1.0.220 取证：进引擎前的最终漏斗。reload 会杀进行中的导航，命令侧
    this.commandChannel.send(command);
  }

  // 上次运行没走正常退出（划掉后台/被杀）时，引擎在启动后的状态快照里把
  // lastSessionRestorable 置 true，并持有一个一次性恢复锁；此前壳层从不消费
  // 这个标志，于是「清除后台 → 标签页全没了」（历史记录另走 HistoryService，
  // 所以看着正常）。这里静默把上次主窗口的标签页（含前进/后退历史）接回来：
  // 只认第一次快照；800ms 后再补发一次——命令若在 browser/tabs 就绪前被引擎
  // 丢掉，补发能救回来；锁已被消费时引擎直接忽略，天然幂等。
  private lastSessionRestoreAsked: boolean = false;
  // 已请求恢复会话、还在等恢复出来的标签给出真网址（用来起预热层）。
  private restoreCoverPending: boolean = false;
  // 冷启动要落在主页：等恢复出来的标签报出网址，再决定是原地留着还是另开主页标签。
  private coldStartHomePending: boolean = false;
  // 标签页徽标要显示的数字：-1 表示跟着 browserState.tabCount 走。
  // 首帧先显示上次退出时的标签数（壳层同步持久化），恢复会话期间一直冻结在
  // 这个值上：引擎是一个个把标签加回来的，直接跟 tabCount 会看到「数一遍」。
  @State private tabBadgeHold: number = -1;
  private lastSavedTabCount: number = -1;
  private savedTabCountContext: common.Context | undefined = undefined;
  // 关掉恢复出来的重复主页标签后，等状态里的标签数落到这个值再放开徽标；
  // 否则会先闪一下「多一个」的数量再跳回来。
  private badgeWaitForCount: number = -1;

  private holdTabBadge(): void {
    if (this.tabBadgeHold < 0) {
      this.tabBadgeHold = this.browserState.tabCount;
    }
  }

  private releaseTabBadge(delayMs: number = 0): void {
    const release = (): void => {
      this.tabBadgeHold = -1;
      // 窗口结束时把真实数量同步落盘，下次冷启动首帧就能直接显示它。
      const count: number = this.browserState.tabCount;
      if (count > 0 && count !== this.lastSavedTabCount && this.savedTabCountContext) {
        this.lastSavedTabCount = count;
        ShellUiPrefs.saveLastTabCountSync(this.savedTabCountContext, count);
      }
    };
    if (delayMs <= 0) {
      release();
      return;
    }
    setTimeout(release, delayMs);
  }

  // 冷启动落点：恢复是后台的，活动标签本来就是启动时那个主页，原地不动。
  // 万一引擎没支持后台恢复（旧版 .so），恢复的网页会被激活，这里再补开一个
  // 主页标签并关掉空白起始标签，保证落点仍是主页。
  private landOnHomeIfNeeded(retry: number = 0): void {
    if (!this.coldStartHomePending) {
      return;
    }
    const url: string = this.browserState.url ?? '';
    const currentTabs: BrowserTabState[] = this.browserState.tabs ?? [];
    if ((url.length === 0 ||
      currentTabs.length < this.lastSessionRestoredCount + 1) && retry < 3) {
      // 状态还没跟上（标签列表还没把恢复出来的标签收齐），再等一小会儿；
      // 最多 ~1.6s，之后由 6s 兜底收尾。
      setTimeout((): void => {
        this.landOnHomeIfNeeded(retry + 1);
      }, 400);
      return;
    }
    this.coldStartHomePending = false;
    if (url.length === 0 || isNewTabUrl(url) || url.startsWith('chrome')) {
      // 后台恢复已生效：主页一直在前台，没有网页首帧要遮，也不需要新开标签。
      this.restoreCoverPending = false;
      // 上次会话里那个主页标签也被恢复回来了，和启动时的主页重复：合并掉，
      // 否则「在主页清后台」每次重开都会多出一个标签。若真的关了一个，
      // 徽标要等标签数回落之后再放开，避免先闪 16 再变 15。
      if (!this.closeDuplicateHomeTab()) {
        this.releaseTabBadge(200);
      }
      return;
    }
    this.restoreCoverPending = false;
    this.executeBrowserCommand({ command: 'newTab', background: false });
    if (this.restoreStartTabWasNew) {
      this.restoreStartTabWasNew = false;
      this.executeBrowserCommand({
        command: 'closeTab',
        index: this.restoreStartTabIndex
      });
    }
    this.releaseTabBadge(200);
  }

  // 会话恢复把上次那个新标签页也追加回来了（冷启动本来已经给了一个）。
  // 只保留启动时的那个，其余多余的主页标签关掉一个即可覆盖常见情形。
  // 返回 true 表示确实发了 closeTab，徽标释放要等这次状态回落。
  private closeDuplicateHomeTab(): boolean {
    if (!this.restoreStartTabWasNew) {
      return false;
    }
    this.restoreStartTabWasNew = false;
    const tabs: BrowserTabState[] = this.browserState.tabs ?? [];
    for (const tab of tabs) {
      const index: number = tab.index ?? -1;
      if (index >= 0 && index !== this.restoreStartTabIndex &&
        isNewTabUrl(tab.url ?? '')) {
        this.badgeWaitForCount = this.browserState.tabCount - 1;
        this.executeBrowserCommand({ command: 'closeTab', index: index });
        // 状态万一没回来也不能一直冻结；状态先到时这个定时器会自然空转。
        setTimeout((): void => {
          if (this.badgeWaitForCount >= 0) {
            this.badgeWaitForCount = -1;
            this.releaseTabBadge();
          }
        }, 1000);
        return true;
      }
    }
    return false;
  }
  // 引擎的恢复是「追加」到当前窗口（chrome::AddRestoredTab 用 tabs->count()
  // 作索引）：启动时那个空白新标签页会留在 index 0，恢复的页面排在它后面，
  // 看起来就像「重开后又自动新建了一个标签页」。记下它，等
  // lastSessionRestored 确认恢复成功后再关；恢复失败时绝不能关（否则空窗口）。
  private restoreStartTabWasNew: boolean = false;
  private restoreStartTabIndex: number = -1;
  // 恢复出来的标签数，用来判断状态里的标签列表是否已经收齐。
  private lastSessionRestoredCount: number = 0;

  private maybeRestoreLastSession(state: BrowserStateSnapshot): void {
    if (this.lastSessionRestoreAsked || state.lastSessionRestorable !== true) {
      // 这次不是崩溃恢复（正常启动），没有恢复窗口，徽标直接跟真实值。
      if (state.lastSessionRestorable !== true && this.tabBadgeHold >= 0) {
        this.releaseTabBadge();
      }
      return;
    }
    this.lastSessionRestoreAsked = true;
    // 恢复出来的标签会重新加载，页面区在首帧之前是黑的：等它报出真网址就起防。
    this.restoreCoverPending = true;
    // 冷启动的落点固定是主页：网页就另开一个主页标签，主页则原地不动。
    this.coldStartHomePending = true;
    // 首帧已经把徽标冻结在上次的标签数上；这里只作兜底（context 没拿到时）。
    this.holdTabBadge();
    // 恢复失败/迟迟没状态时别把用户后来的导航当成冷启动落点。
    setTimeout((): void => {
      this.coldStartHomePending = false;
      this.badgeWaitForCount = -1;
      this.releaseTabBadge();
    }, 6000);
    const tabs = state.tabs;
    if (tabs && tabs.length === 1 && isNewTabUrl(tabs[0].url ?? '')) {
      this.restoreStartTabWasNew = true;
      this.restoreStartTabIndex = tabs[0].index;
    }
    const restore = (): void => {
      this.executeBrowserCommand({
        command: 'restoreLastSession',
        restore: true,
        mainWindowOnly: true,
        // 恢复的标签全部放在后台，当前这个主页标签保持活动：既不会先把网页
        // 顶到前台再切回主页（闪一下），也不用等恢复完再补开主页（有延迟）。
        background: true
      });
    };
    restore();
    setTimeout(restore, 800);
  }

  // Counts handleBack requests, so a late answer to an earlier one is not
  // acted on twice.
  private backRequestId: number = 0;

  private handleRuntimeEvent(event: BrowserRuntimeEvent): void {
    // The page had first refusal on the back gesture and did not take it, so
    // the tab goes back after all. An answer to an older request is ignored:
    // the reader may have pressed back twice before the first one came.
    if (event.event === 'backHandled') {
      if ((event.requestId ?? 0) === this.backRequestId &&
        !(event.handled ?? false)) {
        this.executeBrowserCommand({ command: 'back' });
      }
      return;
    }
    if (event.event === 'lastSessionRestored') {
      const restored: number = event.count ?? 0;
      this.lastSessionRestoredCount = restored;
      // 徽标要等落点判定和「合并重复主页标签」都做完再放开，否则会先显示
      // 恢复后的数量、关掉重复标签后又跳一次。
      // 恢复是后台的，启动时那个标签就是主页，不能在这里关掉（关了会把后台
      // 恢复出来的网页顶成活动标签）。只有下面判定「没走后台恢复」时才补关。
      if (restored > 0) {
        setTimeout((): void => {
          this.landOnHomeIfNeeded();
        }, 400);
      } else {
        // 没有可恢复的网页标签（上次就停在主页）：主页一直在前台，不需要预热层。
        this.coldStartHomePending = false;
        this.restoreCoverPending = false;
        this.badgeWaitForCount = -1;
        this.releaseTabBadge();
      }
      return;
    }
    if (event.event === 'pwaInstalled' && this.isDesktopAuraUi()) {
      AlertDialog.show({
        title: '\u5b89\u88c5\u5b8c\u6210',
        message: '\u606d\u559c\u60a8\uff0c\u60a8\u5df2\u7ecf\u5c06\u5b83\u4f5c\u4e3a\u5c0f\u7a0b\u5e8f\u5b89\u88c5\u5230\u672c\u673a\u4e86\u3002\u60a8\u53ef\u4ee5\u6dfb\u52a0\u670d\u52a1\u5361\u7247\uff0c\u5728\u684c\u9762\u663e\u793a\u5c0f\u7a0b\u5e8f\uff01',
        confirm: {
          value: '\u5b8c\u6210',
          action: (): void => {
          }
        }
      });
      return;
    }

    if (event.event === 'downloadUpdated') {
      const updated = shellEvent<DownloadUpdatedEvent>(event);
      this.downloadNotifier?.update(updated);
      // 1.0.2：App 内下载通知条数据源（snackbar 挂在 MobileBrowserOverlay：
      // 开始下载 → 下载完成[.crx→安装 / 其他→打开] → 失败）。系统通知栏仍由
      // DownloadNotifier 负责，这里是 App 内浮层通道。revision 保证内容变化
      // 必触发 @Watch（AppStorage 逐字节相同不算变，见 auraFindResult 先例）。
      AppStorage.setOrCreate('auraDownloadEvent', JSON.stringify({
        id: updated.id ?? '',
        fileName: updated.fileName ?? '',
        url: updated.url ?? '',
        state: updated.state ?? '',
        filePath: updated.filePath ?? '',
        mimeType: updated.mimeType ?? '',
        dangerous: updated.dangerous === true,
        failReason: updated.failReason ?? '',
        revision: Date.now()
      }));
      if (updated.id && updated.id.length > 0) {
        this.downloadFilePaths[updated.id] = updated.filePath ?? '';
      }
      // The downloads page watches this tick and re-lists (throttled) so
      // progress on it moves while a download is running.
      AppStorage.setOrCreate('auraPanelDownloadsTick', Date.now());
      return;
    }

    if (event.event === 'downloadList') {
      const list = shellEvent<DownloadListEvent>(event).items ?? [];
      // 列表项的 filePath 常缺失（见 downloadFilePaths 注释）：用累积的
      // id→filePath 回填，确保下载页「安装 .crx」能取到真实路径。
      for (const it of list) {
        const id: string = it.id ?? '';
        const fp: string = it.filePath ?? '';
        if (fp.length === 0 && id.length > 0 && this.downloadFilePaths[id]) {
          it.filePath = this.downloadFilePaths[id];
        }
      }
      AppStorage.setOrCreate('auraPanelDownloads', JSON.stringify(list));
      return;
    }

    // 资源嗅探：引擎拦截媒体/图片子资源并归类后，经以下事件与外壳通信。
    // resourceList：listResources 的回包（含 resources 列表）；resourceActionResult：
    // downloadResource / clearResources 的回执；resourcesChanged：页面继续加载时
    // 引擎广播“有新增资源”，外壳据此重拉一次列表。
    if (event.event === 'resourceList') {
      AppStorage.setOrCreate('auraPanelResourceList', JSON.stringify(event));
      return;
    }
    if (event.event === 'resourceActionResult') {
      AppStorage.setOrCreate('auraPanelEvent', JSON.stringify(event));
      return;
    }
    if (event.event === 'resourcesChanged') {
      AppStorage.setOrCreate('auraPanelResourceTick', Date.now());
      return;
    }

    if (event.event === 'tabThumbnails') {
      AppStorage.setOrCreate('auraTabThumbnails',
        JSON.stringify(shellEvent<TabThumbnailsEvent>(event).items ?? []));
      return;
    }

    if (event.event === 'favicons') {
      AppStorage.setOrCreate('auraFavicons',
        JSON.stringify(shellEvent<FaviconsEvent>(event).items ?? []));
      return;
    }

    if (event.event === 'findResult') {
      AppStorage.setOrCreate('auraFindResult', JSON.stringify({
        matches: event.matches ?? 0,
        activeMatch: event.activeMatch ?? 0,
        revision: Date.now()
      }));
      return;
    }

    if (event.event === 'recentlyClosed') {
      AppStorage.setOrCreate('auraPanelRecent',
        JSON.stringify(shellEvent<RecentlyClosedEvent>(event).items ?? []));
      return;
    }

    if (event.event === 'savedPasswords') {
      const sp = shellEvent<SavedPasswordsEvent>(event);
      // 必须连同 requestId 一起存回（对齐 bookmarkList 的 {requestId,nodes}），
      // 否则面板 onPasswordsPayload 的 seq 校验永远对不上、回包被丢弃、卡"加载中"。
      AppStorage.setOrCreate('auraPanelPasswords',
        JSON.stringify({ requestId: sp.requestId ?? -1, items: sp.items ?? [] }));
      return;
    }
    if (event.event === 'passwordRevealed') {
      const revealed = shellEvent<PasswordRevealedEvent>(event);
      AppStorage.setOrCreate('auraPanelPasswordSecret',
        JSON.stringify({ requestId: revealed.requestId, id: revealed.id,
          password: revealed.password, note: revealed.note }));
      return;
    }
    if (event.event === 'passwordCommandResult') {
      const result = shellEvent<PasswordCommandResultEvent>(event);
      AppStorage.setOrCreate('auraPanelPasswordResult',
        JSON.stringify({ command: result.command, ok: result.ok, reason: result.reason ?? '' }));
      return;
    }
    // 密码导入 / 导出回包。面板用它决定保存框、结果提示
    // 与沙箱缓存清理。
    if (event.event === 'passwordsImported') {
      const imported = shellEvent<PasswordsImportedEvent>(event);
      AppStorage.setOrCreate('auraPanelPasswordIo', JSON.stringify({
        kind: 'import',
        requestId: imported.requestId,
        ok: imported.ok,
        imported: imported.imported ?? 0,
        skipped: imported.skipped ?? 0,
        failed: imported.failed ?? 0,
        reason: imported.reason ?? ''
      }));
      return;
    }
    if (event.event === 'passwordsExported') {
      const exported = shellEvent<PasswordsExportedEvent>(event);
      AppStorage.setOrCreate('auraPanelPasswordIo', JSON.stringify({
        kind: 'export',
        requestId: exported.requestId,
        ok: exported.ok,
        imported: 0,
        skipped: 0,
        failed: 0,
        count: exported.count ?? 0,
        reason: exported.reason ?? ''
      }));
      return;
    }
    // 书签导入 / 导出回包。
    if (event.event === 'bookmarkImportDone') {
      const done = shellEvent<BookmarkImportDoneEvent>(event);
      AppStorage.setOrCreate('auraPanelBookmarkIo', JSON.stringify({
        kind: 'import',
        requestId: done.requestId,
        ok: done.ok,
        bookmarkCount: done.bookmarkCount ?? 0,
        folderCount: done.folderCount ?? 0,
        skippedCount: done.skippedCount ?? 0,
        error: done.error ?? ''
      }));
      return;
    }
    if (event.event === 'bookmarkExportDone') {
      const done = shellEvent<BookmarkExportDoneEvent>(event);
      AppStorage.setOrCreate('auraPanelBookmarkIo', JSON.stringify({
        kind: 'export',
        requestId: done.requestId,
        ok: done.ok,
        bookmarkCount: done.bookmarkCount ?? 0,
        folderCount: done.folderCount ?? 0,
        skippedCount: 0,
        error: done.error ?? ''
      }));
      return;
    }
    if (event.event === 'siteSettings') {
      const settings = shellEvent<SiteSettingsEvent>(event);
      AppStorage.setOrCreate('auraPanelSiteSettings',
        JSON.stringify({ requestId: settings.requestId, items: settings.items ?? [] }));
      return;
    }

    if (event.event === 'browserChromeRequested') {
      // 引擎在运行时询问"谁画浏览器 chrome"。我们全程自绘，强制 shell 模式，
      // 否则引擎会按设备类型默认画出原生标签条（主页左上角那排被裁掉的图标）。
      this.executeBrowserCommand({ command: 'setBrowserChrome', mode: 'shell' });
      return;
    }

    if (event.event === 'browserControlsRatio') {
      this.sawControlsRatio = true;
      const ratio = event.ratio ?? 1;
      if (ratio !== this.lastControlsRatio) {
        const prev: number = this.lastControlsRatio;
        this.lastControlsRatio = ratio;
        AppStorage.setOrCreate('auraBrowserControlsRatio', ratio);
      }
      return;
    }

    // 1.0.104 下拉刷新：引擎自己判定「页面已到顶 + 不是内层滚动 + overscroll-behavior
    // 允许」并负责 reload，外壳只负责把指示器画出来（见 engine ShellServiceTypes
    // 的 PullToRefreshEvent）。整包转存，由 MobileBrowserOverlay 渲染：
    // start→阈值 / pull→已拉距离 / release→是否真的刷新 / reset→收起。
    if (event.event === 'pullToRefresh') {
      const pull = shellEvent<PullToRefreshEvent>(event);
      AppStorage.setOrCreate('auraPullRefresh', JSON.stringify({
        state: pull.state,
        threshold: pull.threshold ?? 0,
        distance: pull.distance ?? 0,
        refresh: pull.refresh ?? false,
        at: Date.now()
      }));
      return;
    }

    // Profile data for the shell's own pages (bookmarks / history / settings).
    // The payloads are parked in AppStorage and the mobile panels read them
    // through @StorageLink (see components/mobile/PanelBridge.ets).
    if (event.event === 'recentBookmarks') {
      AppStorage.setOrCreate('auraPanelBookmarks',
        JSON.stringify(shellEvent<RecentBookmarksEvent>(event).nodes ?? []));
      return;
    }
    // 分层书签树（getBookmarks/searchBookmarks 的回包）——书签页的文件夹
    // 导航/搜索基于它（bookmarkApiVersion 1-3 的稳定命令）。
    if (event.event === 'bookmarkList') {
      const listed = shellEvent<BookmarkListEvent>(event);
      AppStorage.setOrCreate('auraPanelBookmarkList', JSON.stringify({
        requestId: listed.requestId,
        parentId: listed.parentId ?? '',
        nodes: listed.nodes ?? []
      }));
      return;
    }
    if (event.event === 'historyResults') {
      AppStorage.setOrCreate('auraPanelHistory',
        JSON.stringify(shellEvent<HistoryResultsEvent>(event).items ?? []));
      return;
    }
    // 网页全屏（video / requestFullscreen）：契约要求外壳收起自己的条带并把
    // 窗口切沉浸（见 ShellServiceTypes.PageFullscreenChangedEvent），否则
    // 状态栏还占着一条、页面视口少一截，画面只能缩在黑边里。
    if (event.event === 'pageFullscreenChanged') {
      this.setPageFullscreen(shellEvent<PageFullscreenChangedEvent>(event).fullscreen === true);
      return;
    }
    // 地址栏联想（autocomplete 命令的回包）：引擎会按同一 requestId 流式推
    // 多次（本地历史/书签/搜索建议），直到 done 为 true。外壳整包转存，由
    // MobileBrowserOverlay 按"最新 requestId"过滤后渲染。
    if (event.event === 'autocompleteResults') {
      const auto = shellEvent<AutocompleteResultsEvent>(event);
      AppStorage.setOrCreate('auraAutocomplete', JSON.stringify({
        requestId: auto.requestId,
        items: auto.items ?? [],
        done: auto.done ?? true
      }));
      return;
    }
    if (event.event === 'prefs') {
      AppStorage.setOrCreate('auraPanelPrefs',
        JSON.stringify(shellEvent<PrefsEvent>(event).values ?? []));
      return;
    }
    // 广告拦截：getAdBlockState / setAdBlock* / updateAdBlockSources 的回包
    // （adBlockState / adBlockConfigResult），以及引擎主动推的 adBlockStateChanged。
    // 原样转给「设置 → 广告拦截」面板，由它自己解析 sources / revision / contextId。
    if (event.event === 'adBlockState' ||
      event.event === 'adBlockConfigResult' ||
      event.event === 'adBlockStateChanged') {
      AppStorage.setOrCreate('auraPanelAdBlock', JSON.stringify(event));
      return;
    }
    // 小锁快捷面板：广告拦截/防钓鱼的「单站」回包（读-改-写协议的两半）。
    // 原样转存，SiteQuickPanel 自己解析（两个开关各自的 contextId/revision/
    // navigationId 都在回包里，写回时原样带上）。
    if (event.event === 'adBlockPageState' ||
      event.event === 'adBlockSiteResult' ||
      event.event === 'siteProtectionState' ||
      event.event === 'siteProtectionConfigResult') {
      AppStorage.setOrCreate('auraPanelSiteQuick', JSON.stringify(event));
      return;
    }
    if (event.event === 'searchEngines') {
      const engines = shellEvent<SearchEnginesEvent>(event).items ?? [];
      AppStorage.setOrCreate('auraPanelEngines', JSON.stringify(engines));
      // Keep the home surface and the address bar searching the way the
      // settings page shows: the default engine's resolved template.
      const ctx = this.getUIContext().getHostContext() as common.Context | undefined;
      SearchEnginesPrefs.loadDefaultId(ctx).then((id: string): void => {
        let template = '';
        // 持久化的内置默认优先（用户选过的内置引擎，重启后仍生效）。
        if (id.length > 0 && !id.startsWith('custom:')) {
          const hit = engines.find((e: SearchEngine): boolean => e.id === id);
          if (hit && hit.searchUrl && hit.searchUrl.length > 0) {
            template = hit.searchUrl;
          }
        }
        // 没命中再退回引擎上报的默认项（通常是 Bing）。
        if (template.length === 0) {
          for (const engine of engines) {
            if (engine.isDefault && engine.searchUrl && engine.searchUrl.length > 0) {
              template = engine.searchUrl;
              break;
            }
          }
        }
        if (template.length > 0) {
          AppStorage.setOrCreate('auraSearchUrlTemplate', template);
        }
        // 持久化默认是「自定义引擎」（引擎列表里不会出现），覆盖模板，
        // 保证重启后自定义默认搜索引擎仍然生效。
        if (id.startsWith('custom:')) {
          SearchEnginesPrefs.loadCustom(ctx).then((list: SearchEngine[]): void => {
            const hit = list.find((e: SearchEngine): boolean => e.id === id);
            if (hit && hit.searchUrl && hit.searchUrl.length > 0) {
              AppStorage.setOrCreate('auraSearchUrlTemplate', hit.searchUrl);
            }
          });
        }
      });
      return;
    }
    if (event.event === 'topSites') {
      AppStorage.setOrCreate('auraTopSites',
        JSON.stringify(shellEvent<TopSitesEvent>(event).items ?? []));
      return;
    }
    if (event.event === 'extensionActions') {
      AppStorage.setOrCreate('auraPanelExtensions',
        JSON.stringify(shellEvent<ExtensionActionsEvent>(event).items ?? []));
      return;
    }
    if (event.event === 'extensionDetails') {
      AppStorage.setOrCreate('auraPanelExtensionDetails',
        JSON.stringify(shellEvent<ExtensionDetailsEvent>(event)));
      return;
    }
    if (event.event === 'extensionActionsChanged') {
      AppStorage.setOrCreate('auraPanelEvent',
        JSON.stringify({ kind: 'extensionActionsChanged', revision: Date.now() }));
      return;
    }
    // 扩展「重新载入」的收到回执：引擎重载是异步的，这条只证明命令到达了
    // native，是否落地看随后的 extensionActionsChanged。
    if (event.event === 'extensionReloadReceived') {
      AppStorage.setOrCreate('auraPanelEvent',
        JSON.stringify({ kind: 'extensionReloadReceived', revision: Date.now() }));
      return;
    }
    // 扩展「重新载入」的落地回执：重载调用没有返回值，引擎只能把重载之后
    // 观察到的状态报回来，由外壳据此判断到底卡在哪一支。
    if (event.event === 'extensionReloadLanded') {
      const landed = shellEvent<ExtensionReloadLandedEvent>(event);
      AppStorage.setOrCreate('auraPanelEvent',
        JSON.stringify({
          kind: 'extensionReloadLanded',
          enabled: landed.enabled === true,
          blocked: landed.blocked === true,
          stuckReloading: landed.stuckReloading === true,
          pathExists: landed.pathExists === true,
          revision: Date.now()
        }));
      return;
    }
    // 原生扩展 popup 关闭：立刻收回主页盖层，不必再等兜底超时
    // （@Watch('onPopupHomeHoldChanged') 见 popupHomeHold 声明处）。
    if (event.event === 'extensionPopupClosed') {
      hilog.info(0x0000, 'ExtPanel', 'extensionPopupClosed received, hold -> 0');
      AppStorage.setOrCreate('auraPopupHomeHold', 0);
      return;
    }
    if (event.event === 'developerMode') {
      // 扩展页标题栏的「开发者模式」开关：引擎 profile pref 的回音。
      // 存 AppStorage 供 ExtensionPanel 读；setDeveloperMode 成功后引擎
      // 会立即回这个事件，所以开关状态永远以引擎为准。
      // revision 让 JSON 每次字节必变：同名同值回包（重开面板的
      // getDeveloperMode）不 otherwise 就唤不醒 @StorageLink 的 @Watch。
      const mode = shellEvent<DeveloperModeEvent>(event);
      AppStorage.setOrCreate('auraDeveloperMode',
        JSON.stringify({
          enabled: mode.enabled === true,
          available: mode.available !== false,
          revision: Date.now()
        }));
      return;
    }
    if (event.event === 'extensionInstallFailed') {
      const notice = shellEvent<ExtensionNoticePayload>(event);
      AppStorage.setOrCreate('auraPanelEvent',
        JSON.stringify({
          kind: 'extensionInstallFailed',
          revision: Date.now(),
          message: notice.message ?? '',
          reason: notice.reason ?? ''
        }));
      return;
    }
    if (event.event === 'extensionCommandFailed') {
      const notice = shellEvent<ExtensionNoticePayload>(event);
      AppStorage.setOrCreate('auraPanelEvent',
        JSON.stringify({
          kind: 'extensionCommandFailed',
          revision: Date.now(),
          message: notice.message ?? '',
          reason: notice.reason ?? '',
          command: notice.command ?? ''
        }));
      return;
    }
    if (event.event === 'aboutInfo') {
      const about = shellEvent<AboutInfoEvent>(event);
      AppStorage.setOrCreate('auraPanelAbout',
        JSON.stringify({ chromiumVersion: about.chromiumVersion ?? '' }));
      return;
    }
    if (event.event === 'browsingDataCounts') {
      AppStorage.setOrCreate('auraBrowsingDataCounts', JSON.stringify(event));
      return;
    }
    if (event.event === 'bookmarkCreated' ||
      event.event === 'bookmarksChanged' || event.event === 'historyChanged' ||
      event.event === 'prefsChanged' || event.event === 'clearBrowsingDataDone' ||
      event.event === 'savedPasswordsChanged') {
      AppStorage.setOrCreate('auraPanelEvent',
        JSON.stringify({ kind: event.event, revision: Date.now() }));
      return;
    }

    if (event.event === 'contextMenuRequested') {
      // 手机：启动配置里 contextMenu 是 'shell'，引擎不弹自己的菜单，由外壳
      // 画。v13 起手机画自绘卡片——model 序列化进 AppStorage，
      // MobileBrowserOverlay 渲染；平板 / 2in1 还没有那块 UI，维持系统动作
      // 面板。没有可显示项时立刻回一条 dismissed，引擎在等这一条。
      if (this.isMobilePhoneUi()) {
        const model: ContextMenuModel | undefined = buildContextMenuModel(event);
        if (model === undefined) {
          this.executeBrowserCommand({ command: 'contextMenuDismissed', requestId: event.requestId ?? 0 });
        } else {
          AppStorage.setOrCreate('auraContextMenu', JSON.stringify(model));
        }
      } else {
        showContextMenuSheet(this.getUIContext(), event, (command: BrowserCommandPayload): void => {
          this.executeBrowserCommand(command);
        });
      }
      return;
    }

    if (event.event === 'contextMenuActionsChanged') {
      // 菜单还开着时补点亮某项（例如"复制指向所选文字的链接"要等渲染器
      // 生成文字片段）。只更新同一 requestId 的那张卡；没有卡就忽略。
      const current: ContextMenuModel | undefined =
        parseContextMenuModel(AppStorage.get<string>('auraContextMenu') ?? '');
      if (current !== undefined && current.requestId === (event.requestId ?? 0)) {
        const updated: ContextMenuModel | undefined = updateContextMenuModel(current, event);
        if (updated === undefined) {
          AppStorage.setOrCreate('auraContextMenu', '');
          this.executeBrowserCommand({ command: 'contextMenuDismissed', requestId: current.requestId });
        } else {
          AppStorage.setOrCreate('auraContextMenu', JSON.stringify(updated));
        }
      }
      return;
    }

    if (event.event === 'pageDragStarted') {
      // 手指开始拖动（长按后移开，或在页面里拖东西）：把还开着的长按菜单
      // 收掉。引擎在等一条回复。
      const dragged: ContextMenuModel | undefined =
        parseContextMenuModel(AppStorage.get<string>('auraContextMenu') ?? '');
      if (dragged !== undefined) {
        AppStorage.setOrCreate('auraContextMenu', '');
        this.executeBrowserCommand({ command: 'contextMenuDismissed', requestId: dragged.requestId });
      }
      return;
    }

    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      if (event.event === 'filePickerRequested') {
        this.completeFilePicker({
          requestId: event.requestId ?? 0,
          paths: [],
          fileTypeIndex: event.fileTypeIndex ?? 0,
          canceled: true
        });
      }
      return;
    }
    if (event.event === 'systemPrintReady' && event.filePath) {
      SystemPrintAdapter.printPdf(context, event.filePath).catch((error: Error): void => {
        console.error('System print failed:', error);
      });
    } else if (event.event === 'shareRequested' && event.url) {
      HuaweiShareAdapter.sharePage(context, event.url, event.title ?? event.url)
        .catch((error: Error): void => {
          console.error('Huawei Share failed:', error);
        });
    } else if (event.event === 'castRequested') {
      this.currentTabCastSession.openPicker(context, this.browserState)
        .catch((error: Error): void => {
          console.error('HarmonyOS cast picker failed:', error);
        });
    } else if (event.event === 'filePickerRequested') {
      HarmonyFilePickerAdapter.show(context, event)
        .then((result: HarmonyFilePickerResult): void => {
          this.completeFilePicker(result);
        })
        .catch((error: Error): void => {
          console.error('HarmonyOS file picker failed:', error);
          this.completeFilePicker({
            requestId: event.requestId ?? 0,
            paths: [],
            fileTypeIndex: event.fileTypeIndex ?? 0,
            canceled: true
          });
        });
    } else if (event.event === 'permissionsRequested') {
      PermissionRequestAdapter.request(context, event)
        .then((result: PermissionRequestResultPayload): void => {
          this.completePermissionRequest(result);
        })
        .catch((error: Error): void => {
          console.error('HarmonyOS permission request failed:', error);
          this.completePermissionRequest({
            requestId: event.requestId ?? 0,
            granted: [],
            denied: event.permissions ?? []
          });
        });
    } else if (event.event === 'systemActionRequested' && event.action) {
      SystemIntegrationAdapter.handle(context, event.action as ChromiumSystemAction)
        .catch((error: Error): void => {
          console.error(`HarmonyOS system action failed: ${error.message}`);
        });
    } else if (event.event === 'externalUrlRequested') {
      this.handleExternalUrl(context, event);
    } else if (event.event === 'systemPrintFailed') {
      console.error(`Chromium PDF generation failed: ${event.reason ?? 'unknown'}`);
    }
  }

  /**
   * 网页里的外链（引擎已把 Android intent 转成对应 scheme，如 zhihu://、
   * bilibili://）。先问用户要不要离开浏览器，再用系统把它交给本机应用；
   * 用户拒绝或本机没有应用接得住，就退回浏览器打开 fallbackUrl。
   *
   * 不要拿 bundleManager.canOpenLink 来判断"有没有应用接得住"：它只认本应用
   * module.json5 的 querySchemes 里声明过的 scheme，碰到 zhihu://、bilibili://
   * 这种没声明的会直接抛 17700056，被 catch 吞掉后永远判成"没人接得住"，
   * 于是跳转永远不发生（点"打开 App"没反应就是这么来的）。能不能交出去，
   * 让 startAbility/openLink 自己报错更可靠。
   */
  private handleExternalUrl(context: common.UIAbilityContext, event: BrowserRuntimeEvent): void {
    const fallbackUrl: string = event.fallbackUrl ?? '';
    const target: string = (event.url ?? '').trim();

    // 开关关掉：一律留在浏览器里，不打扰用户。
    if (!this.externalAppLinks || target.length === 0) {
      this.openInBrowser(fallbackUrl);
      return;
    }

    // 标题用发起页的域名（引擎的 initiator 是 origin），和本机浏览器一致，
    // 读者一眼能看出是哪个网页想跳出去。
    const sourceHost: string = this.externalLinkSourceHost(event.initiator ?? '');
    AlertDialog.show({
      title: `${sourceHost}想打开其它应用`,
      message: '允许后会离开 Orbira，在对应的应用里继续。',
      primaryButton: {
        value: '取消',
        action: (): void => {
          // 用户不想跳：有 fallback 就留在浏览器里打开它。
          this.openInBrowser(fallbackUrl);
        }
      },
      secondaryButton: {
        value: '允许',
        action: (): void => {
          this.launchExternalApp(context, target, fallbackUrl);
        }
      }
    });
  }

  /**
   * 交给系统打开：https 链接走系统 App Linking（域名校验过的），其余 scheme
   * 走隐式 want 的 viewData —— 目标应用 skills 声明的就是 action + uri。
   * 报错说明本机没应用接得住，再让系统只按 uri 路由一次兜底，最后才留在
   * 浏览器里打开 fallbackUrl。
   */
  private launchExternalApp(context: common.UIAbilityContext, target: string, fallbackUrl: string): void {
    const isWebLink: boolean = target.startsWith('http://') || target.startsWith('https://');
    const want: Want = { action: 'ohos.want.action.viewData', uri: target };
    const attempt: Promise<void> = isWebLink
      ? context.openLink(target, { appLinkingOnly: true, hideFailureTipDialog: true })
      : context.startAbility(want);
    attempt.catch((): void => {
      context.openLink(target, { appLinkingOnly: false, hideFailureTipDialog: true })
        .catch((error: Error): void => {
          console.error(`No app takes external link ${target}: ${error.message}`);
          // 本机确实没有应用接得住（例如没装知乎）：退回网页版。
          this.openInBrowser(fallbackUrl);
        });
    });
  }

  // 发起页的域名（引擎的 initiator 形如 https://zhuanlan.zhihu.com）。
  // 浏览器自己发起的链接（设置里的 mailto:）没有 origin，返回空串给标题兜底。
  private externalLinkSourceHost(initiator: string): string {
    const value: string = initiator.trim();
    if (value.length === 0) {
      return '';
    }
    const withoutScheme: string = value.replace(/^[a-z][a-z0-9+.-]*:\/\//i, '');
    const cut: number = withoutScheme.search(/[/?#]/);
    const host: string = cut < 0 ? withoutScheme : withoutScheme.substring(0, cut);
    return host.length > 0 ? `${host} ` : '';
  }

  private openInBrowser(url: string): void {
    if (url.length === 0) {
      return;
    }
    this.executeBrowserCommand({ command: 'navigate', url: url });
  }

  private completeFilePicker(result: HarmonyFilePickerResult): void {
    this.executeBrowserCommand({
      command: 'filePickerResult',
      requestId: result.requestId,
      paths: result.paths,
      fileTypeIndex: result.fileTypeIndex,
      canceled: result.canceled
    });
  }

  // Tells the engine the top bar's extent once the surface is live
  // (SHELL_CONTRACT.md, "手机：滚动时收起地址栏和 dock", step 2). The engine
  // then drives its scroll-away and reports browserControlsRatio events to
  // move both bars.
  //
  // The dock is deliberately NOT sent as bottom controls (bottom: 0). A
  // non-zero bottom is counted into the top controls, so the engine takes
  // that strip out of the renderer's size: the page then ends above the dock
  // and the strip behind it is never page paint -- the opaque block behind
  // the floating dock. With 0 the page draws to the bottom of the window and
  // the dock floats over it; it still hides and returns with the top bar on
  // the same ratio, which the engine reports the same way either way.
  private configureBrowserControls(): void {
    if (this.browserControlsConfigured) {
      return;
    }
    this.browserControlsConfigured = true;
    // The fullscreen-immersive window draws under the status bar, so the
    // page's reserved extent includes it (EntryAbility stores it in vp).
    // minTop 0 keeps the page free to start at the very top, unless the
    // "hide the address bar on scroll" toggle is off: then minTop holds
    // the full height and the bar never collapses (engine ratio locked 1).
    this.sendBrowserControls();
    // 底部不再报任何高度（连手势条也不报）。内核会把这里的 bottom 从**布局**
    // 尺寸里整段扣掉（ohos-browser-controls.patch → OhosReservedHeight →
    // GetRequestedRendererSizeDevicePx），网页于是根本不往那一条画——手势条
    // 区"空一块"就是这么来的。传 0 后网页画满整窗到底，手势条只是浮在网页
    // 上的系统指示器；dock 默认同理（bottom 0 + 自绘浮层，不替网页占位），
    // 例外：dock 设为常驻（不随滚动收起）时它永久盖住一条，那一条要报进去，
    // 否则页面最后一行永远看不到——见 applyDockViewportInset。
    this.applyDockViewportInset();
    // Pull the search engines once, so the home surface and the address bar
    // search the same way the settings page shows before it has been opened.
    this.requestSearchEngines();
    // 真机实测（2026-10-09）：state.ready 那一瞬发出的这组命令会被引擎吞掉
    // （命令通道尚未接上），并且不会自愈——表现为"滚动时两栏永远不收起"，
    // 直到用户动一次设置开关（相当于重发）才恢复。这里启动一个带证据判据的
    // 兜底重发：一旦收到 browserControlsRatio（说明配置已生效）就停。
    this.scheduleBrowserControlsRetry(1);
  }

  private requestSearchEngines(): void {
    this.searchEnginesRequestSeq += 1;
    this.executeBrowserCommand({
      command: 'getSearchEngines',
      requestId: this.searchEnginesRequestSeq
    });
  }

  // 引擎只在内存里保存桌面站点名单，持久化在外壳。启动时补发几次：命令通道
  // 刚接上时会吞命令（真机实测），而脚本后台新开的标签不经过外壳导航，只能
  // 靠这里把名单送进引擎。
  private desktopSitesRetries: number = 0;

  private desktopSitesSynced: boolean = false;

  private syncDesktopSites(): void {
    // 只在启动时跑一轮：onBrowserState 每次状态更新都会进 ready 分支，
    // 不加闸门会不断重排重试，形成命令洪水（页面反复加载、脚本卡死）。
    // 重试耗尽同样要停：名单为空（没配桌面站点、总开关也没开）时闸门永远
    // 落不下来，缺这一条会每次状态轮询都白跑一遍。
    if (this.desktopSitesSynced || this.desktopSitesRetries >= 3) {
      return;
    }
    const sites: string = String(AppStorage.get('auraDesktopSites') ?? '');
    const allSites: boolean =
      String(AppStorage.get('auraUaDefault') ?? 'mobile') === 'desktop';
    // 不在这里 return：名单是异步从 preferences 读进来的，第一次调用时可能还是
    // 空的。始终留着重试，等它读出来再送一次。
    if (sites.length > 0 || allSites) {
      this.executeBrowserCommand({
        command: 'setDesktopSites',
        sites: sites,
        allSites: allSites,
        mobileSites: String(AppStorage.get('auraMobileSites') ?? '')
      });
      // 闸门只在名单真的发出去之后才落。放在发送判断之前会让重试的第二跳被
      // 开头闸门挡死：名单异步读出前闸门已关，迟到的名单永远补发不了。
      this.desktopSitesSynced = true;
    }
    if (this.desktopSitesRetries < 3) {
      this.desktopSitesRetries += 1;
      setTimeout((): void => {
        this.syncDesktopSites();
      }, 1500);
    }
  }

  // 启动兜底重发：每 1.5s 检查一次、最多 8 次（约 12s）。重发全部幂等，
  // 且只会在"配置未生效"时发生（此状态下本就没有收起动作，不会打断用户）。
  private scheduleBrowserControlsRetry(attempt: number): void {
    if (attempt > 8) {
      return;
    }
    setTimeout((): void => {
      if (this.sawControlsRatio) {
        return;
      }
      this.sendBrowserControls();
      this.applyDockViewportInset();
      this.requestSearchEngines();
      this.scheduleBrowserControlsRetry(attempt + 1);
    }, 1500);
  }

  // Chromium resolves a site's geolocation request against the app's own
  // permission before prompting, so it needs to know that permission. Reported
  // once the native side is live, and again after any request that could have
  // changed it.
  private reportSystemPermissionState(): void {
    // Subscribing here rather than at startup keeps the two together: the
    // report is only useful once the native side can receive it, and the
    // subscription exists to send the same report again when the user changes
    // the permission somewhere this shell cannot see.
    PermissionRequestAdapter.observeLocation((): void => {
      this.reportSystemPermissionState();
    });
    const state = PermissionRequestAdapter.locationState();
    hilog.info(0x0000, 'OhosPerm', 'reporting systemPermissionState=%{public}s', state);
    this.executeBrowserCommand({
      command: 'systemPermissionState',
      location: state
    });
  }

  private systemPermissionReported: boolean = false;
  private browserControlsConfigured: boolean = false;
  // 引擎开始上报收起比例 = 启动时的 browser controls 配置确实生效了。
  // 见 scheduleBrowserControlsRetry：收不到就兜底重发。
  private sawControlsRatio: boolean = false;
  private lastControlsRatio: number = -1;
  private searchEnginesRequestSeq: number = 0;

  private completePermissionRequest(result: PermissionRequestResultPayload): void {
    this.reportSystemPermissionState();
    this.executeBrowserCommand({
      command: 'permissionResult',
      requestId: result.requestId,
      granted: result.granted,
      denied: result.denied
    });
  }

  private handleAuxiliaryWindowState(state: AuxiliaryWindowState): void {
    if (state.windowRole === 'pwa') {
      this.handlePwaWindowState(state);
      return;
    }
    if (!this.isFullscreenWindow() && state.pictureInPicture !== true &&
      this.findAuxiliaryWindow(state.widget)?.state.pictureInPicture !== true) {
      return;
    }

    const previous = this.findAuxiliaryWindow(state.widget);
    const remaining = this.auxiliaryWindows.filter(
      (view: AuxiliaryWindowView): boolean => view.state.widget !== state.widget
    );
    if (state.visible && !state.destroyed) {
      const modal = state.modal ?? previous?.modal ?? false;
      remaining.push(this.layoutAuxiliary(state, modal, previous));
      remaining.sort((left: AuxiliaryWindowView, right: AuxiliaryWindowView): number =>
        left.state.stackingOrder - right.state.stackingOrder);
    }

    this.auxiliaryWindows = remaining;
    const focusable = remaining.filter(
      (view: AuxiliaryWindowView): boolean => view.state.anchored !== true);
    this.activeAuxiliaryWidget =
      focusable.length > 0 ? focusable[focusable.length - 1].state.widget : 0;
  }

  private handlePwaWindowState(state: AuxiliaryWindowState): void {
    if (state.destroyed || !state.visible) {
      this.launchingPwaWidgets = this.launchingPwaWidgets.filter(
        (widget: number): boolean => widget !== state.widget);
      return;
    }
    if (this.launchingPwaWidgets.includes(state.widget)) {
      return;
    }

    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    this.launchingPwaWidgets.push(state.widget);
    PwaWindowLauncher.launch(context, state, this.startupConfigText, this.profileId)
      .catch((error: Error): void => {
        this.launchingPwaWidgets = this.launchingPwaWidgets.filter(
          (widget: number): boolean => widget !== state.widget);
        console.error('Failed to launch the PWA system window:', error);
        this.requestAuxiliaryWindowDismiss(state.widget);
      });
  }

  private requestAuxiliaryWindowDismiss(widget: number): void {
    if (widget <= 0) {
      return;
    }
    this.auxiliaryDismissWidget = widget;
    this.auxiliaryDismissRevision += 1;
  }

  // 见 homeHold 字段注释。兜底定时器遇到「仍在加载」就续命：github 这类
  // 连不上的站点要 20s+ 才 commit，固定 8s 撤防会把引擎默认新标签页露出
  // 好几秒（真机反馈"先闪一个 Chromium 页面再出错误页"）。续命封顶 8 次
  // （≈56s）防引擎卡死时主页层永久盖住。
  private holdHomeForPaint(): void {
    this.homeHold = true;
    this.homeHoldSawLoading = false;
    this.homeHoldExtensions = 0;
    if (this.homeHoldQuickTimer !== -1) {
      clearTimeout(this.homeHoldQuickTimer);
      this.homeHoldQuickTimer = -1;
    }
    this.armHomeHoldTimer(8000);
  }

  private armHomeHoldTimer(ms: number): void {
    if (this.homeHoldTimer !== -1) {
      clearTimeout(this.homeHoldTimer);
    }
    this.homeHoldTimer = setTimeout((): void => {
      this.homeHoldTimer = -1;
      if (!this.homeHold) {
        return;
      }
      if (this.browserState.loading && this.homeHoldExtensions < 8) {
        this.homeHoldExtensions += 1;
        this.armHomeHoldTimer(6000);
        return;
      }
      this.releaseHomeHold();
    }, ms);
  }

  private releaseHomeHold(): void {
    this.homeHold = false;
    if (this.homeHoldTimer !== -1) {
      clearTimeout(this.homeHoldTimer);
      this.homeHoldTimer = -1;
    }
    if (this.homeHoldQuickTimer !== -1) {
      clearTimeout(this.homeHoldQuickTimer);
      this.homeHoldQuickTimer = -1;
    }
  }

  // 主页键：立即铺主页层（见 homeReturnCover 注释）。1.2s 兜底撤防，防止
  // 引擎没响应 home 命令时主页层一直盖着。
  private beginHomeReturnCover(): void {
    this.homeReturnCover = true;
    if (this.homeReturnTimer !== -1) {
      clearTimeout(this.homeReturnTimer);
    }
    this.homeReturnTimer = setTimeout((): void => {
      this.homeReturnTimer = -1;
      if (!this.homeReturnCover) {
        return;
      }
      // url 还停在原网页 = 引擎的 newtab 导航没落地（用户报「按主页键回到主页
      // 之后又被弹回之前的网页」：主页层只是被这 1.2s 假捂着，到点撤防就露出
      // 原页面）。撤防前先重发一次 home 再捂一拍；只重试一次。
      if (!this.isNewTabPage() && !this.homeRetryDone) {
        this.homeRetryDone = true;
        this.executeBrowserCommand({ command: 'home' });
        this.beginHomeReturnCover();
        return;
      }
      this.homeRetryDone = false;
      this.homeReturnCover = false;
    }, 1200);
  }

  private releaseHomeReturnCover(): void {
    this.homeReturnCover = false;
    this.homeRetryDone = false;
    if (this.homeReturnTimer !== -1) {
      clearTimeout(this.homeReturnTimer);
      this.homeReturnTimer = -1;
    }
  }

  private isNewTabPage(): boolean {
    return isNewTabUrl(this.browserState.url ?? '') || this.engineHomeCovered();
  }

  // 1.0.120：内置启动主页层要不要挂。在原来的 isNewTabPage() 基础上多一条
  // 冷启动预热判据：本次启动目标是真网址、且还没被引擎提交上来时，browserState
  // 仍是 EMPTY_BROWSER_STATE（url = chrome://newtab），照旧判定会先闪一帧内置
  // 启动页。预热期返回 false，交给 NavCoverView 那块同色底顶着。
  private homeSurfaceVisible(): boolean {
    // 扩展 popup 让位**最先判**：原生 popup 画在窗口层，主页盖层留着就会把它
    // 压在底下，用户看到的是「点扩展没反应」。这条必须压过 homeHold /
    // homeReturnCover —— 那两者是导航落地期的遮盖，从扩展页 back 回浏览器
    // 那一刻可能仍为真，顺序反了就会把 popup 盖回去（偶发「有时候弹不出来」）。
    // 清零来源：返回键（overlay 的 handleSystemBack）、导航离开主页、引擎的
    // extensionPopupClosed 事件；另有 10 分钟兜底。
    if (this.popupHomeHold > 0) {
      return false;
    }
    if (this.homeHold || this.homeReturnCover) {
      return true;
    }
    if (this.navCover) {
      return false;
    }
    return this.isNewTabPage();
  }

  // 1.0.121：导航预热层。用 browser_canvas（外壳底同色）铺满，淡出时不会
  // 出现第二种颜色；退场动画挂在 if 分支根节点上才播得出来。
  @Builder
  private NavCoverView() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.browser_canvas'))
      .transition(TransitionEffect.opacity(0).animation({ duration: 200, curve: Curve.Friction }))
  }

  // 「导航失败后露出的引擎新标签页」（用户报：github 连不上网，返回后到这个满屏
  // 原生磁贴的页面，地址栏却还是 github.com）。成因在引擎侧：
  // aura_shell_runtime_bridge.cc:2968 的 state.url 取的是
  // WebContents::GetVisibleURL() —— 失败的待定导航**没提交**，于是 url 报的是那个
  // 失败的地址，而画面还停在最后提交的那一页 = 引擎自己的新标签页。
  // 判据（三条同时满足才认，避免误盖真的页面）：
  //   ① 不在加载中；
  //   ② 没有可后退的历史（失败导航不产生历史项，说明这一页就是本次会话的第一页）；
  //   ③ URL 是 http(s)，但标题仍是新标签页的标题（或压根没标题 = 什么页面都没提交）。
  private engineHomeCovered(): boolean {
    const url = this.browserState.url ?? '';
    if (isNewTabUrl(url)) {
      return false;
    }
    if (this.browserState.loading || this.browserState.canGoBack) {
      return false;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return false;
    }
    const title = (this.browserState.title ?? '').trim();
    if (title.length === 0) {
      return true;
    }
    return this.newTabTitleSeen.length > 0 && title === this.newTabTitleSeen;
  }

  private isMobilePhoneUi(): boolean {
    if (!this.startupConfigText || this.startupConfigText.trim().length === 0) {
      return this.browserState.uiFamily === 'mobile_phone';
    }

    try {
      const startupConfig = JSON.parse(this.startupConfigText) as Record<string, Object>;
      return String(startupConfig['uiFamily'] ?? '') === 'mobile_phone';
    } catch (error) {
      return this.browserState.uiFamily === 'mobile_phone';
    }
  }

  private isDesktopAuraUi(): boolean {
    if (!this.startupConfigText || this.startupConfigText.trim().length === 0) {
      return this.browserState.uiFamily === 'aura_pc' ||
        this.browserState.uiFamily === 'aura_tablet';
    }
    try {
      const startupConfig = JSON.parse(this.startupConfigText) as Record<string, Object>;
      const uiFamily = String(startupConfig['uiFamily'] ?? '');
      return uiFamily === 'aura_pc' || uiFamily === 'aura_tablet';
    } catch (error) {
      return this.browserState.uiFamily === 'aura_pc' ||
        this.browserState.uiFamily === 'aura_tablet';
    }
  }

  private isFullscreenWindow(): boolean {
    if (!this.startupConfigText || this.startupConfigText.trim().length === 0) {
      return this.isMobilePhoneUi();
    }
    try {
      const startupConfig = JSON.parse(this.startupConfigText) as Record<string, Object>;
      return String(startupConfig['windowMode'] ?? '') === 'fullscreen';
    } catch (error) {
      return this.isMobilePhoneUi();
    }
  }
}
