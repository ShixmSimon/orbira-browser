/*
 * 贴右上角弹出的「更多操作」菜单卡 —— CustomDialog 承载。
 *
 * ⚠️ 2026-10-10 真机定案：**弹窗子窗口里自定义组件挂 systemMaterial 不渲染**
 * （材质挂上了却把 backgroundColor 顶掉 → 整块透明）。系统流光只存在于
 * AlertDialog/ActionSheet 等「系统默认样式」的弹窗上——系统自己画的那层，
 * 自定义内容拿不到。别再试在 CustomDialog/页内 Stack 卡上挂材质；
 * 菜单卡的最终形态就是 menu_glass 实底 + 圆角 + 阴影（无流光）。
 *
 * 仍用 CustomDialog 承载的理由：形态/定位稳定（贴右上、标题行正下方），
 * autoCancel 点外自动收起，独立窗口不参与页面布局。
 */
export interface MoreMenuItemSpec {
  icon: Resource;
  label: string;
  action: () => void;
}

@CustomDialog
export struct MoreMenuDialog {
  controller?: CustomDialogController;
  items: MoreMenuItemSpec[] = [];

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
    .backgroundColor($r('app.color.menu_glass'))
    .shadow({ radius: 26, color: $r('app.color.shadow'), offsetY: 8 })
  }
}
