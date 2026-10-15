// A' 面板页化（Phase 3）：扩展程序改为独立 @Entry 路由页。
// 导航由系统 router 栈接管（router.pushUrl / router.back）：从菜单进入时返回回
// 浏览器、从设置进入时返回回设置页——系统栈自动区分，不再需要 extensionsFromSettings。
// currentUrl 由 ExtensionPanel 自身从 AppStorage（auraCurrentUrl）读取。
import router from '@ohos.router';
import { BrowserCommandBus } from '../../bus/BrowserCommandBus';
import { ExtensionPanel } from '../../components/mobile/ExtensionPanel';

@Entry
@Component
struct ExtensionPanelPage {
  build() {
    Stack() {
      ExtensionPanel({
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
