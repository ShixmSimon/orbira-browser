// 方案A：地址栏锁图标进入的"网站设置"独立 @Entry 路由页。
// 系统栈：浏览器 → 网站设置；返回自然回到浏览器。
// 组件内部从 AppStorage 'auraCurrentUrl' 取当前站 origin 并自行加载权限。
import router from '@ohos.router';
import { BrowserCommandBus } from '../../bus/BrowserCommandBus';
import { SiteSettingsPanel } from '../../components/mobile/SiteSettingsPanel';

@Entry
@Component
struct SiteSettingsPanelPage {
  build() {
    Stack() {
      SiteSettingsPanel({
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
