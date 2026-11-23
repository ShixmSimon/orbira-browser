// A' 面板页化（Phase 3）：设置改为独立 @Entry 路由页。
// 导航由系统 router 栈接管（router.pushUrl / router.back），免费获得原生 push-pop
// 转场，且不嵌套 GlassPage 的 HdsNavigation（避免白屏铁律）。
// 设置内的二级入口（扩展程序 / 网站权限 / 密码）改为 router.pushUrl 压入系统栈，
// 返回自然回到本页；主页布局 / 添加主页磁贴经 AppStorage 信号桥回 overlay。
import router from '@ohos.router';
import { BrowserCommandBus } from '../../bus/BrowserCommandBus';
import { SettingsPanel } from '../../components/mobile/SettingsPanel';

@Entry
@Component
struct SettingsPanelPage {
  build() {
    Stack() {
      SettingsPanel({
        onCommand: BrowserCommandBus.dispatch,
        onBack: (): void => {
          router.back();
        },
        onOpenExtensions: (): void => {
          router.pushUrl({ url: 'pages/panels/ExtensionPanelPage' }).catch((error: Error): void => {
            console.error('openExtensionPanelPage pushUrl failed:', error);
          });
        },
        onOpenWebApps: (): void => {
          router.pushUrl({ url: 'pages/panels/WebAppsPanelPage' }).catch((error: Error): void => {
            console.error('openWebAppsPanelPage pushUrl failed:', error);
          });
        },
        onOpenSitePermissions: (): void => {
          router.pushUrl({ url: 'pages/panels/SitePermissionsPanelPage' })
            .catch((error: Error): void => {
              console.error('openSitePermissionsPanelPage pushUrl failed:', error);
            });
        },
        onOpenPasswords: (): void => {
          router.pushUrl({ url: 'pages/panels/PasswordsPanelPage' }).catch((error: Error): void => {
            console.error('openPasswordsPanelPage pushUrl failed:', error);
          });
        },
        onOpenHomeLayout: (): void => {
          // 方案 R4：先退出本页（pop 回浏览器），再经信号打开主页布局弹层
          // （HomeSurface 在底层浏览器页 @Watch，跨页仍触发）。
          router.back();
          AppStorage.setOrCreate('auraOpenHomeLayout',
            ((AppStorage.get('auraOpenHomeLayout') as number) ?? 0) + 1);
        },
        onAddHomeTile: (): void => {
          // 先退出本页，再经信号让 overlay 弹出「添加主页网址」表单。
          router.back();
          AppStorage.setOrCreate('auraRequestAddHomeTile',
            ((AppStorage.get('auraRequestAddHomeTile') as number) ?? 0) + 1);
        }
      })
    }
    .width('100%')
    .height('100%')
  }
}
