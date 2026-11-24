/*
 * 已安装 WebApp 管理页。引擎的 getWebApps / launchWebApp / uninstallWebApp /
 * exportWebAppIcon 命令已具备，本页只负责列出、操作和认领回包。
 *
 * 回包统一由 AuraShell 写到 'auraPanelWebApps'（含 _seq，保证同内容也刷新）。
 * 按 event 区分列表 / 卸载 / 图标导出，按 requestId 过滤迟到回包。
 *
 * 页面外壳走官方 HdsNavigation（和设置/扩展面板同一套：标题栏沉浸光感
 * 材质 + 渐变模糊滚动 + 系统安全区），不再自绘标题栏，观感与其它页对齐。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BrowserCommandPayload, InstalledWebApp } from 'engine';
import { glassHeaderInsetVp } from './GlassPage';
import {
  HdsNavigation,
  HdsNavigationTitleMode,
  hdsMaterial,
  ScrollEffectType
} from '@kit.UIDesignKit';

interface WebAppsPayload {
  event?: string;
  requestId?: number;
  apps?: InstalledWebApp[];
  appId?: string;
  title?: string;
  path?: string;
  ok?: boolean;
}

@Component
export struct WebAppsPanel {
  @StorageLink('auraPanelWebApps') @Watch('onWebAppsPayload') webAppsJson: string = '';
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  onBack: () => void = (): void => {};
  onClose: () => void = (): void => {};

  @State private apps: InstalledWebApp[] = [];
  @State private loading: boolean = true;
  @State private pathStack: NavPathStack = new NavPathStack();
  private listScroller: Scroller = new Scroller();
  private requestSeq: number = 0;
  private exportSeq: number = 0;

  aboutToAppear(): void {
    this.onWebAppsPayload();
    this.reload();
  }

  private reload(): void {
    this.loading = true;
    this.requestSeq += 1;
    this.onCommand({ command: 'getWebApps', requestId: this.requestSeq });
  }

  private onWebAppsPayload(): void {
    if (this.webAppsJson.length === 0) {
      return;
    }
    let payload: WebAppsPayload;
    try {
      payload = JSON.parse(this.webAppsJson) as WebAppsPayload;
    } catch (error) {
      return;
    }
    if (payload.event === 'webApps') {
      if ((payload.requestId ?? 0) !== this.requestSeq) {
        return;
      }
      const list: InstalledWebApp[] = [];
      const raw = payload.apps ?? [];
      for (const app of raw) {
        list.push(app);
      }
      this.apps = list;
      this.loading = false;
    } else if (payload.event === 'webAppUninstalled') {
      if (payload.ok === true) {
        this.getUIContext().getPromptAction().showToast({ message: '已卸载', duration: 2000 });
        this.reload();
      } else {
        this.getUIContext().getPromptAction().showToast({ message: '卸载失败', duration: 2000 });
      }
    } else if (payload.event === 'pwaInstalled') {
      // 安装完成（通常来自网页上的 Chromium 安装气泡）：面板正开着就重取，
      // 省得用户退出重进才看到新应用。
      this.reload();
    } else if (payload.event === 'webAppIcon') {
      if ((payload.requestId ?? 0) !== this.exportSeq) {
        return;
      }
      const path: string = payload.path ?? '';
      this.getUIContext().getPromptAction().showToast({
        message: path.length > 0 ? `图标已导出：${path}` : '这个应用没有可用的图标',
        duration: 3000
      });
    }
  }

  private install(): void {
    // 引擎把 Chromium 的安装确认气泡画在当前标签的网页层，面板盖在上面就
    // 看不见；先收面板再下发（所以用户看到的是「返回网页后弹出」，正常）。
    this.onClose();
    this.onCommand({ command: 'installWebApp' });
  }

  private launch(appId: string): void {
    this.onClose();
    this.onCommand({ command: 'launchWebApp', appId: appId });
  }

  private confirmUninstall(appId: string, title: string): void {
    AlertDialog.show({
      title: '卸载 Web 应用',
      message: `确定要移除"${title}"吗？`,
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
          this.onCommand({ command: 'uninstallWebApp', appId: appId });
        }
      }
    });
  }

  private exportIcon(appId: string): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined) {
      return;
    }
    const directory: string = `${context.filesDir}/aura-webapp-icons`;
    try {
      if (!fs.accessSync(directory)) {
        fs.mkdirSync(directory);
      }
    } catch (error) {
      try {
        fs.mkdirSync(directory);
      } catch (createError) {
        this.getUIContext().getPromptAction().showToast({ message: '无法创建图标目录', duration: 2000 });
        return;
      }
    }
    this.exportSeq += 1;
    this.onCommand({
      command: 'exportWebAppIcon',
      requestId: this.exportSeq,
      appId: appId,
      directory: directory
    });
  }

  build() {
    HdsNavigation(this.pathStack) {
      Scroll(this.listScroller) {
        Column({ space: 12 }) {
          Text('把网页安装成独立窗口后，可以从这里启动、卸载，或导出它的图标。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          if (this.loading) {
            Text('加载中…')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding(16)
              .borderRadius(16)
              .backgroundColor($r('app.color.card_background'))
          } else if (this.apps.length === 0) {
            Text('还没有安装 Web 应用')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding(16)
              .borderRadius(16)
              .backgroundColor($r('app.color.card_background'))
          } else {
            ForEach(this.apps, (app: InstalledWebApp): void => {
              Column({ space: 8 }) {
                Text(app.title)
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                Text(app.startUrl)
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
                  Button('启动').margin({ right: 8, top: 4 })
                    .onClick(() => this.launch(app.appId))
                  Button('导出图标').margin({ right: 8, top: 4 })
                    .onClick(() => this.exportIcon(app.appId))
                  if (app.canUninstall) {
                    Button('卸载').margin({ right: 8, top: 4 })
                      .fontColor($r('app.color.danger'))
                      .onClick(() => this.confirmUninstall(app.appId, app.title))
                  }
                }
                .width('100%')
              }
              .width('100%')
              .padding(16)
              .borderRadius(16)
              .backgroundColor($r('app.color.card_background'))
            }, (app: InstalledWebApp): string => app.appId)
          }

          Button('安装当前网页到桌面')
            .width('100%')
            .height(46)
            .fontSize(16)
            .margin({ top: 8, bottom: 24 })
            .onClick(() => this.install())
        }
        .width('100%')
        .padding({
          left: 16,
          right: 16,
          top: glassHeaderInsetVp(),
          bottom: 16
        })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }
    .titleBar({
      content: {
        title: { mainTitle: 'Web 应用' },
        backIcon: {
          icon: $r('sys.symbol.chevron_backward'),
          isEnabled: true,
          action: (): void => {
            this.onBack();
          }
        },
        menu: undefined
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
    .width('100%')
    .height('100%')
  }
}
