// A' 面板页化（Phase 3）：扩展程序改为独立 @Entry 路由页。
// 导航由系统 router 栈接管（router.pushUrl / router.back）：从菜单进入时返回回
// 浏览器、从设置进入时返回回设置页——系统栈自动区分，不再需要 extensionsFromSettings。
// currentUrl 由 ExtensionPanel 自身从 AppStorage（auraCurrentUrl）读取。
// ⚠️ onClose 与 onBack 语义不同：onBack = 返回上一级（pop 一层）；onClose 是
// ExtensionPanel 的「收起本页让网页层原生 UI 可见」专属语义（扩展 popup /
// chrome://extensions / 安装确认框都画在网页层）→ 必须 back({url: AuraShell})
// 一路回到浏览器，不能只 pop 一层（从设置进入时会退回设置页，原生 UI 被盖住，
// 表现为「点扩展没反应 / 被弹回设置页」）。
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
          router.back({ url: 'pages/AuraShell' });
        }
      })
    }
    .width('100%')
    .height('100%')
  }
}
