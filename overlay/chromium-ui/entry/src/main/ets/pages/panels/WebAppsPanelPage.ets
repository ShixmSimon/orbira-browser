// WebApp 管理作为独立 @Entry 路由页：系统 router 栈负责 push-pop 转场，
// 不嵌套 GlassPage 的 HdsNavigation（避免白屏铁律）。
import router from '@ohos.router';
import { BrowserCommandBus } from '../../bus/BrowserCommandBus';
import { WebAppsPanel } from '../../components/mobile/WebAppsPanel';

@Entry
@Component
struct WebAppsPanelPage {
  build() {
    Stack() {
      WebAppsPanel({
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
