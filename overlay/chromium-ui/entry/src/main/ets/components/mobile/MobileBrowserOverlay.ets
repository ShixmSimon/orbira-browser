import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { AVCastPicker, AVCastPickerColorMode, AVCastPickerStyle } from '@kit.AVSessionKit';
import { hdsEffect, hdsMaterial, HdsTabs, HdsTabsFloatingStyle } from '@kit.UIDesignKit';
import { inputMethod } from '@kit.IMEKit';
import { curves } from '@kit.ArkUI';
import display from '@ohos.display';
import { showSystemPasteDialog } from './SystemPasteDialog';
import { ScanService } from './ScanService';
import {
  BrowserCommandPayload,
  BrowserStateSnapshot,
  BrowserTabState,
  ContextMenuAction,
  TabThumbnail
} from 'engine';
import { HuaweiShareAdapter } from 'engine';
import { GripSide, HoldingHandRouter } from './HoldingHandRouter';
import { CurrentTabCastSession } from './CurrentTabCastSession';
import { BookmarksPanel } from './BookmarksPanel';
import {
  ContextMenuItem,
  ContextMenuModel,
  EMPTY_CONTEXT_MENU_MODEL,
  parseContextMenuModel,
  shellCopyTextFor
} from './ContextMenuSheet';
import { DownloadsPanel } from './DownloadsPanel';
import { ExtensionPanel } from './ExtensionPanel';
import { HistoryPanel } from './HistoryPanel';
import { MobileBackRouter } from './MobileBackRouter';
import { PasswordsPanel } from './PasswordsPanel';
import { RecentPanel } from './RecentPanel';
import { SettingsPanel } from './SettingsPanel';
import { SitePermissionsPanel } from './SitePermissionsPanel';
import { normalizeAddress } from './ShellUtils';
import { IncognitoSwitch, SavedTab } from '../../utils/IncognitoSwitch';

// The floating bars' full vertical extents (top gap + bar height), in vp.
// AuraShell reports the top bar to the engine through setBrowserControls;
// the browserControlsRatio event then drives both bars' translation, so the
// page and both bars move together while scrolling (SHELL_CONTRACT.md,
// "手机：滚动时收起地址栏和 dock"). The dock is not reported: it reserves
// no room on the page and floats over it.
export const TOP_BAR_EXTENT_VP: number = 52;
// Dock height 48 + container top breathing 12: the bar must travel far
// enough to fully leave the screen when the page scrolls (controlsRatio 0).
export const BOTTOM_DOCK_EXTENT_VP: number = 60;

// The glass bar itself (the Row inside the dock's container): the material
// plate and the painted fallback must agree on it exactly.
// 48vp = Lumie 的 PHONE_DOCK_HEIGHT：同一台手机截图实测，Lumie 胶囊
// 167px ≈ 48vp，我们的 62 画出来 218px，并排就是"太粗"。
const DOCK_BAR_HEIGHT_VP: number = 48;
const DOCK_BAR_RADIUS_VP: number = 24;
// 每个 dock 页签项的固有宽度：HDS 浮动页签在没收到显式 barWidth 时会按
// 内容测量条形宽度，而内容里再套 100% 宽就成了循环依赖——v9 那版真机上
// 整个条塌成一个点就是这个原因。给每项一个具体宽度，两条路都能立起来：
// 显式 barWidth 生效时 Fixed 均分（约 65.4），不生效时 5 × 65 = 325 兜底。
const DOCK_SLOT_WIDTH_VP: number = 65;

// 浮动条宽度 = 屏幕宽 - 左右各 16 的边距。用 display 同步算（而不是等
// 布局量完），首帧就有正确宽度，材质不会闪一下。
function resolveDockBarWidthVp(): number {
  try {
    const info: display.Display = display.getDefaultDisplaySync();
    if (info.densityPixels > 0 && info.width > 0) {
      const vpWidth: number = info.width / info.densityPixels;
      if (Number.isFinite(vpWidth) && vpWidth > 64) {
        return vpWidth - 32;
      }
    }
  } catch (error) {
    // Fall through to the design-width fallback below.
  }
  return 328;
}

// dock 的底距。v11 曾照搬 Lumie 的钳制算法（反编译 PhoneControlsSync
// .phoneDockBottom：min(安全区, PHONE_TOOLBAR_SAFE_MAX=16) + GAP=4，本机
// 算得 20vp），真机用户反馈"太贴边、调回原来的位置"，已回退为原始安全区
// 值（本机 28vp）。dock 位置、收起行程、响应区条带三处共用这一个底距。
function resolveDockBottomMarginVp(safeVp: number): number {
  return Number.isFinite(safeVp) ? Math.max(safeVp, 0) : 0;
}

// The tab grid: two columns ten vp apart, each card 208 tall of which the
// title row takes 36. The picture therefore fills TAB_THUMB_HEIGHT_VP of a
// card (grid width - gap) / 2 wide -- the shape getTabThumbnails is asked to
// capture, so a portrait card shows more of the page than the engine's
// default 4:3 would.
const TAB_GRID_COLUMNS: number = 2;
const TAB_GRID_GAP_VP: number = 10;
const TAB_CARD_HEIGHT_VP: number = 208;
const TAB_CARD_TITLE_VP: number = 36;
export const TAB_THUMB_HEIGHT_VP: number = TAB_CARD_HEIGHT_VP - TAB_CARD_TITLE_VP;
// ⋮ 菜单卡片：Lumie 那块是 258 上下、贴着屏幕右侧，左边留出底下网页的宽度。
const MENU_CARD_WIDTH_VP: number = 258;
// 长按菜单卡片（v13）：与 ⋮ 卡片同宽同款，锚在按压点旁边。
const CONTEXT_MENU_CARD_WIDTH_VP: number = 258;

enum MobileEdgeAction {
  BACK = 'back',
  MENU = 'menu'
}

const PRIMARY_ACTION_KEY: string = 'mobilePrimaryAction';
const FOLLOW_GRIP_KEY: string = 'mobileFollowGrip';
const LAST_GRIP_SIDE_KEY: string = 'mobileLastGripSide';

// findResult payload parked in AppStorage by AuraShell.
interface FindResultSummary {
  matches?: number;
  activeMatch?: number;
  revision?: number;
}

// HarmonyOS 7 沉浸光感：设备能不能渲染系统沉浸材质。走 HDS 探测
// （getSystemMaterialTypes）——与 Lumie 同一个入口：全 NONE（材质被系统
// 关掉）或旧 SDK 抛错都算不可用，dock 回退纯色玻璃。一次探测、进程内缓存。
let cachedDockMaterialAvailable: boolean | undefined = undefined;

function isDockMaterialAvailable(): boolean {
  if (cachedDockMaterialAvailable !== undefined) {
    return cachedDockMaterialAvailable;
  }
  try {
    const types: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
    cachedDockMaterialAvailable = types.some((type: hdsMaterial.MaterialType): boolean =>
      type !== hdsMaterial.MaterialType.NONE);
  } catch (error) {
    cachedDockMaterialAvailable = false;
  }
  return cachedDockMaterialAvailable;
}

