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
  BrowserTabState
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

// The floating bars' full vertical extents (top gap + bar height), in vp.
// AuraShell reports these to the engine through setBrowserControls; the
// browserControlsRatio event then drives the bars' translation, so the page
// and both bars move together while scrolling (SHELL_CONTRACT.md, "手机：滚动
// 时收起地址栏和 dock").
export const TOP_BAR_EXTENT_VP: number = 52;
export const BOTTOM_DOCK_EXTENT_VP: number = 68;

enum MobileEdgeAction {
  BACK = 'back',
  MENU = 'menu'
}

const PRIMARY_ACTION_KEY: string = 'mobilePrimaryAction';
const FOLLOW_GRIP_KEY: string = 'mobileFollowGrip';
const LAST_GRIP_SIDE_KEY: string = 'mobileLastGripSide';

@Component
export struct MobileBrowserOverlay {
  @StorageLink('auraColorScheme') colorScheme: string = 'light';
  // Safe-area insets (status bar / navigation pill) in vp, from EntryAbility.
  @StorageProp('auraTopSafeVp') topSafeVp: number = 0;
  @StorageProp('auraBottomSafeVp') bottomSafeVp: number = 0;
  @Prop @Watch('onBrowserStateChanged') browserState: BrowserStateSnapshot;
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
  // Which view the sheet hosts: the tab list ('tabs', from the tab-count
  // button) or the browser menu ('menu', from the ⋮ button). Two entries,
  // two views -- they used to open the same screen.
  @State private sheetKind: string = 'tabs';
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
      .justifyContent(this.isNewTabUrl(this.browserState.url) ?
        FlexAlign.End : FlexAlign.SpaceBetween)
      // Reserve the status bar (top) and the navigation pill (bottom): the
      // window is fullscreen-immersive, so without these the bars sit under
      // the system clock and the gesture pill.
      .padding({ top: 8 + this.topSafeVp, left: 12, right: 12,
        bottom: 12 + this.bottomSafeVp })
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

  @Builder
  private TopAddressBar() {
    Row() {
      this.TopBarContent()
    }
    .width('100%')
    .height(44)
    .borderRadius(22)
    .backgroundColor($r('app.color.glass_tint'))
    .border({ width: 0.5, color: $r('app.color.divider') })
    .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR)
    .shadow({ radius: 16, color: $r('app.color.shadow'), offsetY: 4 })
    .translate({ y: -(1 - this.controlsRatioRaw) * TOP_BAR_EXTENT_VP })
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
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          Row({ space: 8 }) {
            if (this.browserState.loading) {
              LoadingProgress()
                .width(18)
                .height(18)
                .color($r('app.color.accent_primary'))
            }
            Text(this.displayDomain())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')
        }
        .layoutWeight(1)
        .height(44)
        .padding({ left: 16, right: 10 })
        .backgroundColor(Color.Transparent)
        .accessibilityText('地址栏')
        .onClick(() => this.beginAddressEdit())

        Button({ type: ButtonType.Circle, stateEffect: true }) {
          Image($r('app.media.chromium_scan'))
            .width(20)
            .height(20)
            .fillColor($r('app.color.icon_primary'))
        }
        .width(38)
        .height(38)
        .margin({ right: 3 })
        .backgroundColor(Color.Transparent)
        .accessibilityText('扫一扫')
        .onClick(() => {
          this.startScan();
        })

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

