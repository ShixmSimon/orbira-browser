import { common } from '@kit.AbilityKit';
import { AVCastPicker, AVCastPickerColorMode, AVCastPickerStyle } from '@kit.AVSessionKit';
import { hdsEffect } from '@kit.UIDesignKit';
import { inputMethod } from '@kit.IMEKit';
import { curves } from '@kit.ArkUI';
import { showSystemPasteDialog } from './SystemPasteDialog';
import { ScanService } from './ScanService';
import {
  BrowserCommandPayload,
  BrowserStateSnapshot,
  BrowserTabState,
  TabThumbnail
} from 'engine';
import { HuaweiShareAdapter } from 'engine';
import { GripSide, HoldingHandRouter } from './HoldingHandRouter';
import { CurrentTabCastSession } from './CurrentTabCastSession';
import { BookmarksPanel } from './BookmarksPanel';
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
// Dock height 62 + container bottom padding 12: the bar must travel far
// enough to fully leave the screen when the page scrolls (controlsRatio 0).
export const BOTTOM_DOCK_EXTENT_VP: number = 74;

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
  // Floating-chrome styling note: the system ImmersiveMaterial is
  // deliberately NOT used for these bars. The HarmonyOS 7 light-sense
  // contract honors system materials only on dialog-class components or
  // inside Navigation title bars / Tabs bottom bars -- a free-floating Row
  // silently loses the effect and would render with no background at all.
  // The bars therefore always take the painted path: translucent resource
  // color + component blur. See UI-DESIGN-SPEC.md section 8.

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
    this.holdingHandRouter.stop();
    this.currentTabCastSession.stop().catch((error: Error) => {
      console.error('Failed to stop current-tab cast session:', error);
    });
  }

  // The page's onBackPress asks this first: dismiss chrome the user can see
  // (address editing, the tab menu, a full-screen shell page), then page
  // history, and only leave the app when there is nothing of ours to unwind.
  private handleSystemBack(): boolean {
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
    this.currentTabCastSession.update(this.browserState);
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
    }
    .width('100%')
    .height('100%')
    // While only the floating bars are up, touches fall through to the page;
    // a full-screen panel covers everything, so it takes the events instead.
    .hitTestBehavior(this.panelPage === 'none' ?
      HitTestMode.Transparent : HitTestMode.Default)
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

  // 底部 dock：一块悬浮玻璃横条——左右各留 16vp、完整圆角，半透明纯色玻璃
  // （契约 §8：网页上方不用模糊），网页从它后面穿过，跟手收起。
  // 引擎不再为 dock 保留网页空间（setBrowserControls bottom = 0）：网页画到
  // 窗口底部（手势条区除外），dock 只是外壳自己的悬浮层。条区总高 = dock
  // 自己的容器与行程（BOTTOM_DOCK_EXTENT_VP + 底部安全区）。
  @Builder
  private BottomDock() {
    Column() {
      Row() {
        this.BottomDockContent()
      }
      .width('100%')
      .height(62)
      .borderRadius(24)
      .backgroundColor($r('app.color.glass_tint'))
      .border({ width: 0.5, color: $r('app.color.divider') })
      .shadow({ radius: 16, color: $r('app.color.shadow'), offsetY: 4 })
      // System point-light press effect (HDS hdsEffect, API 20+, every
      // device): a soft white light spot that appears under the finger and
      // follows it across the bar. This is the same mechanism the system
      // browser and other HarmonyOS browsers use -- NOT the API-26
      // uiMaterial lightEffect, which is off-limits for floating bars.
      .visualEffect(this.buildDockLightEffect())
    }
    .width('100%')
    .height(BOTTOM_DOCK_EXTENT_VP + this.bottomSafeVp)
    // 左右留边让 dock 悬浮；底部留出安全区，手势条不压到胶囊上。
    .padding({ top: 12, left: 16, right: 16, bottom: this.bottomSafeVp })
    // 同顶栏：行程要含底部安全区内边距，否则 ratio→0 时 dock 仍留一条缝。
    .translate({ y: (1 - this.controlsRatioRaw) * (BOTTOM_DOCK_EXTENT_VP + this.bottomSafeVp) })
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
        Column({ space: 3 }) {
          Text(this.browserState.tabCount > 99 ? '99+' : this.browserState.tabCount.toString())
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.icon_primary'))
            .textAlign(TextAlign.Center)
            .width(22)
            .height(20)
            .borderRadius(6)
            .border({ width: 1.8, color: $r('app.color.icon_primary') })
          Text('标签页')
            .fontSize(10)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
        }
        .alignItems(HorizontalAlign.Center)
      }
      .layoutWeight(1)
      .height(58)
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
      Column({ space: 3 }) {
        Image(icon)
          .width(22)
          .height(22)
          .fillColor($r('app.color.icon_primary'))
        Text(label)
          .fontSize(10)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Center)
    }
    .layoutWeight(1)
    .height(58)
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
    }
    this.editingAddress = false;
    // Hand the bars back to scroll control.
    this.issueCommand({ command: 'setBrowserControlsState', state: 'both' });
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
