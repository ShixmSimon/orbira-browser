// A' 面板页化（Phase 3）：密码改为独立 @Entry 路由页。
// 从设置页 pushUrl 进入（系统栈：浏览器 → 设置 → 密码），返回自然回设置页。
// 面板内详情子页仍由 PasswordsPanel 自持的 HdsNavigation 处理。
import router from '@ohos.router';
import { BrowserCommandBus } from '../../bus/BrowserCommandBus';
import { PasswordsPanel } from '../../components/mobile/PasswordsPanel';

@Entry
@Component
struct PasswordsPanelPage {
  build() {
    Stack() {
      PasswordsPanel({
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
