// A' 面板页化（Phase 3）：网站权限改为独立 @Entry 路由页。
// 从设置页 pushUrl 进入（系统栈：浏览器 → 设置 → 网站权限），返回自然回设置页。
// 面板内详情子页仍由 SitePermissionsPanel 自持的 HdsNavigation 处理。
import router from '@ohos.router';
import { BrowserCommandBus } from '../../bus/BrowserCommandBus';
import { SitePermissionsPanel } from '../../components/mobile/SitePermissionsPanel';

@Entry
@Component
struct SitePermissionsPanelPage {
  build() {
    Stack() {
      SitePermissionsPanel({
        onCommand: BrowserCommandBus.dispatch,
        onBack: (): void => {
          router.back();
        },
        onClose: (): void => {
          router.back();
        }
      })
    }
    .width('100%')
    .height('100%')
  }
}