@Component
export struct MobileBrowserOverlay {
  @StorageLink('auraColorScheme') colorScheme: string = 'light';
  // Safe-area insets (status bar / navigation pill) in vp, from EntryAbility.
  @StorageProp('auraTopSafeVp') topSafeVp: number = 0;
  @StorageProp('auraBottomSafeVp') bottomSafeVp: number = 0;
  @Prop @Watch('onBrowserStateChanged') browserState: BrowserStateSnapshot;
  // 无痕会话（重启进来的那一种，见 utils/IncognitoSwitch.ets）。
  @Prop incognito: boolean = false;
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};

  @State private menuVisible: boolean = false;
  @State private editingAddress: boolean = false;
  // Fix B（点搜索跳一下）：提交地址栏导航后延迟顶栏回弹到首帧绘制完成，
  // 避免 setBrowserControlsState 视口 resize 与 Chromium 首帧 swap 叠加造成跳动。
  private pendingControlsRebound: boolean = false;
  private controlsReboundSawLoading: boolean = false;
  private reboundTimer: number = 0;
  @State private addressDraft: string = '';
  @State private primaryAction: MobileEdgeAction = MobileEdgeAction.BACK;
  @State private followGrip: boolean = true;
  @State private lastGripSide: GripSide = GripSide.LEFT;
  // Which dock button is being pressed (by label), for the springy press
  // feedback. Hand-rolled "jelly": unlike the system interactive material,
  // the under-damped spring works on any device and target API level.
  @State private pressedDock: string = '';
  // Which page the sheet shows: the tabs menu only now; kept as the reset
  // value while the sheet opens or closes.
  @State private sheetPage: string = 'tabs';
  // The ⋮ menu is a floating card above the dock (Lumie-style), not a
  // sheet; the sheet hosts the tab switcher only.
  @State private menuCardVisible: boolean = false;
  // 长按网页元素（链接 / 图片 / 选区）：AuraShell 把 buildContextMenuModel
  // 的结果序列化写进 AppStorage，这里画卡片（v13，取代系统动作面板）。
  // 空串 = 没有菜单；用户选一项或关掉时回 contextMenuAction /
  // contextMenuDismissed 并清空。
  @StorageLink('auraContextMenu') contextMenuJson: string = '';
  // 页内查找 (findInPage): a small bar under the top area.
  @State private findVisible: boolean = false;
  @State private findQuery: string = '';
  @StorageLink('auraFindResult') findResultJson: string = '';
  // Tab switcher card previews, keyed by tab id.
  @StorageLink('auraTabThumbnails') tabThumbnailsJson: string = '';
  private tabThumbnails: Map<string, string> = new Map();
  // What to ask getTabThumbnails for: the card's width, and the card's width
  // over its picture's height. Measured once the grid has laid itself out, so
  // the first request -- made on the tap that opens the switcher -- falls back
  // to the engine's own 4:3 and is re-asked for as soon as there is a size.
  @State private tabThumbWidthVp: number = 160;
  @State private tabThumbAspect: number = 0;
  // Which full-screen shell page is open ('none' while browsing). The shell's
  // sub-pages are full-screen like Lumie's, not part of the bottom sheet.
  @State private panelPage: string = 'none';
  // True while the extensions page was opened from settings, so its back
  // button returns there instead of closing to the browser.
  private extensionsFromSettings: boolean = false;
  // 0..1, from the engine: how much of the top bar the page is showing.
  // 1 keeps both bars in place; 0 has scrolled both fully away. Applied
  // straight from the storage link so one engine update is one render pass.
  @StorageLink('auraBrowserControlsRatio') controlsRatioRaw: number = 1;

  private readonly holdingHandRouter: HoldingHandRouter = new HoldingHandRouter();
  private readonly currentTabCastSession: CurrentTabCastSession = new CurrentTabCastSession();
  // Floating-chrome styling note: the dock's system immersive material (沉浸
  // 光感) is drawn through HDS, the same door Lumie's dock uses -- a real
  // HdsTabs whose tabBar entries ARE the dock buttons (DockMaterialPlate
  // below). uiMaterial was the first attempt and is scoped far tighter
  // (bottom TabBar inside a horizontal Tabs only); on device it rendered
  // nothing. HDS renders anywhere. The top bar stays painted.
  private readonly dockMaterialActive: boolean = isDockMaterialAvailable();
  // 视口高度（vp），首次布局即上报；dock 条带的响应区以它为底边基准。
  @State private viewportHeightVp: number = 0;

  private keyboardRecoveryTimers: number[] = [];
  private readonly addressController: TextInputController = new TextInputController();
  private addressSelectionStart: number = 0;
  private addressSelectionEnd: number = 0;
  private addressEditEpoch: number = 0;
  private requestSeq: number = 0;

  aboutToAppear(): void {
    const storedAction = String(AppStorage.get(PRIMARY_ACTION_KEY) ?? MobileEdgeAction.BACK);
    this.primaryAction = storedAction === MobileEdgeAction.MENU ?
      MobileEdgeAction.MENU : MobileEdgeAction.BACK;
    this.followGrip = Boolean(AppStorage.get(FOLLOW_GRIP_KEY) ?? true);
    const storedSide = String(AppStorage.get(LAST_GRIP_SIDE_KEY) ?? GripSide.LEFT);
    this.lastGripSide = storedSide === GripSide.RIGHT ? GripSide.RIGHT : GripSide.LEFT;
    if (this.followGrip) {
      this.startHoldingHandAwareness();
    }
    // The entry page's onBackPress asks this before letting the system back
    // gesture exit the app.
    MobileBackRouter.handler = (): boolean => this.handleSystemBack();
    // The cast session starts when the cast picker opens, not here. HarmonyOS
    // allows one AVSession per ability, and an idle one held from launch left
    // the engine's media session (control center card) unable to exist.
  }

  aboutToDisappear(): void {
    MobileBackRouter.handler = undefined;
    this.clearKeyboardRecoveryTimers();
    if (this.reboundTimer !== 0) {
      clearTimeout(this.reboundTimer);
      this.reboundTimer = 0;
    }
    this.holdingHandRouter.stop();
    this.currentTabCastSession.stop().catch((error: Error) => {
      console.error('Failed to stop current-tab cast session:', error);
    });
  }

  // The page's onBackPress asks this first: dismiss chrome the user can see
  // (address editing, the tab menu, a full-screen shell page), then page
  // history, and only leave the app when there is nothing of ours to unwind.
  private handleSystemBack(): boolean {
    // 长按菜单是最上面的一层：先它。
    if (this.contextMenuJson.length > 0) {
      this.dismissContextMenu();
      return true;
    }
    if (this.editingAddress) {
      this.clearKeyboardRecoveryTimers();
      this.editingAddress = false;
      return true;
    }
    if (this.findVisible) {
      this.closeFindBar();
      return true;
    }
    if (this.menuCardVisible) {
      this.closeMenuCard();
      return true;
    }
    if (this.menuVisible) {
      this.closeMenuSheet();
      return true;
    }
    if (this.panelPage !== 'none') {
      this.closePanel();
      return true;
    }
    // Back on the home surface there is nothing left of ours to unwind --
    // the gesture ends the app instead of paging further back through
    // history that was left behind when "home" was pressed.
    if (this.isNewTabUrl(this.browserState.url)) {
      return false;
    }
    if (this.browserState.canGoBack) {
      this.issueCommand({ command: 'back' });
      return true;
    }
    return false;
  }

  private onBrowserStateChanged(): void {
    // Fix B：导航提交后，等首帧绘制（loading true→false）再回弹顶栏，
    // 消除与首帧 swap 叠加的跳动。
    if (this.pendingControlsRebound) {
      if (this.browserState.loading) {
        this.controlsReboundSawLoading = true;
      } else if (this.controlsReboundSawLoading) {
        this.flushControlsRebound();
      }
    }
    this.currentTabCastSession.update(this.browserState);
    this.maybeActivatePendingNewTab();
  }

  // Fix B：提交导航后延迟顶栏回弹。理想路径由 onBrowserStateChanged 在
  // loading true→false 时回弹；兜底 1.5s 强制回弹（同 URL 未触发加载等）。
  private reboundControlsAfterPaint(): void {
    this.pendingControlsRebound = true;
    this.controlsReboundSawLoading = false;
    if (this.reboundTimer !== 0) {
      clearTimeout(this.reboundTimer);
    }
    this.reboundTimer = setTimeout((): void => {
      this.reboundTimer = 0;
      this.flushControlsRebound();
    }, 1500);
  }

  private flushControlsRebound(): void {
    if (!this.pendingControlsRebound) {
      return;
    }
    this.pendingControlsRebound = false;
    this.controlsReboundSawLoading = false;
    if (this.reboundTimer !== 0) {
      clearTimeout(this.reboundTimer);
      this.reboundTimer = 0;
    }
    this.issueCommand({ command: 'setBrowserControlsState', state: 'both' });
  }

  private parseThumbnails(): void {
    try {
      const items: TabThumbnail[] = JSON.parse(this.tabThumbnailsJson) as TabThumbnail[];
      const map: Map<string, string> = new Map();
      for (const item of items) {
        map.set(item.id, `data:image/png;base64,${item.pngBase64}`);
      }
      this.tabThumbnails = map;
    } catch (error) {
      this.tabThumbnails = new Map();
    }
  }

  private thumbnailFor(tab: BrowserTabState): string {
    if (tab.id && tab.id.length > 0) {
      const value = this.tabThumbnails.get(tab.id);
      if (value) {
        return value;
      }
    }
    return '';
  }

  private requestTabThumbnails(): void {
    this.parseThumbnails();
    const ids: string[] = [];
    for (const tab of this.browserState.tabs) {
      if (tab.id && tab.id.length > 0) {
        ids.push(tab.id);
      }
    }
    if (ids.length === 0) {
      return;
    }
    this.requestSeq += 1;
    // The engine (from build-443425d6) takes an optional card aspect; older
    // engines ignore it and answer with the same 4:3 picture as before.
    if (this.tabThumbAspect > 0) {
      this.issueCommand({
        command: 'getTabThumbnails',
        requestId: this.requestSeq,
        ids: ids,
        widthVp: this.tabThumbWidthVp,
        aspect: this.tabThumbAspect
      });
    } else {
      this.issueCommand({
        command: 'getTabThumbnails',
        requestId: this.requestSeq,
        ids: ids,
        widthVp: this.tabThumbWidthVp
      });
    }
  }

  // Once the grid has a size, ask for pictures shaped like its cards: a card
  // taller than it is wide then shows more than the top few lines of a page.
  private measureTabGrid(area: Area): void {
    const gridWidth: number = Number(area.width);
    if (gridWidth <= 0) {
      return;
    }
    const cardWidth: number =
      (gridWidth - TAB_GRID_GAP_VP * (TAB_GRID_COLUMNS - 1)) / TAB_GRID_COLUMNS;
    const aspect: number = Math.min(Math.max(cardWidth / TAB_THUMB_HEIGHT_VP, 0.4), 2.5);
    if (Math.abs(aspect - this.tabThumbAspect) < 0.02) {
      return;
    }
    this.tabThumbAspect = aspect;
    this.tabThumbWidthVp = Math.max(80, Math.round(cardWidth));
    this.requestTabThumbnails();
  }

  private closeMenuCard(): void {
    this.menuCardVisible = false;
  }

  // ---- 长按菜单（自绘卡片，2026-10-09 v13）----
  //
  // 协议见 docs/SHELL_CONTRACT.md「长按菜单」：每次 contextMenuRequested 都
  // 要回一条 contextMenuAction（选了某项）或 contextMenuDismissed（没选就
  // 关），requestId 一一对应；新的一次长按直接替换旧的。卡片锚在按压点
  // 旁边，位置夹取，绝不出屏。

  private contextMenuModelOrDefault(): ContextMenuModel {
    return parseContextMenuModel(this.contextMenuJson) ?? EMPTY_CONTEXT_MENU_MODEL;
  }

  private clearContextMenu(): void {
    AppStorage.setOrCreate('auraContextMenu', '');
  }

  private chooseContextMenuAction(model: ContextMenuModel, action: ContextMenuAction): void {
    const copyText: string | undefined = shellCopyTextFor(model, action);
    this.clearContextMenu();
    if (copyText !== undefined) {
      // Shell-side copy: the engine's own copies flash a native "copied"
      // toast pinned at the window top, which an immersive window clips in
      // half (see shellCopyTextFor). Dismissed, so the engine never acts.
      this.copyPlainText(copyText);
      this.issueCommand({ command: 'contextMenuDismissed', requestId: model.requestId });
      return;
    }
    if (action === 'openLinkInNewTab' || action === 'openImageInNewTab' ||
      action === 'openMediaInNewTab') {
      // Chromium opens these in a background tab and stays put. Remember the
      // tab set; the first state snapshot carrying an unknown id is the new
      // tab, and that is the page the reader asked to go to.
      this.armPendingNewTabSwitch();
    }
    this.issueCommand({ command: 'contextMenuAction', requestId: model.requestId, action: action });
  }

  private copyPlainText(text: string): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).catch((error: Error): void => {
        console.error('Failed to copy text:', error.message);
      });
    } catch (error) {
      console.error('Failed to copy text');
    }
    this.getUIContext().getPromptAction().showToast({ message: '已复制', duration: 1500 });
  }

  // ---- 后台开标签后自动切过去（长按菜单 open*InNewTab）----

  // Tab ids at the moment the action was sent; the new tab is whichever id
  // shows up later that is not in here.
  private pendingNewTabSwitch: boolean = false;
  private pendingNewTabIds: Set<string> = new Set<string>();
  private pendingNewTabTimer: number = -1;

  private armPendingNewTabSwitch(): void {
    this.pendingNewTabIds = new Set<string>();
    for (const tab of this.browserState.tabs) {
      const id: string | undefined = tab.id;
      if (id !== undefined && id.length > 0) {
        this.pendingNewTabIds.add(id);
      }
    }
    this.pendingNewTabSwitch = true;
    if (this.pendingNewTabTimer >= 0) {
      clearTimeout(this.pendingNewTabTimer);
    }
    // Safety: if no new tab ever appears (the action failed), stop watching.
    this.pendingNewTabTimer = setTimeout((): void => {
      this.pendingNewTabSwitch = false;
      this.pendingNewTabTimer = -1;
    }, 10000);
  }

  private maybeActivatePendingNewTab(): void {
    if (!this.pendingNewTabSwitch) {
      return;
    }
    for (const tab of this.browserState.tabs) {
      const id: string | undefined = tab.id;
      if (id !== undefined && id.length > 0 && !this.pendingNewTabIds.has(id)) {
        this.pendingNewTabSwitch = false;
        if (this.pendingNewTabTimer >= 0) {
          clearTimeout(this.pendingNewTabTimer);
          this.pendingNewTabTimer = -1;
        }
        this.issueCommand({ command: 'activateTab', index: tab.index });
        return;
      }
    }
  }

  private dismissContextMenu(): void {
    const model: ContextMenuModel | undefined = parseContextMenuModel(this.contextMenuJson);
    this.clearContextMenu();
    if (model !== undefined) {
      this.issueCommand({ command: 'contextMenuDismissed', requestId: model.requestId });
    }
  }

  // 系统安全粘贴：浏览器进程拿不到明文剪贴板，走系统对话框取一次文本再
  // 插回（insertText）。先收菜单再弹对话框，避免两层浮层同时在场。
  private pasteFromContextMenu(model: ContextMenuModel): void {
    const ui: UIContext = this.getUIContext();
    this.clearContextMenu();
    setTimeout((): void => {
      showSystemPasteDialog(ui,
        (text: string): void => {
          this.issueCommand({ command: 'insertText', requestId: model.requestId, text: text });
        },
        (): void => {
          this.issueCommand({ command: 'contextMenuDismissed', requestId: model.requestId });
        });
    }, 0);
  }

  private deviceWidthVp(): number {
    try {
      const info: display.Display = display.getDefaultDisplaySync();
      if (info.densityPixels > 0 && info.width > 0) {
        return info.width / info.densityPixels;
      }
    } catch (error) {
    }
    return 360;
  }

  private deviceHeightVp(): number {
    try {
      const info: display.Display = display.getDefaultDisplaySync();
      if (info.densityPixels > 0 && info.height > 0) {
        return info.height / info.densityPixels;
      }
    } catch (error) {
    }
    return this.viewportHeightVp > 0 ? this.viewportHeightVp : 780;
  }

  // 卡片高度估算（定位用）：头部（有链接文字时多一行）+ 分隔线 + 每项
  // 48 + 底部留 6。与渲染保持一致即可，误差几 vp 无碍——定位有夹取。
  private contextMenuCardHeightVp(model: ContextMenuModel): number {
    const header: number = model.subtitle.length > 0 ? 61 : 42;
    const rows: number = model.items.length + (model.systemPaste ? 1 : 0);
    return header + 1 + rows * 48 + 6;
  }

  private contextMenuListMaxHeightVp(model: ContextMenuModel): number {
    const header: number = model.subtitle.length > 0 ? 61 : 42;
    return Math.max(96, this.deviceHeightVp() * 0.56 - header - 7);
  }

  private contextMenuPosition(model: ContextMenuModel): Position {
    const screenW: number = this.deviceWidthVp();
    const screenH: number = this.deviceHeightVp();
    const cardW: number = CONTEXT_MENU_CARD_WIDTH_VP;
    const maxCardH: number = Math.max(160, screenH * 0.56);
    const cardH: number = Math.min(this.contextMenuCardHeightVp(model), maxCardH);
    const margin: number = 12;
    let left: number = model.x - 14;
    left = Math.min(Math.max(left, margin), Math.max(margin, screenW - cardW - margin));
    // 优先弹在按压点下方；下方放不下翻到上方；再夹进安全区。
    let top: number = model.y + 14;
    if (top + cardH > screenH - margin) {
      top = model.y - 14 - cardH;
    }
    const minTop: number = Math.max(this.topSafeVp + 8, margin);
    top = Math.min(Math.max(top, minTop), Math.max(minTop, screenH - cardH - margin));
    return { x: left, y: top };
  }

  @Builder
  private ContextMenuLayer() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 一张透明点击层：点到卡片外面就收起来（⋮ 菜单卡同款做法）。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onClick((): void => {
          this.dismissContextMenu();
        })

      this.ContextMenuCard(this.contextMenuModelOrDefault())
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private ContextMenuCard(model: ContextMenuModel) {
    Column() {
      Column({ space: 2 }) {
        Text(model.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (model.subtitle.length > 0) {
          Text(model.subtitle)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 18, right: 16, top: 12, bottom: 10 })

      Divider()
        .color($r('app.color.divider'))
        .margin({ left: 18, right: 0 })

      Scroll() {
        Column() {
          ForEach(model.items, (item: ContextMenuItem): void => {
            this.ContextMenuRow(item.label, (): void => {
              this.chooseContextMenuAction(model, item.action);
            })
          }, (item: ContextMenuItem): string => item.action)
          if (model.systemPaste) {
            this.ContextMenuRow('粘贴', (): void => {
              this.pasteFromContextMenu(model);
            })
          }
        }
        .width('100%')
        .padding({ bottom: 6 })
      }
      .width('100%')
      .constraintSize({ maxHeight: this.contextMenuListMaxHeightVp(model) })
      // 血泪：Scroll 默认垂直居中，内容不满时必须显式 TopStart。
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
    }
    .width(CONTEXT_MENU_CARD_WIDTH_VP)
    .borderRadius(22)
    .backgroundColor($r('app.color.surface_floating'))
    .shadow({ radius: 26, color: $r('app.color.shadow'), offsetY: 8 })
    .clip(true)
    .position(this.contextMenuPosition(model))
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.opacity(0)
        .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 })),
      TransitionEffect.opacity(0)
    ).animation({ duration: 180, curve: Curve.Friction }))
  }

  @Builder
  private ContextMenuRow(label: string, action: () => void) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height(48)
    .padding({ left: 18, right: 16 })
    .onClick(action)
  }

  private closeFindBar(): void {
    this.findVisible = false;
    this.findQuery = '';
    this.issueCommand({ command: 'stopFind' });
  }

  private findNext(forward: boolean): void {
    if (this.findQuery.trim().length === 0) {
      return;
    }
    this.issueCommand({ command: 'findInPage', text: this.findQuery, forward: forward });
  }

  private toggleBookmark(): void {
    const url = this.browserState.url;
    if (url.length === 0 || this.isNewTabUrl(url)) {
      return;
    }
    this.issueCommand({
      command: 'addBookmark',
      url: url,
      title: this.browserState.title && this.browserState.title.length > 0 ?
        this.browserState.title : this.displayDomain()
    });
    this.menuCardVisible = false;
    this.getUIContext().getPromptAction().showToast({ message: '已加入书签', duration: 2000 });
  }

  private findMatches(): number {
    try {
      const data = JSON.parse(this.findResultJson) as FindResultSummary;
      return data.matches ?? 0;
    } catch (error) {
      return 0;
    }
  }

  private findActiveMatch(): number {
    try {
      const data = JSON.parse(this.findResultJson) as FindResultSummary;
      return data.activeMatch ?? 0;
    } catch (error) {
      return 0;
    }
  }

  build() {
    Stack() {
      Column() {
        // The home surface (new tab) already carries a search box; the
        // address bar would duplicate it right above, so it only shows
        // while browsing actual pages.
        if (!this.isNewTabUrl(this.browserState.url)) {
          this.TopAddressBar()
        }
        this.BottomDock()
      }
      .width('100%')
      .height('100%')
      // On the home surface only the dock remains; SpaceBetween with a
      // single child pins it to the START (top), so pin to END there.
      // The floating bars carry their own safe-area padding, so this layer
      // carries none of its own.
      .justifyContent(this.isNewTabUrl(this.browserState.url) ?
        FlexAlign.End : FlexAlign.SpaceBetween)
      .hitTestBehavior(HitTestMode.Transparent)
      .bindSheet($$this.menuVisible, this.MenuSheet, {
        height: SheetSize.LARGE,
        showClose: false,
        enableOutsideInteractive: false,
        maskColor: Color.Transparent
      })

      if (this.panelPage !== 'none') {
        this.PanelLayer()
      }

      // 页内查找 bar sits under the status area, above everything else.
      if (this.findVisible) {
        this.FindBar()
      }

      // ⋮ 菜单：一块悬浮卡片贴在 dock 上方靠右。Lumie 不铺遮罩，这里也只留
      // 一层透明点击层，点到卡片外面就收起来。
      if (this.menuCardVisible) {
        Stack({ alignContent: Alignment.BottomEnd }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              this.closeMenuCard();
            })

          this.MenuCard()
        }
        .width('100%')
        .height('100%')
      }

      // 长按菜单（v13）：贴着按压点弹的自绘卡片；点卡片外 / 按返回收起来。
      // 数据来自 AuraShell 写进 AppStorage 的 ContextMenuModel。
      if (this.contextMenuJson.length > 0) {
        this.ContextMenuLayer()
      }
    }
    .width('100%')
    .height('100%')
    // 视口高度（vp）：dock 条带的响应区以它为底边基准。首次布局即上报，
    // 转屏 / 窗口变化时更新。
    .onAreaChange((_old: Area, next: Area): void => {
      const measured: number = Number(next.height);
      if (Number.isFinite(measured) && measured > 0 &&
          Math.abs(measured - this.viewportHeightVp) > 0.5) {
        this.viewportHeightVp = measured;
      }
    })
    // 命中契约（2026-10-09，修复「点 dock / 顶栏按钮穿透到网页」）：
    // 引擎按"命中子节点自身的 hitTestMode"决定是否继续测试下层兄弟
    // （frame_node.cpp → CheckChildHitTestResult / BUBBLING 分支）。本节点若为
    // Transparent，命中任何子节点的触摸都会继续下发到 WebWindow（点穿）；
    // 恒 Default 又会整屏阻断网页。正解 = Default + responseRegion 把根节点
    // 的响应区收缩为两条 bars 条带（随收起比例收缩）：条带内命中即阻断，
    // 条带外整棵 overlay 判 OUT_OF_REGION（子树里只有 Transparent 的全屏
    // 布局容器，消费不会传导上来），触摸正常落到网页。
    .responseRegion(this.buildChromeTouchRegions())
    .hitTestBehavior(this.resolveChromeHitTestMode())
  }

  // 悬浮 chrome 的「可交互条带」（响应区）：只有顶栏 / dock 真正占据的条区
  // 参与阻断。条带高度随收起比例收缩（与各自 translate 行程一致），完全
  // 收起时不占区域——收起后那一带照常可点。空数组被引擎回退为"整节点
  // 矩形"，因此只会与 Transparent 组合出现（行为与旧实现一致）。
  private buildChromeTouchRegions(): Array<Rectangle> {
    const regions: Array<Rectangle> = [];
    // 模态层（七页面板 / ⋮ 悬浮菜单卡 / 长按菜单）在场：整屏归它，直接
    // 全屏响应区，顺带把网页挡在后面（菜单卡点外收起时不再误点页面）。
    if (this.panelPage !== 'none' || this.menuCardVisible || this.contextMenuJson.length > 0) {
      const full: Rectangle = { x: 0, y: 0, width: '100%', height: '100%' };
      regions.push(full);
      return regions;
    }
    const ratio: number = Number.isFinite(this.controlsRatioRaw) ?
      Math.min(Math.max(this.controlsRatioRaw, 0), 1) : 1;
    // 顶栏条带：新标签页没有顶栏，不占（否则首页顶部会出现一条死区）。
    if (!this.isNewTabUrl(this.browserState.url)) {
      const topShown: number = ratio * (TOP_BAR_EXTENT_VP + this.topSafeVp);
      if (topShown > 0.5) {
        const top: Rectangle = { x: 0, y: 0, width: '100%', height: topShown };
        regions.push(top);
      }
    }
    // dock 条带：底边贴视口底，高度 = 收起比例 × 全高。
    if (this.viewportHeightVp > 0) {
      const dockShown: number = ratio * (BOTTOM_DOCK_EXTENT_VP + resolveDockBottomMarginVp(this.bottomSafeVp));
      if (dockShown > 0.5 && dockShown < this.viewportHeightVp) {
        const dock: Rectangle = {
          x: 0,
          y: this.viewportHeightVp - dockShown,
          width: '100%',
          height: dockShown
        };
        regions.push(dock);
      }
    }
    return regions;
  }

  // 根命中模式：模态层（七页面板 / ⋮ 菜单卡 / 长按菜单）在场 → Default +
  // 全屏响应区，整屏阻断、交给模态层自身处理点击；正常浏览 → Transparent，
  // 页面区直达 XComponent（消除 dock/顶栏全宽条带矩形对滑动起始段的拦截——
  // 修复"手指滑出一段页面才滚"），dock/顶栏的按钮、地址栏等控件自身是
  // Default 子节点，仍正常拦截点击。
  private resolveChromeHitTestMode(): HitTestMode {
    const modal: boolean = this.panelPage !== 'none' ||
      this.menuCardVisible || this.contextMenuJson.length > 0;
    return modal ? HitTestMode.Default : HitTestMode.Transparent;
  }

  @Builder
  private EdgeButton(action: MobileEdgeAction) {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      Image(action === MobileEdgeAction.BACK ?
        $r('app.media.chromium_back') : $r('app.media.chromium_more'))
        .width(24)
        .height(24)
        .fillColor($r('app.color.icon_primary'))
    }
    .width(52)
    .height(52)
    .backgroundColor($r('app.color.surface_floating'))
    .shadow({ radius: 16, color: $r('app.color.shadow'), offsetY: 4 })
    .visualEffect(this.buildBubbleEffect())
    .opacity(action === MobileEdgeAction.BACK && !this.browserState.canGoBack ? 0.52 : 1)
    .enabled(action !== MobileEdgeAction.BACK || this.browserState.canGoBack)
    .accessibilityText(action === MobileEdgeAction.BACK ? '返回' : '菜单')
    .onClick(() => this.handleEdgeAction(action))
  }

  // 悬浮地址胶囊：只有「胶囊 + 扩展圆钮」两块玻璃，周围留边、悬浮在页面上，
  // 没有通宽色带（色带会把胶囊和屏幕边连成一条，不再是悬浮动画）。
  // 材质用 glass_tint 半透明纯色：网页走 SURFACE 独立图层，模糊采不到它的内容，
  // 契约 §8 明确"网页上方不要叠模糊控件"，所以不用 backgroundBlurStyle。
  // 条区总高 = 引擎通过 setBrowserControls top 保留的高度
  // （TOP_BAR_EXTENT_VP + 顶部安全区），页面顶边从条区下沿开始。
  @Builder
  private TopAddressBar() {
    Row({ space: 8 }) {
      // Main pill: back chevron + lock + URL + reload, like the reference
      // browser's single-capsule address bar.
      Row() {
        this.TopBarContent()
      }
      .layoutWeight(1)
      .height(44)
      .borderRadius(22)
      .backgroundColor($r('app.color.glass_tint'))
      .border({ width: 0.5, color: $r('app.color.divider') })
      .shadow({ radius: 16, color: $r('app.color.shadow'), offsetY: 4 })

      // 右上角圆形「扩展」按钮：点击进入扩展管理页（扫一扫仍保留在首页搜索框内）。
      if (!this.editingAddress) {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          Image($r('app.media.chromium_extensions'))
            .width(22)
            .height(22)
            .fillColor($r('app.color.icon_primary'))
        }
        .width(44)
        .height(44)
        .backgroundColor($r('app.color.glass_tint'))
        .border({ width: 0.5, color: $r('app.color.divider') })
        .shadow({ radius: 16, color: $r('app.color.shadow'), offsetY: 4 })
        .accessibilityText('扩展')
        .onClick(() => {
          this.openPanel('extensions');
        })
      }
    }
    .width('100%')
    .padding({ top: this.topSafeVp + 8, left: 16, right: 16 })
    // 行程必须覆盖"顶部安全区内边距 + 条高"，否则 ratio 到 0 时条底仍卡在安全区
    // 高度处，露出一条缝（用户看到的"贴边还看得见"）。
    .translate({ y: -(1 - this.controlsRatioRaw) * (TOP_BAR_EXTENT_VP + this.topSafeVp) })
  }

  @Builder
  private TopBarContent() {
      if (this.editingAddress) {
        TextInput({ text: this.addressDraft, placeholder: '搜索或输入网址',
          controller: this.addressController })
          .id('mobile_address_input')
          .layoutWeight(1)
          .height(44)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_secondary'))
          .backgroundColor(Color.Transparent)
          .padding({ left: 16, right: 12 })
          .enterKeyType(EnterKeyType.Go)
          .selectAll(true)
          .onChange((value: string) => {
            this.addressDraft = value;
          })
          .onTextSelectionChange((start: number, end: number): void => {
            this.addressSelectionStart = start;
            this.addressSelectionEnd = end;
          })
          .onSubmit(() => {
            this.submitAddress();
          })
        Button('粘贴')
          .fontSize(14)
          .onClick((): void => this.pasteAddress())
        Button({ type: ButtonType.Circle }) {
          Image($r('app.media.chromium_close'))
            .width(20)
            .height(20)
            .fillColor($r('app.color.icon_secondary'))
        }
        .width(36)
        .height(36)
        .margin({ right: 5 })
        .backgroundColor(Color.Transparent)
        .accessibilityText('取消编辑')
        .onClick(() => {
          this.clearKeyboardRecoveryTimers();
          this.editingAddress = false;
          this.issueCommand({ command: 'setBrowserControlsState', state: 'both' });
        })
      } else {
        // Back chevron inside the bar, dimmed when there is nowhere to go.
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          Image($r('app.media.chromium_back'))
            .width(20)
            .height(20)
            .fillColor($r('app.color.icon_primary'))
        }
        .width(34)
        .height(34)
        .margin({ left: 3 })
        .backgroundColor(Color.Transparent)
        .opacity(this.browserState.canGoBack ? 1 : 0.4)
        .enabled(this.browserState.canGoBack)
        .accessibilityText('返回')
        .onClick(() => {
          this.issueCommand({ command: 'back' });
        })

        Button({ type: ButtonType.Normal, stateEffect: true }) {
          Row({ space: 6 }) {
            if (this.browserState.loading) {
              LoadingProgress()
                .width(16)
                .height(16)
                .color($r('app.color.accent_primary'))
            } else {
              Image($r('app.media.aura_lock'))
                .width(14)
                .height(14)
                .fillColor($r('app.color.icon_secondary'))
            }
            if (this.incognito) {
              Text('无痕')
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(6)
                .backgroundColor($r('app.color.surface_secondary'))
            }
            Text(this.displayDomain())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .textAlign(TextAlign.Start)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .height(44)
        .padding({ left: 6, right: 6 })
        .backgroundColor(Color.Transparent)
        .accessibilityText('地址栏')
        .onClick(() => this.beginAddressEdit())

        Button({ type: ButtonType.Circle, stateEffect: true }) {
          Image(this.browserState.loading ?
            $r('app.media.chromium_close') : $r('app.media.chromium_reload'))
            .width(20)
            .height(20)
            .fillColor($r('app.color.icon_primary'))
        }
        .width(38)
        .height(38)
        .margin({ right: 3 })
        .backgroundColor(Color.Transparent)
        .accessibilityText(this.browserState.loading ? '停止' : '刷新')
        .onClick(() => {
          this.issueCommand({ command: this.browserState.loading ? 'stop' : 'reload' });
        })
      }
  }

  // 底部 dock：一块悬浮玻璃横条——左右各留 16vp、完整圆角，网页从它后面
  // 穿过，跟手收起。玻璃走 HDS（HDS 没有 uiMaterial 的 Navigation/TabBar
  // 作用域限制，与 Lumie 的 dock 同一条路，详见 DockMaterialPlate）；
  // 拿不到材质时回退半透明纯色玻璃（契约 §8：网页上方不用模糊）。引擎不给
  // dock 保留网页空间（setBrowserControls bottom = 0），网页一直画到窗口底。
  //
  // 布局（v9，结构对齐 Lumie）：材质板铺满整层（含顶部 12vp 呼吸位与底部
  // 安全区），五个按钮作为 HdsTabs 的真实 tabBar 项渲染在浮动胶囊里——
  // 材质、按钮、触摸同在一棵子树内，材质几何随内容收敛、触摸也能被材质
  // 感知（Lumie 同构）。无材质设备走同一胶囊几何的自绘玻璃。
  @Builder
  private BottomDock() {
    Stack() {
      if (this.dockMaterialActive) {
        DockMaterialPlate({
          canGoBack: this.browserState.canGoBack,
          canGoForward: this.browserState.canGoForward,
          tabCount: this.browserState.tabCount,
          barWidthVp: resolveDockBarWidthVp(),
          barHeightVp: DOCK_BAR_HEIGHT_VP,
          sideMarginVp: 16,
          bottomMarginVp: resolveDockBottomMarginVp(this.bottomSafeVp),
          onDockSlot: (slot: string): void => {
            this.handleDockSlot(slot);
          }
        })
      } else {
        // 保底路径（无材质设备）：同一胶囊几何，半透明纯色玻璃 + 按钮行。
        Column() {
          Row() {
            this.BottomDockContent()
          }
          .width('100%')
          .height(DOCK_BAR_HEIGHT_VP)
          .borderRadius(DOCK_BAR_RADIUS_VP)
          .backgroundColor($r('app.color.glass_tint'))
          .border({ width: 0.5, color: $r('app.color.divider') })
          .shadow({ radius: 16, color: $r('app.color.shadow'), offsetY: 4 })
          // System point-light press effect (HDS hdsEffect, API 20+, every
          // device): a soft light spot under the finger that follows it
          // across the bar.
          .visualEffect(this.buildDockLightEffect())
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .padding({ top: 12, left: 16, right: 16, bottom: resolveDockBottomMarginVp(this.bottomSafeVp) })
      }
    }
    .width('100%')
    .height(BOTTOM_DOCK_EXTENT_VP + resolveDockBottomMarginVp(this.bottomSafeVp))
    // 同顶栏：行程要含 dock 的底距（原始安全区），否则 ratio→0 时 dock
    // 仍留一条缝。
    .translate({ y: (1 - this.controlsRatioRaw) * (BOTTOM_DOCK_EXTENT_VP + resolveDockBottomMarginVp(this.bottomSafeVp)) })
  }

  // dock 一个按钮的语义动作——材质路径由 HdsTabs 的 onTabBarClick 分发到
  // 这里；保底路径的按钮仍直连各自的 onClick。禁用态在两边都做守卫。
  private handleDockSlot(slot: string): void {
    if (slot === '返回') {
      if (this.browserState.canGoBack) {
        this.issueCommand({ command: 'back' });
      }
    } else if (slot === '前进') {
      if (this.browserState.canGoForward) {
        this.issueCommand({ command: 'forward' });
      }
    } else if (slot === '主页') {
      this.issueCommand({ command: 'home' });
    } else if (slot === '标签页') {
      this.requestTabThumbnails();
      this.menuVisible = true;
    } else if (slot === '菜单') {
      this.menuCardVisible = true;
    }
  }

  private buildDockLightEffect(): VisualEffect {
    return new hdsEffect.HdsEffectBuilder()
      .pointLight({
        sourceType: hdsEffect.PointLightSourceType.SOFT,
        illuminatedType: hdsEffect.PointLightIlluminatedType.CONTENT
      })
      .buildEffect();
  }

  @Builder
  private BottomDockContent() {
      this.DockButton($r('app.media.chromium_back'), '返回', this.browserState.canGoBack,
        (): void => {
          this.issueCommand({ command: 'back' });
        })
      this.DockButton($r('app.media.chromium_forward'), '前进', this.browserState.canGoForward,
        (): void => {
          this.issueCommand({ command: 'forward' });
        })
      // 'home' is the engine's own command for chrome://newtab (also what the
      // keyboard's home key maps to), so the tab lands on the shell's home
      // surface without pushing a duplicate of the current URL.
      this.DockButton($r('app.media.chromium_home'), '主页', true,
        (): void => {
          this.issueCommand({ command: 'home' });
        })

      Button({ type: ButtonType.Normal, stateEffect: true }) {
        // 去字后只剩计数徽标。
        Text(this.browserState.tabCount > 99 ? '99+' : this.browserState.tabCount.toString())
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.icon_primary'))
          .textAlign(TextAlign.Center)
          .width(22)
          .height(20)
          .borderRadius(6)
          .border({ width: 1.8, color: $r('app.color.icon_primary') })
      }
      .layoutWeight(1)
      .height(DOCK_BAR_HEIGHT_VP)
      .backgroundColor(Color.Transparent)
      .scale({ x: this.pressedDock === '标签页' ? 0.82 : 1, y: this.pressedDock === '标签页' ? 0.82 : 1 })
      .accessibilityText('标签页')
      .onTouch((event: TouchEvent): void => {
        this.handleDockTouch(event, '标签页');
      })
      .onClick((): void => {
        this.requestTabThumbnails();
        this.menuVisible = true;
      })

      this.DockButton($r('app.media.chromium_more'), '菜单', true,
        (): void => {
          this.menuCardVisible = true;
        })
  }

  @Builder
  private DockButton(icon: Resource, label: string, usable: boolean, action: () => void) {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      // 图标即内容（2026-10-09：dock 去字）；label 只留作无障碍名和按压键。
      Image(icon)
        .width(22)
        .height(22)
        .fillColor($r('app.color.icon_primary'))
    }
    .layoutWeight(1)
    .height(DOCK_BAR_HEIGHT_VP)
    .backgroundColor(Color.Transparent)
    .opacity(usable ? 1 : 0.4)
    .enabled(usable)
    .scale({ x: this.pressedDock === label ? 0.82 : 1, y: this.pressedDock === label ? 0.82 : 1 })
    .accessibilityText(label)
    .onTouch((event: TouchEvent): void => {
      this.handleDockTouch(event, label);
    })
    .onClick(action)
  }

  // Press -> quick shrink; release -> under-damped spring back, the
  // "jelly" gravity-motion feel. Hand-rolled on purpose: the system
  // interactive material never applies to free-floating bars.
  private handleDockTouch(event: TouchEvent, label: string): void {
    if (event.type === TouchType.Down) {
      animateTo({ duration: 90, curve: Curve.FastOutSlowIn }, (): void => {
        this.pressedDock = label;
      });
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      animateTo({ curve: curves.springMotion(0.3, 0.7) }, (): void => {
        this.pressedDock = '';
      });
    }
  }

  @Builder
  private MenuSheet() {
    Column() {
      this.TabsView()
    }
    .width('100%')
    .height('100%')
    // Transparent on purpose: with the app-level UIMaterial switch enabled
    // (module.json5, target API 26+), bindSheet draws its own ULTRA_THICK
    // system material behind this content -- a solid fill here would hide
    // it. See UI-DESIGN-SPEC.md section 8.5.
    .backgroundColor(Color.Transparent)
  }

  // The shell's own pages (bookmarks / history / downloads / settings /
  // extensions) are full-screen pages, like Lumie's — no sheet around them,
  // which also removes the sheet's top gap on those pages.
  @Builder
  private PanelLayer() {
    Column() {
      if (this.panelPage === 'bookmarks') {
        BookmarksPanel({
          currentUrl: this.browserState.url,
          currentTitle: this.browserState.title,
          onCommand: (command: BrowserCommandPayload): void => {
            this.issueCommand(command);
          },
          onBack: (): void => {
            this.closePanel();
          },
          onClose: (): void => {
            this.closePanel();
          }
        })
      } else if (this.panelPage === 'history') {
        HistoryPanel({
          onCommand: (command: BrowserCommandPayload): void => {
            this.issueCommand(command);
          },
          onBack: (): void => {
            this.closePanel();
          },
          onClose: (): void => {
            this.closePanel();
          }
        })
      } else if (this.panelPage === 'downloads') {
        DownloadsPanel({
          onCommand: (command: BrowserCommandPayload): void => {
            this.issueCommand(command);
          },
          onBack: (): void => {
            this.closePanel();
          },
          onClose: (): void => {
            this.closePanel();
          }
        })
      } else if (this.panelPage === 'recent') {
        RecentPanel({
          onCommand: (command: BrowserCommandPayload): void => {
            this.issueCommand(command);
          },
          onBack: (): void => {
            this.closePanel();
          },
          onClose: (): void => {
            this.closePanel();
          }
        })
      } else if (this.panelPage === 'passwords') {
        PasswordsPanel({
          onCommand: (command: BrowserCommandPayload): void => {
            this.issueCommand(command);
          },
          onBack: (): void => {
            this.panelPage = 'settings';
          },
          onClose: (): void => {
            this.closePanel();
          }
        })
      } else if (this.panelPage === 'sitepermissions') {
        SitePermissionsPanel({
          onCommand: (command: BrowserCommandPayload): void => {
            this.issueCommand(command);
          },
          onBack: (): void => {
            this.panelPage = 'settings';
          },
          onClose: (): void => {
            this.closePanel();
          }
        })
      } else if (this.panelPage === 'settings') {
        SettingsPanel({
          onCommand: (command: BrowserCommandPayload): void => {
            this.issueCommand(command);
          },
          onBack: (): void => {
            this.closePanel();
          },
          onOpenExtensions: (): void => {
            this.extensionsFromSettings = true;
            this.panelPage = 'extensions';
          },
          onOpenSitePermissions: (): void => {
            this.panelPage = 'sitepermissions';
          },
          onOpenPasswords: (): void => {
            this.panelPage = 'passwords';
          }
        })
      } else if (this.panelPage === 'extensions') {
        ExtensionPanel({
          currentUrl: this.browserState.url,
          onCommand: (command: BrowserCommandPayload): void => {
            this.issueCommand(command);
          },
          onBack: (): void => {
            if (this.extensionsFromSettings) {
              this.extensionsFromSettings = false;
              this.panelPage = 'settings';
            } else {
              this.closePanel();
            }
          },
          onClose: (): void => {
            this.closePanel();
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: 8 + this.topSafeVp, bottom: this.bottomSafeVp })
    .backgroundColor($r('app.color.surface_primary'))
    // Motion: a shell page slides in from the right and fades back out, so
    // opening and closing a page reads as navigation.
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.opacity(0)
        .combine(TransitionEffect.translate({ x: '16%' })),
      TransitionEffect.opacity(0)
    ).animation({ duration: 240, curve: Curve.Friction }))
  }

  @Builder
  private TabsView() {
    Column() {
      Row() {
        Text(`${this.browserState.tabCount} 个标签`)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
      }
      .width('100%')
      .height(52)

      Grid() {
        ForEach(this.browserState.tabs, (tab: BrowserTabState) => {
          GridItem() {
            Column() {
              Row() {
                Text(tab.title && tab.title.length > 0 ? tab.title : '新标签页')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontSize(13)
                  .fontWeight(tab.active ? FontWeight.Medium : FontWeight.Regular)
                  .fontColor(tab.active ?
                    $r('app.color.accent_primary') : $r('app.color.text_primary'))
                  .layoutWeight(1)
                Button({ type: ButtonType.Circle }) {
                  Image($r('app.media.chromium_close'))
                    .width(16)
                    .height(16)
                    .fillColor($r('app.color.icon_secondary'))
                }
                .width(30)
                .height(30)
                .backgroundColor(Color.Transparent)
                .accessibilityText('关闭标签页')
                .onClick(() => {
                  this.issueCommand({ command: 'closeTab', index: tab.index });
                })
              }
              .width('100%')
              .height(36)
              .padding({ left: 10, right: 4 })

              Stack() {
                if (this.thumbnailFor(tab).length > 0) {
                  Image(this.thumbnailFor(tab))
                    .objectFit(ImageFit.Cover)
                } else {
                  // 没抓到快照（后台标签被回收等）：别把整条 URL 糊上来，
                  // 用页面标题占位更可读。
                  Text(tab.title.length > 0 ? tab.title : this.shortUrl(tab.url))
                    .fontSize(13)
                    .fontColor($r('app.color.text_secondary'))
                    .textAlign(TextAlign.Center)
                    .maxLines(3)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .padding(10)
                }
              }
              .width('100%')
              .layoutWeight(1)
              .backgroundColor($r('app.color.surface_secondary'))
            }
            .width('100%')
            .height(208)
            .clip(true)
            .borderRadius(14)
            .border({
              width: tab.active ? 2 : 0.5,
              color: tab.active ? $r('app.color.accent_primary') : $r('app.color.divider')
            })
            .backgroundColor($r('app.color.surface_primary'))
            .onClick(() => {
              // Switch first, then dismiss: the reader expects to land on
              // the page they tapped, with the sheet gone.
              this.issueCommand({ command: 'activateTab', index: tab.index });
              this.closeMenuSheet();
            })
          }
        }, (tab: BrowserTabState): string => tab.index.toString())
      }
      .columnsTemplate('1fr 1fr')
      .columnsGap(10)
      .rowsGap(10)
      .width('100%')
      .layoutWeight(1)
      .onAreaChange((_oldArea: Area, newArea: Area): void => {
        this.measureTabGrid(newArea);
      })

      Row({ space: 10 }) {
        Button('新建标签页')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_accent'))
          .backgroundColor($r('app.color.accent_primary'))
          .borderRadius(22)
          .onClick(() => {
            this.closeMenuSheet();
            this.issueCommand({ command: 'newTab' });
          })
        Button('完成')
          .height(44)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.surface_secondary'))
          .borderRadius(22)
          .padding({ left: 24, right: 24 })
          .onClick(() => {
            this.closeMenuSheet();
          })
      }
      .width('100%')
      .margin({ top: 10 })

      Row() {
        Text('最近关闭的标签页')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
        Blank()
        Text('›')
          .fontSize(16)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .height(40)
      .onClick(() => {
        this.openPanel('recent');
      })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 16 })
    // Transparent: the bindSheet's system material (ULTRA_THICK under the
    // app-level ENABLE switch) must show through -- a solid fill here
    // covered it entirely. See UI-DESIGN-SPEC.md section 8.3.
    .backgroundColor(Color.Transparent)
  }

  // ⋮ 菜单：Lumie 那块悬浮卡片的样子。不铺遮罩（只留一层透明点击层收卡片），
  // 卡片贴在 dock 上方、靠右；第一行是"域名 · 连接安全"，然后是页面操作，
  // 再一组是无痕与桌面版，最后一行四个入口。**主页上没有页面可操作，页面类
  // 的项一律不出现**，只剩无痕与入口行。每一项点完立即关卡片。
  @Builder
  private MenuCard() {
    Column() {
      if (!this.isHomeSurface()) {
        this.MenuHeader()
        this.MenuSeparator()
      }

      if (!this.isHomeSurface()) {
        // 引擎的状态里没有"当前页是否已收藏"这项（native 有 bookmarked，
        // 但 HAR 的 BrowserStateSnapshot 还没声明），所以这一项只做加入。
        this.MenuItem($r('app.media.chromium_bookmark'), '加入书签', '',
          (): void => {
            this.closeMenuCard();
            this.toggleBookmark();
          })
        if (this.browserState.readerModeAvailable === true) {
          this.MenuItem($r('app.media.aura_reader'), '阅读模式',
            this.browserState.inReaderMode === true ? '开' : '', (): void => {
              this.closeMenuCard();
              this.issueCommand({ command: 'toggleReaderMode' });
            })
        }
        this.MenuItem($r('app.media.chromium_share'), '分享 / 发送到我的设备', '', (): void => {
          this.closeMenuCard();
          this.shareCurrentPage();
        })
        this.MenuItem($r('app.media.chromium_search'), '在页面中查找', '', (): void => {
          this.closeMenuCard();
          this.findVisible = true;
        })
        this.MenuItem($r('app.media.chromium_print'), '打印', '', (): void => {
          this.closeMenuCard();
          this.issueCommand({ command: 'print' });
        })
        this.MenuSeparator()
      }

      if (this.incognito) {
        this.MenuItem($r('app.media.aura_incognito'), '退出无痕', '', (): void => {
          this.closeMenuCard();
          this.leaveIncognito();
        })
      } else {
        this.MenuItem($r('app.media.aura_incognito'), '新建无痕标签页', '', (): void => {
          this.closeMenuCard();
          this.enterIncognito();
        })
      }
      if (!this.isHomeSurface()) {
        this.MenuItem($r('app.media.aura_desktop'), '桌面版网站',
          this.browserState.requestDesktopSite === true ? '开' : '', (): void => {
            this.closeMenuCard();
            this.toggleDesktopSite();
          })
      }

      this.MenuSeparator()

      Row({ space: 8 }) {
        this.PanelEntryButton('书签', $r('app.media.chromium_bookmark'), (): void => {
          this.openPanel('bookmarks');
        })
        this.PanelEntryButton('历史', $r('app.media.chromium_history'), (): void => {
          this.openPanel('history');
        })
        this.PanelEntryButton('下载', $r('app.media.chromium_download'), (): void => {
          this.openPanel('downloads');
        })
        this.PanelEntryButton('设置', $r('app.media.chromium_settings'), (): void => {
          this.openPanel('settings');
        })
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 10, bottom: 12 })
    }
    .width(MENU_CARD_WIDTH_VP)
    .borderRadius(22)
    .backgroundColor($r('app.color.surface_floating'))
    .shadow({ radius: 26, color: $r('app.color.shadow'), offsetY: 8 })
    .margin({ right: 14, bottom: 82 + this.bottomSafeVp })
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.opacity(0)
        .combine(TransitionEffect.translate({ y: 24 }))
        .combine(TransitionEffect.scale({ x: 0.97, y: 0.97 })),
      TransitionEffect.opacity(0)
    ).animation({ duration: 200, curve: Curve.Friction }))
  }

  // 第一行：连接状态。锁形图标 + 域名 + " · 连接安全/不安全"，与 Lumie 一致。
  @Builder
  private MenuHeader() {
    Row({ space: 10 }) {
      Image($r('app.media.aura_lock'))
        .width(18)
        .height(18)
        .fillColor(this.isConnectionSecure() ?
          $r('app.color.text_primary') : $r('app.color.icon_secondary'))
      Text(this.isConnectionSecure() ?
        `${this.menuDomainText()} · 连接安全` : `${this.menuDomainText()} · 不安全`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height(44)
    .padding({ left: 18, right: 16 })
  }

  @Builder
  private MenuSeparator() {
    Divider()
      .color($r('app.color.divider'))
      .margin({ left: 18, right: 0 })
  }

  private isConnectionSecure(): boolean {
    return this.browserState.url.startsWith('https://');
  }

  private isHomeSurface(): boolean {
    return this.isNewTabUrl(this.browserState.url);
  }

  private menuDomainText(): string {
    if (this.isHomeSurface()) {
      return '新标签页';
    }
    return this.displayDomain();
  }

  // 一项菜单：图标 + 文字 +（可选的）右侧"开"。整行都可点。
  @Builder
  private MenuItem(icon: Resource, label: string, trailing: string, action: () => void) {
    Row({ space: 14 }) {
      Image(icon)
        .width(21)
        .height(21)
        .fillColor($r('app.color.icon_primary'))
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
      Blank()
      if (trailing.length > 0) {
        Text(trailing)
          .fontSize(13)
          .fontColor($r('app.color.accent_primary'))
      }
    }
    .width('100%')
    .height(48)
    .padding({ left: 18, right: 16 })
    .onClick(action)
  }

  // 进无痕：手机上没有第二个渲染进程可用，先把标签存下来再用另一个 profile
  // 重启应用（引擎据此换一整套用户数据目录）。存不下就不进，免得回来时标签
  // 全丢——Lumie 也是这个取舍。
  private async enterIncognito(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    const saved: SavedTab[] = [];
    for (const tab of this.browserState.tabs) {
      if (tab.url && tab.url.length > 0 && !this.isNewTabUrl(tab.url)) {
        saved.push({ url: tab.url, title: tab.title ?? '' });
      }
    }
    const ok = await IncognitoSwitch.saveTabs(context, saved);
    if (!ok) {
      this.getUIContext().getPromptAction().showToast({ message: '保存标签失败，已取消进入无痕', duration: 2500 });
      return;
    }
    IncognitoSwitch.restart(context, true, '');
  }

  // 退出无痕：重启回普通 profile；无痕那套目录由 EntryAbility 在普通启动时
  // 整个删掉（IncognitoSwitch.sweepIncognitoProfile）。
  private leaveIncognito(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    IncognitoSwitch.restart(context, false, '');
  }

  // 桌面版网站是每个标签自己的状态，读 requestDesktopSite 再取反。
  private toggleDesktopSite(): void {
    if (this.isHomeSurface()) {
      return;
    }
    const enabled = !(this.browserState.requestDesktopSite === true);
    this.issueCommand({ command: 'setRequestDesktopSite', enabled: enabled });
    this.getUIContext().getPromptAction().showToast({
      message: enabled ? '已请求桌面版网站' : '已回到移动版网站',
      duration: 2000
    });
  }

  @Builder
  private FindBar() {
    Row({ space: 8 }) {
      TextInput({ text: this.findQuery, placeholder: '在页面中查找' })
        .layoutWeight(1)
        .height(40)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_secondary'))
        .backgroundColor(Color.Transparent)
        .enterKeyType(EnterKeyType.Done)
        .onChange((value: string) => {
          this.findQuery = value;
          if (value.trim().length > 0) {
            this.issueCommand({ command: 'findInPage', text: value });
          }
        })
        .onSubmit(() => {
          this.findNext(true);
        })

      Text(this.findMatches() > 0 ? `${this.findActiveMatch()}/${this.findMatches()}` : '')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))

      Button({ type: ButtonType.Circle }) {
        Text('↑')
          .fontSize(16)
          .fontColor($r('app.color.icon_primary'))
      }
      .width(34)
      .height(34)
      .backgroundColor(Color.Transparent)
      .accessibilityText('上一个')
      .onClick(() => {
        this.findNext(false);
      })

      Button({ type: ButtonType.Circle }) {
        Text('↓')
          .fontSize(16)
          .fontColor($r('app.color.icon_primary'))
      }
      .width(34)
      .height(34)
      .backgroundColor(Color.Transparent)
      .accessibilityText('下一个')
      .onClick(() => {
        this.findNext(true);
      })

      Button({ type: ButtonType.Circle }) {
        Image($r('app.media.chromium_close'))
          .width(18)
          .height(18)
          .fillColor($r('app.color.icon_secondary'))
      }
      .width(34)
      .height(34)
      .backgroundColor(Color.Transparent)
      .accessibilityText('结束查找')
      .onClick(() => {
        this.closeFindBar();
      })
    }
    .width('100%')
    .padding({ left: 12, right: 8, top: this.topSafeVp + 6, bottom: 6 })
    .backgroundColor($r('app.color.surface_floating'))
    .shadow({ radius: 16, color: $r('app.color.shadow'), offsetY: 4 })
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.opacity(0)
        .combine(TransitionEffect.translate({ y: -24 })),
      TransitionEffect.opacity(0)
    ).animation({ duration: 200, curve: Curve.Friction }))
  }

  @Builder
  private CommandButton(label: string, icon: Resource, command: string) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 4 }) {
        Image(icon)
          .width(22)
          .height(22)
          .fillColor($r('app.color.icon_primary'))
        Text(label)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .layoutWeight(1)
    .height(58)
    .borderRadius(8)
    .backgroundColor($r('app.color.surface_secondary'))
    .onClick(() => this.issueCommand({ command }))
  }

  @Builder
  private PanelEntryButton(label: string, icon: Resource, action: () => void) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 4 }) {
        Image(icon)
          .width(22)
          .height(22)
          .fillColor($r('app.color.icon_primary'))
        Text(label)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .layoutWeight(1)
    .height(58)
    .borderRadius(8)
    .backgroundColor($r('app.color.surface_secondary'))
    .onClick(action)
  }

  @Builder
  private ShareButton() {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 4 }) {
        Image($r('app.media.chromium_share'))
          .width(22)
          .height(22)
          .fillColor($r('app.color.icon_primary'))
        Text('华为分享')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .layoutWeight(1)
    .height(58)
    .borderRadius(8)
    .backgroundColor($r('app.color.surface_secondary'))
    .onClick(() => this.shareCurrentPage())
  }

  @Builder
  private CastButton() {
    AVCastPicker({
      normalColor: this.colorScheme === 'dark' ? '#F5F5F5' : '#202124',
      activeColor: this.colorScheme === 'dark' ? '#5B8CFF' : '#0A59F7',
      pickerStyle: AVCastPickerStyle.STYLE_PANEL,
      colorMode: AVCastPickerColorMode.AUTO,
      sessionType: 'video',
      customPicker: this.CastPickerContent
    })
      .layoutWeight(1)
      .height(58)
  }

  @Builder
  private CastPickerContent() {
    Column({ space: 4 }) {
      Image($r('app.media.chromium_cast'))
        .width(22)
        .height(22)
        .fillColor($r('app.color.icon_primary'))
      Text('投放')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .height(58)
    .justifyContent(FlexAlign.Center)
    .borderRadius(8)
    .backgroundColor($r('app.color.surface_secondary'))
  }

  private buildBubbleEffect(): VisualEffect {
    return new hdsEffect.HdsEffectBuilder()
      .pressShadow(hdsEffect.PressShadowType.BLEND_GRADIENT)
      .buildEffect();
  }

  private leftAction(): MobileEdgeAction {
    if (this.lastGripSide === GripSide.LEFT) {
      return this.primaryAction;
    }
    return this.secondaryAction();
  }

  private rightAction(): MobileEdgeAction {
    if (this.lastGripSide === GripSide.RIGHT) {
      return this.primaryAction;
    }
    return this.secondaryAction();
  }

  private secondaryAction(): MobileEdgeAction {
    return this.primaryAction === MobileEdgeAction.BACK ?
      MobileEdgeAction.MENU : MobileEdgeAction.BACK;
  }

  private handleEdgeAction(action: MobileEdgeAction): void {
    if (action === MobileEdgeAction.BACK) {
      this.issueCommand({ command: 'back' });
    } else {
      this.sheetPage = 'tabs';
      this.menuVisible = true;
    }
  }

  private closeMenuSheet(): void {
    this.menuVisible = false;
    this.sheetPage = 'tabs';
  }

  // 扫一扫: system scanner, result goes through the same address/search
  // rules as typed input (URL opens, text searches).
  private async startScan(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    const value = await ScanService.scanOnce(context);
    if (value.length > 0) {
      this.issueCommand({ command: 'navigate', url: normalizeAddress(value) });
    }
  }

  private openPanel(page: string): void {
    this.menuVisible = false;
    this.menuCardVisible = false;
    this.sheetPage = 'tabs';
    this.extensionsFromSettings = false;
    this.panelPage = page;
  }

  private closePanel(): void {
    this.panelPage = 'none';
    this.extensionsFromSettings = false;
  }

  private displayDomain(): string {
    if (this.isNewTabUrl(this.browserState.url)) {
      return '新标签页';
    }
    if (this.browserState.domain && this.browserState.domain.length > 0) {
      return this.browserState.domain;
    }
    return this.browserState.title && this.browserState.title.length > 0 ?
      this.browserState.title : 'Chromium';
  }

  private shortUrl(url: string): string {
    if (!url || this.isNewTabUrl(url)) {
      return '新标签页';
    }
    return url.replace(/^https?:\/\//, '');
  }

  private isNewTabUrl(url: string): boolean {
    return url.startsWith('chrome://newtab') ||
      url.startsWith('chrome://new-tab-page') ||
      url.startsWith('chrome://new-tab-page-third-party');
  }

  private beginAddressEdit(): void {
    this.addressEditEpoch += 1;
    this.addressDraft = this.browserState.url.startsWith('chrome://') ? '' : this.browserState.url;
    this.addressSelectionStart = 0;
    this.addressSelectionEnd = this.addressDraft.length;
    this.editingAddress = true;
    this.clearKeyboardRecoveryTimers();
    // Pin both bars while the keyboard is up (SHELL_CONTRACT.md, "手机：滚动
    // 时收起地址栏和 dock", step 5).
    this.issueCommand({ command: 'setBrowserControlsState', state: 'shown' });
    [0, 80, 220, 450].forEach((delay: number): void => {
      this.keyboardRecoveryTimers.push(setTimeout((): void => {
        if (!this.editingAddress) {
          return;
        }
        try {
          this.getUIContext().getFocusController().requestFocus('mobile_address_input');
          inputMethod.getController().showTextInput().catch((error: Error): void => {
            console.error('Failed to show the address keyboard:', error);
          });
        } catch (error) {
        }
      }, delay));
    });
  }

  private pasteAddress(): void {
    this.clearKeyboardRecoveryTimers();
    const epoch = this.addressEditEpoch;
    const original = this.addressDraft;
    const activation = this.browserState.activationEpoch;
    const tabId = this.browserState.tabs[this.browserState.activeTabIndex]?.id;
    const pageUrl = this.browserState.url;
    const start = Math.max(0, Math.min(this.addressSelectionStart, original.length));
    const end = Math.max(start, Math.min(this.addressSelectionEnd, original.length));
    showSystemPasteDialog(this.getUIContext(), (text: string): void => {
      if (!this.editingAddress || this.addressEditEpoch !== epoch ||
        this.addressDraft !== original || this.browserState.activationEpoch !== activation ||
        this.browserState.tabs[this.browserState.activeTabIndex]?.id !== tabId ||
        this.browserState.url !== pageUrl) {
        return;
      }
      this.addressDraft = original.substring(0, start) + text + original.substring(end);
      this.addressSelectionStart = start + text.length;
      this.addressSelectionEnd = this.addressSelectionStart;
      this.keyboardRecoveryTimers.push(setTimeout((): void => {
        if (this.editingAddress && this.addressEditEpoch === epoch) {
          this.getUIContext().getFocusController().requestFocus('mobile_address_input');
          this.addressController.caretPosition(this.addressSelectionEnd);
        }
      }, 0));
    }, (): void => {});
  }

  private submitAddress(): void {
    this.clearKeyboardRecoveryTimers();
    const target = normalizeAddress(this.addressDraft);
    if (target.length > 0) {
      this.issueCommand({ command: 'navigate', url: target });
      this.editingAddress = false;
      // Fix B：延迟顶栏回弹到首帧绘制后，消除视口 resize 与首帧 swap 叠加跳动。
      this.reboundControlsAfterPaint();
    } else {
      this.editingAddress = false;
      this.issueCommand({ command: 'setBrowserControlsState', state: 'both' });
    }
  }

  private clearKeyboardRecoveryTimers(): void {
    this.keyboardRecoveryTimers.forEach((timer: number): void => clearTimeout(timer));
    this.keyboardRecoveryTimers = [];
  }

  private issueCommand(command: BrowserCommandPayload): void {
    this.onCommand(command);
  }

  private setPrimaryAction(action: MobileEdgeAction): void {
    this.primaryAction = action;
    AppStorage.setOrCreate(PRIMARY_ACTION_KEY, action);
  }

  private setFollowGrip(value: boolean): void {
    this.followGrip = value;
    AppStorage.setOrCreate(FOLLOW_GRIP_KEY, value);
    if (value) {
      this.startHoldingHandAwareness();
    } else {
      this.holdingHandRouter.stop();
    }
  }

  private startHoldingHandAwareness(): void {
    this.holdingHandRouter.start((side: GripSide): void => {
      this.lastGripSide = side;
      AppStorage.setOrCreate(LAST_GRIP_SIDE_KEY, side);
    });
  }

  private shareCurrentPage(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    HuaweiShareAdapter.sharePage(context, this.browserState.url, this.browserState.title)
      .catch((error: Error) => {
        console.error('Huawei Share failed:', error);
      });
  }
}

// The dock's system immersive material (沉浸光感), driven exactly the way
// Lumie drives it: a real HdsTabs whose five tabBar entries ARE the five
// dock buttons. The earlier revision used a bare single-tab backplate with
// the buttons stacked on top of it; on device the material's geometry
// followed that empty bar, so the capsule looked too tall and a haze ring
// bled around both rounded ends -- and with hitTest None touches never
// reached the material either, so the press light never fired. Lumie shows
// none of that on the same phone, and its decompiled shell explains why:
// five TabContents, each with a tabBar builder rendering a real button,
// clicks distributed centrally from onTabBarClick.
//
// The three flags that make the floating material appear (official guide:
// all three at once, or the material silently does not render):
// barOverlap true + vertical false + barPosition End.
//
// gradientMask pins the material's fade region to exactly "bar + the strip
// below it" -- the same shape as Lumie's dock mask. Left unset, the mask
// falls back to "component height + tabBar + 32vp", a tall rectangle
// bleeding above the capsule. barBackgroundColor / barBackgroundBlurStyle
// are deliberately never set: the official guide says they cover the
// material ("避免遮挡材质效果").
//
// barWidth is set explicitly. A first revision passed no barWidth (Lumie
// sets none either) and the floating bar measured itself from its tab
// items -- but our items are percent-sized, so the measurement collapsed
// to nothing and the whole plate (material AND buttons) vanished. Now the
// bar gets the concrete width on all three breakpoints AND every tab item
// carries an intrinsic DOCK_SLOT_WIDTH_VP, so either measurement path
// lands on the intended capsule.
@Component
struct DockMaterialPlate {
  @Prop canGoBack: boolean = false;
  @Prop canGoForward: boolean = false;
  @Prop tabCount: number = 0;
  @Prop barWidthVp: number = 328;
  @Prop barHeightVp: number = 48;
  @Prop sideMarginVp: number = 16;
  @Prop bottomMarginVp: number = 0;
  onDockSlot: (slot: string) => void = (_slot: string): void => {};
  // 按压中的按钮（弹簧缩放用）；只在本子树内使用，无需跨组件共享。
  @State private pressedSlot: string = '';

  private readonly slots: string[] = ['返回', '前进', '主页', '标签页', '菜单'];

  build() {
    HdsTabs({ barPosition: BarPosition.End, index: 0 }) {
      ForEach(this.slots, (slot: string): void => {
        TabContent() {
          // 页面本体在 WebWindow 里；TabContent 只是 tab 的存在凭据。
          Column()
            .width('100%')
            .height('100%')
        }
        .tabBar(this.DockSlotBar(slot))
      }, (slot: string): string => slot)
    }
    .vertical(false)
    .scrollable(false)
    .barMode(BarMode.Fixed)
    .barOverlap(true)
    .animationDuration(0)
    .barHeight(this.barHeightVp)
    .barFloatingStyle(this.resolveFloatingStyle())
    .onTabBarClick((index: number): void => {
      if (index < 0 || index >= this.slots.length) {
        return;
      }
      const slot: string = this.slots[index];
      if (slot === '返回' && !this.canGoBack) {
        return;
      }
      if (slot === '前进' && !this.canGoForward) {
        return;
      }
      this.onDockSlot(slot);
    })
    .width('100%')
    .height('100%')
    .clip(true)
  }

  // 一个 tabBar 项 = 一个 dock 按钮。结构刻意与 Lumie 的 DockItem 同构
  // （反编译：Column + width('100%') + height('100%') + justifyContent
  // Center），两个真机教训是这么修的：
  // ① "胶囊内图标不居中"：固定高 62 的 Button 在 HdsTabs 的槽位里会落在
  //    偏下 ~4vp 处（像素实测），Lumie 同机居中——因为它填满槽位再居中。
  // ② "点按白框"：Button 的默认按压蒙层（stateEffect）在深色下是一块
  //    浅色矩形（按压缩小后 ≈51×50vp，与截图逐像素吻合）；Lumie 的项
  //    是普通 Column，全程没有 Button/stateEffect。
  // 点光源也不要：v9 的 BORDER_CONTENT 把每个按钮点亮成一圈白色描边
  // 方框、还把整条胶囊洗白。按压反馈 = 弹簧缩放 + 材质原生触摸光感。
  @Builder
  private DockSlotBar(slot: string) {
    Column() {
      if (slot === '标签页') {
        Text(this.tabCount > 99 ? '99+' : this.tabCount.toString())
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.icon_primary'))
          .textAlign(TextAlign.Center)
          .width(22)
          .height(20)
          .borderRadius(6)
          .border({ width: 1.8, color: $r('app.color.icon_primary') })
      } else {
        Image(this.slotIcon(slot))
          .width(22)
          .height(22)
          .fillColor($r('app.color.icon_primary'))
      }
    }
    // 固有宽度 65 是防塌缩保险（浮动条自动测量路径要靠它；barWidth 已
    // 显式给，两条测量路径都要能立起来）。高度交给槽位（100%），内容
    // 由 justifyContent 垂直居中——这是与 Lumie 对齐的关键。
    .width(DOCK_SLOT_WIDTH_VP)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .opacity(this.slotUsable(slot) ? 1 : 0.4)
    .enabled(this.slotUsable(slot))
    .scale({ x: this.pressedSlot === slot ? 0.82 : 1, y: this.pressedSlot === slot ? 0.82 : 1 })
    .accessibilityText(slot)
    .onTouch((event: TouchEvent): void => {
      this.handleSlotTouch(event, slot);
    })
  }

  private slotUsable(slot: string): boolean {
    if (slot === '返回') {
      return this.canGoBack;
    }
    if (slot === '前进') {
      return this.canGoForward;
    }
    return true;
  }

  private slotIcon(slot: string): Resource {
    if (slot === '返回') {
      return $r('app.media.chromium_back');
    }
    if (slot === '前进') {
      return $r('app.media.chromium_forward');
    }
    if (slot === '主页') {
      return $r('app.media.chromium_home');
    }
    return $r('app.media.chromium_more');
  }

  // Press -> quick shrink; release -> under-damped spring back ("jelly").
  // 禁用槽位（返回/前进不可用）不做按压动画——以前靠 Button.enabled 挡
  // 触摸，换成 Column 后在这里守。
  private handleSlotTouch(event: TouchEvent, slot: string): void {
    if (!this.slotUsable(slot)) {
      return;
    }
    if (event.type === TouchType.Down) {
      animateTo({ duration: 90, curve: Curve.FastOutSlowIn }, (): void => {
        this.pressedSlot = slot;
      });
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      animateTo({ curve: curves.springMotion(0.3, 0.7) }, (): void => {
        this.pressedSlot = '';
      });
    }
  }

  private resolveFloatingStyle(): HdsTabsFloatingStyle {
    const width: number = Math.max(1, this.barWidthVp);
    const style: HdsTabsFloatingStyle = {
      barSideMargin: this.sideMarginVp,
      barBottomMargin: this.bottomMarginVp,
      // The concrete capsule width. Without it the floating bar falls back
      // to measuring its items, and percent-sized items measure to zero.
      barWidth: {
        smallWidth: width,
        mediumWidth: width,
        largeWidth: width
      },
      // ADAPTIVE lets the system pick the material strength for the device
      // (Lumie's DOCK_MATERIAL is exactly this type/level pair).
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      },
      // The fade region: from the bar down past the home-indicator strip to
      // the layer's bottom edge (= the screen edge). maskHeight = bar +
      // bottom margin, mirroring Lumie's dockMaskHeight.
      gradientMask: {
        maskColor: $r('app.color.dock_mask'),
        maskHeight: this.barHeightVp + this.bottomMarginVp
      }
    };
    return style;
  }
}
