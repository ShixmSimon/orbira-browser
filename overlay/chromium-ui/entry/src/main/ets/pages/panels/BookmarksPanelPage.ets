// A' 面板页化（Phase 2）：书签改为独立 @Entry 路由页。
// 导航由系统 router 栈接管（router.pushUrl / router.back），免费获得原生 push-pop
// 转场，且不嵌套 GlassPage 的 HdsNavigation（避免白屏铁律）。
// currentUrl/currentTitle 已由 BookmarksPanel 自身从 AppStorage（auraCurrentUrl /
// auraCurrentTitle）读取，本页不再以构造参数传入。
import router from '@ohos.router';
import { BrowserCommandBus } from '../../bus/BrowserCommandBus';
import { BookmarksPanel } from '../../components/mobile/BookmarksPanel';

@Entry
@Component
struct BookmarksPanelPage {
  build() {
    Stack() {
      BookmarksPanel({
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