  @Builder
  private BottomDock() {
    Row() {
      this.BottomDockContent()
    }
    .width('100%')
    .height(56)
    .borderRadius(28)
    .backgroundColor($r('app.color.glass_tint'))
    .border({ width: 0.5, color: $r('app.color.divider') })
    .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR)
    .shadow({ radius: 16, color: $r('app.color.shadow'), offsetY: 4 })
    // System point-light press effect (HDS hdsEffect, API 20+, every
    // device): a soft white light spot that appears under the finger and
    // follows it across the bar. This is the same mechanism the system
    // browser and other HarmonyOS browsers use -- NOT the API-26
    // uiMaterial lightEffect, which is off-limits for floating bars.
    .visualEffect(this.buildDockLightEffect())
    .translate({ y: (1 - this.controlsRatioRaw) * BOTTOM_DOCK_EXTENT_VP })
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
        Text(this.browserState.tabCount > 99 ? '99+' : this.browserState.tabCount.toString())
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.icon_primary'))
          .textAlign(TextAlign.Center)
          .width(24)
          .height(22)
          .borderRadius(6)
          .border({ width: 1.8, color: $r('app.color.icon_primary') })
      }
      .layoutWeight(1)
      .height(52)
      .backgroundColor(Color.Transparent)
      .scale({ x: this.pressedDock === '标签页' ? 0.82 : 1, y: this.pressedDock === '标签页' ? 0.82 : 1 })
      .accessibilityText('标签页')
      .onTouch((event: TouchEvent): void => {
        this.handleDockTouch(event, '标签页');
      })
      .onClick((): void => {
        this.sheetKind = 'tabs';
        this.menuVisible = true;
      })

      this.DockButton($r('app.media.chromium_more'), '菜单', true,
        (): void => {
          this.sheetKind = 'menu';
          this.menuVisible = true;
        })
  }

  @Builder
  private DockButton(icon: Resource, label: string, usable: boolean, action: () => void) {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Image(icon)
        .width(22)
        .height(22)
        .fillColor($r('app.color.icon_primary'))
    }
    .layoutWeight(1)
    .height(52)
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
      if (this.sheetKind === 'menu') {
        this.MenuView()
      } else {
        this.TabsView()
      }
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
        Text('标签页')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Button({ type: ButtonType.Circle }) {
          Image($r('app.media.chromium_add'))
            .width(22)
            .height(22)
            .fillColor($r('app.color.icon_primary'))
        }
        .width(44)
        .height(44)
        .backgroundColor($r('app.color.surface_secondary'))
        .accessibilityText('新建标签页')
        .onClick(() => {
          this.menuVisible = false;
          this.sheetKind = 'tabs';
          this.issueCommand({ command: 'newTab' });
        })
      }
      .width('100%')
      .height(52)

      List({ space: 2 }) {
        ForEach(this.browserState.tabs, (tab: BrowserTabState) => {
          ListItem() {
            Row({ space: 10 }) {
              Row()
                .width(4)
                .height(28)
                .borderRadius(2)
                .backgroundColor(tab.active ?
                  $r('app.color.accent_primary') : $r('app.color.transparent'))
              Column({ space: 2 }) {
                Text(tab.title && tab.title.length > 0 ? tab.title : '新标签页')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontSize(16)
                  .fontWeight(tab.active ? FontWeight.Medium : FontWeight.Regular)
                  .fontColor($r('app.color.text_primary'))
                Text(this.shortUrl(tab.url))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Button({ type: ButtonType.Circle }) {
                Image($r('app.media.chromium_close'))
                  .width(18)
                  .height(18)
                  .fillColor($r('app.color.icon_secondary'))
              }
              .width(40)
              .height(40)
              .backgroundColor(Color.Transparent)
              .accessibilityText('关闭标签页')
              .onClick(() => {
                this.issueCommand({ command: 'closeTab', index: tab.index });
              })
            }
            .width('100%')
            .height(58)
            .padding({ left: 4, right: 2 })
            .onClick(() => {
              // Switch first, then dismiss: the reader expects to land on
              // the page they tapped, with the panel gone.
              this.issueCommand({ command: 'activateTab', index: tab.index });
              this.closeMenuSheet();
            })
          }
        }, (tab: BrowserTabState): string => tab.index.toString())
      }
      .width('100%')
      .layoutWeight(1)

      Row() {
        Text('最近关闭的标签页')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
        Blank()
        Text('›')
          .fontSize(18)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .height(44)
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

  // The ⋮ menu: page commands and the shell's own pages. The tab list lives
  // in TabsView (tab-count button), so the two dock entries open two
  // different views instead of the same screen. The old "primary action"
  // and grip-awareness rows were removed with the floating 3-button bar
  // they tuned -- the fixed dock has nothing for them to change.
  @Builder
  private MenuView() {
    Column() {
      Row() {
        Text('菜单')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')
      .height(52)

      Row({ space: 8 }) {
        this.CommandButton(
          this.browserState.loading ? '停止' : '刷新',
          $r('app.media.chromium_reload'),
          this.browserState.loading ? 'stop' : 'reload')
        this.ShareButton()
        this.CommandButton(
          '\u6253\u5370',
          $r('app.media.chromium_print'),
          'print')
        this.CastButton()
      }
      .width('100%')

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
        this.PanelEntryButton('扩展', $r('app.media.chromium_extensions'), (): void => {
          this.openPanel('extensions');
        })
        this.PanelEntryButton('设置', $r('app.media.chromium_settings'), (): void => {
          this.openPanel('settings');
        })
      }
      .width('100%')
      .margin({ top: 8 })

      Blank()
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 16 })
    // Transparent for the same reason as TabsView: let the sheet's system
    // material show through instead of painting over it.
    .backgroundColor(Color.Transparent)
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
    this.sheetKind = 'tabs';
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
