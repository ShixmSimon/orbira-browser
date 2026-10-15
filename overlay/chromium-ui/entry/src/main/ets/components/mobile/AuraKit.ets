/*
 * 共享件（卡片式视觉）。
 *
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
