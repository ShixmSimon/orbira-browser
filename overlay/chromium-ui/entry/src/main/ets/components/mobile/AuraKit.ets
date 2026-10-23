/*
 * 共享件（卡片式视觉）。
 */
import { firstLetterOfHost, placeholderTint } from './FaviconKit';

/*
 * 规格（从真机截图提取）：
 *   页面底 = page_background（浅灰 #F2F3F5 / 深 #121214）
 *   卡片   = card_background（白 / #232326），圆角 16，左右留 16
 *   组标题 = 13 次要色，卡片上方左缩进 4
 *   行     = 最小高 56，左图标 22，主文字 16，副文字 12，右侧 chevron 16（0.65 透明）
 *   危险   = danger（#E24B4A / #FF6B6B）
 *
 * 全部为无 @BuilderParam 的叶子组件：卡片容器由各面板手写（Column 圆角 16 +
 * card_background），"行"里需要自定义按钮时也由面板手写——历史上 @BuilderParam
 * 传引用丢 this 的坑不再踩。
 */

@Component
export struct AuraSectionLabel {
  @Prop text: string = '';
  // 列表第一个分组标签置 true：标题栏到内容的间距统一到「一个标题字高」
  // （真机反馈 2026-10-10）。默认 14vp 是给页面中段的分组留的呼吸感。
  @Prop tightTop: boolean = false;

  build() {
    Text(this.text)
      .fontSize(13)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .padding({ left: 4, top: this.tightTop ? 4 : 14, bottom: 6 })
  }
}

@Component
export struct AuraChevron {
  @Prop iconSize: number = 16;

  build() {
    Image($r('app.media.aura_chevron'))
      .width(this.iconSize)
      .height(this.iconSize)
      .fillColor($r('app.color.icon_secondary'))
      .opacity(0.65)
  }
}

// 带图标的导航行（设置、搜索引擎等列表用）。
@Component
export struct AuraNavIconRow {
  icon: Resource = $r('app.media.chromium_settings');
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop value: string = '';
  @Prop showChevron: boolean = true;
  @Prop danger: boolean = false;
  @Prop showDivider: boolean = true;
  onTap: () => void = (): void => {};

  build() {
    Column() {
      Row({ space: 12 }) {
        Image(this.icon)
          .width(22)
          .height(22)
          .fillColor(this.danger ? $r('app.color.danger') : $r('app.color.icon_primary'))

        Column({ space: 2 }) {
          Text(this.title)
            .fontSize(16)
            .fontColor(this.danger ? $r('app.color.danger') : $r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          if (this.subtitle.length > 0) {
            Text(this.subtitle)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.value.length > 0) {
          Text(this.value)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
        }
        if (this.showChevron) {
          AuraChevron()
        }
      }
      .width('100%')
      .constraintSize({ minHeight: 56 })
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .onClick(() => {
        this.onTap();
      })

      if (this.showDivider) {
        Divider()
          .color($r('app.color.divider'))
          .margin({ left: 50 })
      }
    }
    .width('100%')
  }
}

// 站点图标：有 favicon（dataURL）则显示圆角图标；没有则按主机名稳定取色 +
// 白字首字母占位（Chrome 的 fake favicon 做法，比灰底字母可分辨）。
@Component
export struct AuraSiteIcon {
  @Prop url: string = '';
  // dataURL（'data:image/png;base64,...'）或空串（走占位）。
  @Prop iconData: string = '';
  // 不能叫 size：与 CustomComponent 基类的 size(value) 属性方法冲突。
  @Prop iconSize: number = 22;

  build() {
    if (this.iconData.length > 0) {
      Image(this.iconData)
        .width(this.iconSize)
        .height(this.iconSize)
        .borderRadius(this.iconSize * 0.22)
        .objectFit(ImageFit.Cover)
        .interpolation(ImageInterpolation.Medium)
    } else {
      Stack({ alignContent: Alignment.Center }) {
        Text(firstLetterOfHost(this.url))
          .fontSize(this.iconSize * 0.42)
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Medium)
      }
      .width(this.iconSize)
      .height(this.iconSize)
      .borderRadius(this.iconSize * 0.22)
      .backgroundColor(placeholderTint(this.url))
    }
  }
}

// 统一搜索框（沉浸光感）：glass_tint 半透底 + 发丝描边 + 柔影，呼应鸿蒙 7 设置。
// 内容区只能用 glass_tint（真玻璃只在标题栏/弹窗），不叠 backgroundBlurStyle。
// 通过 inputId 暴露给各页的「回顶聚焦」逻辑；showClear 控制右侧清除按钮。
@Component
export struct AuraSearchBar {
  @Prop placeholder: string = '';
  @Prop text: string = '';
  @Prop showClear: boolean = false;
  inputId: string = '';
  onInput: (value: string) => void = (_value: string): void => {};
  onClear: () => void = (): void => {};

  build() {
    Row({ space: 8 }) {
      Image($r('app.media.chromium_search'))
        .width(16)
        .height(16)
        .fillColor($r('app.color.icon_secondary'))
      TextInput({ text: this.text, placeholder: this.placeholder })
        .id(this.inputId)
        .layoutWeight(1)
        .height(38)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_secondary'))
        .backgroundColor(Color.Transparent)
        .onChange((value: string): void => {
          this.onInput(value);
        })
      if (this.showClear && this.text.length > 0) {
        Image($r('app.media.aura_close'))
          .width(18)
          .height(18)
          .fillColor($r('app.color.icon_secondary'))
          .onClick((): void => {
            this.onClear();
          })
      }
    }
    .width('100%')
    .height(40)
    .borderRadius(20)
    .backgroundColor($r('app.color.glass_tint'))
    .border({ width: 0.5, color: $r('app.color.divider') })
    .shadow({ radius: 10, color: $r('app.color.shadow'), offsetY: 2 })
    .padding({ left: 12, right: 12 })
  }
}

// 无图标的导航行（文字型操作，如"更多设置"）。
@Component
export struct AuraNavRow {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop value: string = '';
  @Prop showChevron: boolean = true;
  @Prop danger: boolean = false;
  @Prop showDivider: boolean = true;
  onTap: () => void = (): void => {};

  build() {
    Column() {
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text(this.title)
            .fontSize(16)
            .fontColor(this.danger ? $r('app.color.danger') : $r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          if (this.subtitle.length > 0) {
            Text(this.subtitle)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.value.length > 0) {
          Text(this.value)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
        }
        if (this.showChevron) {
          AuraChevron()
        }
      }
      .width('100%')
      .constraintSize({ minHeight: 56 })
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .onClick(() => {
        this.onTap();
      })

      if (this.showDivider) {
        Divider()
          .color($r('app.color.divider'))
          .margin({ left: 16 })
      }
    }
    .width('100%')
  }
}
