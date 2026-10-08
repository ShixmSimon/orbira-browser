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

import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { ShellUiPrefs } from '../utils/appearance/ShellUiPrefs';
import { IncognitoSwitch, SavedTab } from '../utils/IncognitoSwitch';
import { WebWindow, PictureInPictureSurface } from 'engine';
import { BOTTOM_DOCK_EXTENT_VP, MobileBrowserOverlay, TOP_BAR_EXTENT_VP } from '../components/mobile/MobileBrowserOverlay';
import { MobileBackRouter } from '../components/mobile/MobileBackRouter';
import { HomeSurface } from '../components/mobile/HomeSurface';
import { CurrentTabCastSession } from '../components/mobile/CurrentTabCastSession';
import { showContextMenuSheet } from '../components/mobile/ContextMenuSheet';
import { BrowserOnboarding } from '../components/onboarding/BrowserOnboarding';
import {
  AuxiliaryWindowState,
  BrowserCommandPayload,
  BrowserRuntimeEvent,
  BrowserStateSnapshot
} from 'engine';
import { CHROMIUM_HOME_URL } from 'engine';
import { HuaweiKnockShareSession, HuaweiShareAdapter } from 'engine';
import { HarmonyFilePickerAdapter, HarmonyFilePickerResult } from 'engine';
import { PermissionRequestAdapter, PermissionRequestResultPayload } from 'engine';
import {
  AboutInfoEvent,
  BrowserCommandChannel,
  DownloadListEvent,
  DownloadNotifier,
  DownloadUpdatedEvent,
  ExtensionActionsEvent,
  ExtensionDetailsEvent,
  FaviconsEvent,
  HistoryResultsEvent,
  PasswordCommandResultEvent,
  PasswordRevealedEvent,
  PrefsEvent,
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
  title: 'Chromium',
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
  @StorageLink('auraRoutingRevision') routingRevision: number = 0;
  @StorageLink('auraStartupConfig') startupConfigText: string = '';
  @StorageLink('auraStartUrl') startUrl: string = CHROMIUM_HOME_URL;
  @StorageLink('auraAppVisible') @Watch('onAppVisibleChanged') appVisible: boolean = true;
  // 上滑时隐藏状态栏: address bar collapses -> the status bar hides with it
  // and the page fills the screen (Lumie's 外观 toggle). Hysteresis keeps
  // the system bar from flapping at the collapse boundary.
  @StorageLink('auraBrowserControlsRatio') @Watch('onControlsRatioMoved') scrolledRatio: number = 1;
  @StorageLink('auraHideStatusBarOnScroll') @Watch('onHideStatusBarPrefChanged') hideStatusBarOnScroll: boolean = false;
  private statusBarHiddenByScroll: boolean = false;
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
      ShellUiPrefs.loadHideStatusBar(context).then((value: boolean): void => {
        AppStorage.setOrCreate('auraHideStatusBarOnScroll', value);
      });
    }
  }

  private onControlsRatioMoved(): void {
    this.updateStatusBarForScroll(this.scrolledRatio);
  }

  private onHideStatusBarPrefChanged(): void {
    if (!this.hideStatusBarOnScroll) {
      this.applyStatusBarHidden(false);
      this.statusBarHiddenByScroll = false;
      this.sendScrollTopExtent(false);
    } else {
      this.updateStatusBarForScroll(this.scrolledRatio);
    }
  }

  // Collapsed address bar -> hide the status bar too, and let the page fill
  // to the very top (minTop 0). Scrolling back restores both.
  private updateStatusBarForScroll(ratio: number): void {
    if (!this.hideStatusBarOnScroll || !this.isMobilePhoneUi()) {
      return;
    }
    if (ratio <= 0.1 && !this.statusBarHiddenByScroll) {
      this.statusBarHiddenByScroll = true;
      this.applyStatusBarHidden(true);
      this.sendScrollTopExtent(true);
    } else if (ratio >= 0.4 && this.statusBarHiddenByScroll) {
      this.statusBarHiddenByScroll = false;
      this.applyStatusBarHidden(false);
      this.sendScrollTopExtent(false);
    }
  }

  private applyStatusBarHidden(hidden: boolean): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    window.getLastWindow(context).then((win: window.Window): void => {
      win.setSpecificSystemBarEnabled('status', !hidden);
    }).catch((error: Error) => {
      hilog.warn(0x0000, 'AuraShell', 'Status bar toggle failed: %{public}s', JSON.stringify(error));
    });
  }

  // Re-send the reserved extents: with the status bar hidden the page may
  // start at the very top (minTop 0); with it shown, below the clock.
  private sendScrollTopExtent(statusHidden: boolean): void {
    const topSafe = Number(AppStorage.get('auraTopSafeVp') ?? 0);
    this.executeBrowserCommand({
      command: 'setBrowserControls',
      top: TOP_BAR_EXTENT_VP + (statusHidden ? 0 : topSafe),
      minTop: statusHidden ? 0 : topSafe,
      bottom: BOTTOM_DOCK_EXTENT_VP + Number(AppStorage.get('auraBottomSafeVp') ?? 0)
    });
  }

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
          this.browserState = state;
          if (!this.systemPermissionReported) {
            this.systemPermissionReported = true;
            this.reportSystemPermissionState();
          }
          if (state.ready) {
            this.configureBrowserControls();
            this.restoreSavedTabs();
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
        if (this.isMobilePhoneUi() && this.isNewTabPage()) {
          HomeSurface({
            incognito: this.incognito,
            onCommand: (command: BrowserCommandPayload): void => {
              this.executeBrowserCommand(command);
            }
          })
            .width('100%')
            .height('100%')
            .padding({ top: Number(AppStorage.get('auraTopSafeVp') ?? 0) })
        }
        if (this.isMobilePhoneUi()) {
          MobileBrowserOverlay({
            browserState: this.browserState,
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
    this.commandChannel.send(command);
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
      this.downloadNotifier?.update(shellEvent<DownloadUpdatedEvent>(event));
      // The downloads page watches this tick and re-lists (throttled) so
      // progress on it moves while a download is running.
      AppStorage.setOrCreate('auraPanelDownloadsTick', Date.now());
      return;
    }

    if (event.event === 'downloadList') {
      AppStorage.setOrCreate('auraPanelDownloads',
        JSON.stringify(shellEvent<DownloadListEvent>(event).items ?? []));
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
      AppStorage.setOrCreate('auraPanelPasswords',
        JSON.stringify(shellEvent<SavedPasswordsEvent>(event).items ?? []));
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
    if (event.event === 'siteSettings') {
      const settings = shellEvent<SiteSettingsEvent>(event);
      AppStorage.setOrCreate('auraPanelSiteSettings',
        JSON.stringify({ requestId: settings.requestId, items: settings.items ?? [] }));
      return;
    }

    if (event.event === 'browserControlsRatio') {
      const ratio = event.ratio ?? 1;
      if (ratio !== this.lastControlsRatio) {
        this.lastControlsRatio = ratio;
        AppStorage.setOrCreate('auraBrowserControlsRatio', ratio);
      }
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
    if (event.event === 'historyResults') {
      AppStorage.setOrCreate('auraPanelHistory',
        JSON.stringify(shellEvent<HistoryResultsEvent>(event).items ?? []));
      return;
    }
    if (event.event === 'prefs') {
      AppStorage.setOrCreate('auraPanelPrefs',
        JSON.stringify(shellEvent<PrefsEvent>(event).values ?? []));
      return;
    }
    if (event.event === 'searchEngines') {
      const engines = shellEvent<SearchEnginesEvent>(event).items ?? [];
      AppStorage.setOrCreate('auraPanelEngines', JSON.stringify(engines));
      // Keep the home surface and the address bar searching the way the
      // settings page shows: the default engine's resolved template.
      let template = '';
      engines.forEach((engine: SearchEngine): void => {
        if (engine.isDefault) {
          template = engine.searchUrl ?? '';
        }
      });
      if (template.length > 0) {
        AppStorage.setOrCreate('auraSearchUrlTemplate', template);
      }
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
          reason: notice.reason ?? ''
        }));
      return;
    }
    if (event.event === 'aboutInfo') {
      const about = shellEvent<AboutInfoEvent>(event);
      AppStorage.setOrCreate('auraPanelAbout',
        JSON.stringify({ chromiumVersion: about.chromiumVersion ?? '' }));
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
      showContextMenuSheet(this.getUIContext(), event, (command: BrowserCommandPayload): void => {
        this.executeBrowserCommand(command);
      });
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
    } else if (event.event === 'systemPrintFailed') {
      console.error(`Chromium PDF generation failed: ${event.reason ?? 'unknown'}`);
    }
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

  // Tells the engine the two floating bars' extents once the surface is live
  // (SHELL_CONTRACT.md, "手机：滚动时收起地址栏和 dock", step 2). The engine
  // then drives their scroll-away and reports browserControlsRatio events.
  private configureBrowserControls(): void {
    if (this.browserControlsConfigured) {
      return;
    }
    this.browserControlsConfigured = true;
    // The fullscreen-immersive window draws under the status bar and the
    // navigation pill, so the page's reserved extents include their heights
    // (EntryAbility stores them in vp). minTop keeps the page below the
    // system clock even with both bars scrolled away.
    const topSafe = Number(AppStorage.get('auraTopSafeVp') ?? 0);
    const bottomSafe = Number(AppStorage.get('auraBottomSafeVp') ?? 0);
    this.executeBrowserCommand({
      command: 'setBrowserControls',
      top: TOP_BAR_EXTENT_VP + topSafe,
      minTop: topSafe,
      bottom: BOTTOM_DOCK_EXTENT_VP + bottomSafe
    });
    // Pull the search engines once, so the home surface and the address bar
    // search the same way the settings page shows before it has been opened.
    this.searchEnginesRequestSeq += 1;
    this.executeBrowserCommand({
      command: 'getSearchEngines',
      requestId: this.searchEnginesRequestSeq
    });
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

  private isNewTabPage(): boolean {
    const url = this.browserState.url ?? '';
    return url.startsWith('chrome://newtab');
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
