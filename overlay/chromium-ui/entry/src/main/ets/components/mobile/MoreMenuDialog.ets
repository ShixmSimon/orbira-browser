/*
 * 贴右上角弹出的「更多操作」菜单卡 —— CustomDialog 承载。
 *
 * 为什么走 CustomDialog：弹窗在独立子窗口里，属于沉浸材质的「允许区」
 * （GlassScope.HOST）——卡片挂官方 systemMaterial 能拿到真玻璃 + 边缘流光
 * （和系统 AlertDialog 同源的窗口机制），这是页内自绘 Stack 卡拿不到的。
 * 材质不可用时兜底 menu_glass 实底（观感退化为之前的自绘卡，不会透明）。
 *
 * 定位：alignment TopEnd + offset —— 卡片右缘距屏右 12vp、顶在标题行下方，
 * 复刻旧版 bindMenu 的弹出位置。autoCancel 点外自动收起，maskColor 透明
 * （不做全屏变暗，菜单卡语义）。
 */
import uiMaterial from '@ohos.arkui.uiMaterial';
import { glassMaterial, GlassRole, GlassScope, glassNoneShadow } from '../../utils/appearance/GlassMaterial';

export interface MoreMenuItemSpec {
  icon: Resource;
  label: string;
  action: () => void;
}

@CustomDialog
export struct MoreMenuDialog {
  controller?: CustomDialogController;
  items: MoreMenuItemSpec[] = [];
  // 弹窗子窗口 = 允许区 → 材质会真的渲染（THICK 压得住下层 + 自带阴影光效）。
  private readonly glass: uiMaterial.Material | undefined =
    glassMaterial(GlassRole.CARD, GlassScope.HOST);

  build() {
    Column() {
      ForEach(this.items, (item: MoreMenuItemSpec) => {
        Row({ space: 14 }) {
          Image(item.icon)
            .width(21)
            .height(21)
            .fillColor($r('app.color.icon_primary'))
          Text(item.label)
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
          Blank()
        }
        .width('100%')
        .height(48)
        .padding({ left: 18, right: 16 })
        .onClick(() => {
          this.controller?.close();
          item.action();
        })
      }, (item: MoreMenuItemSpec): string => item.label)
    }
    .width(190)
    .padding({ top: 6, bottom: 6 })
    .borderRadius(22)
    .systemMaterial(this.glass)
    // 材质接管背景色（官方约定让位给它）；拿不到材质就退回 menu_glass 实底。
    .backgroundColor(this.glass === undefined ? $r('app.color.menu_glass') : Color.Transparent)
    .shadow(this.glass === undefined
      ? { radius: 26, color: $r('app.color.shadow'), offsetY: 8 }
      : glassNoneShadow())
  }
}
