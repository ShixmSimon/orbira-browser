// A' 面板页化（试点）：历史改为独立 @Entry 路由页。
// 导航由系统 router 栈接管（router.pushUrl / router.back），免费获得原生 push-pop
// 转场，且不嵌套 GlassPage 的 HdsNavigation（避免白屏铁律）。
import router from '@ohos.router';
import { BrowserCommandBus } from '../../bus/BrowserCommandBus';
import { HistoryPanel } from '../../components/mobile/HistoryPanel';

@Entry
@Component
struct HistoryPanelPage {
  build() {
    Stack() {
      HistoryPanel({
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
