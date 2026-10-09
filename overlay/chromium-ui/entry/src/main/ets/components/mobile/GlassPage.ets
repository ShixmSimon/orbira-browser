/*
 * 全屏页 + 沉浸光感标题栏的统一外壳（v3，2026-10-10 真机反馈定稿）。
 *
 * 布局（从上到下）：
 *   ① 状态栏区（系统，页面实底延伸上去）
 *   ② Navigation 标题栏：圆形玻璃返回钮 + 页面标题（22fp）并排一行。
 *      —— 材质必须落在 Navigation 标题栏里才生效（HarmonyOS 7 收紧沉浸光感
 *      范围，见 GlassMaterial.ets 文件头），所以返回钮留在标题栏里。
 *   ③ 内容区从标题栏下方开始（barStyle 用默认 STANDARD——SDK 注释明写
 *      "title bar is laid out above the content area"；此前用的 STACK 是
 *      "overlaid on top of the content area"，内容顶到状态栏下面，这就是
 *      前两版标题/内容跟返回钮重叠改不掉的根源）。
 *   ④ 内容区顶部有一条 GLASS_TITLE_ZONE_VP(28) 的渐隐带：滚动上来的内容
 *      在贴近标题栏时逐渐淡出（对齐系统设置的观感）。各页滚动内容顶部
 *      留同样的内边距，静态时首行正好落在渐隐带下缘。
 *
 * 实底原则不变：Navigation 与内容层都铺 page_background，玻璃只用在
 * 标题栏那颗圆钮（和菜单卡）上。
 */
import { curves } from '@kit.ArkUI';
import uiMaterial from '@ohos.arkui.uiMaterial';
import {
  glassFallbackColor,
  glassFallbackShadow,
  glassMaterial,
  GlassRole,
  glassNoneShadow,
  GlassScope
} from '../../utils/appearance/GlassMaterial';

/** 标题栏高度（vp）：返回钮 + 标题并排的一行。 */
export const GLASS_TITLE_BAR_HEIGHT_VP: number = 56;

/**
 * 内容区顶部渐隐带高度（vp）。
 * 各页面要把它加在**滚动内容**的顶部内边距里（不是外层容器），
 * 静态时首行内容正好落在渐隐带下缘，滚动时内容会在贴近标题栏处逐渐淡出。
 * 真机反馈 28 偏大（「内容和标题间隙过大」），收到 12。
 */
export const GLASS_TITLE_ZONE_VP: number = 12;

/**
 * 圆形玻璃返回钮（对齐系统「软件更新」标题栏那颗）。
 *
 * 材质生效时：系统毛玻璃 + 自带描边阴影 + interactive 按压形变 + 触摸流光。
 * 材质不可用时：退回 glass_tint 半透明圆底，并**自己补一个弹性缩放**，
 * 保证「按下去会弹」在任何设备上都能看到（用户明确要的体感）。
 */
@Component
export struct GlassBackButton {
  onAction: () => void = (): void => {};
  @State private pressed: boolean = false;
  // 允许区（Navigation 标题栏内）→ 材质会真的渲染。
  private readonly glass: uiMaterial.Material | undefined =
    glassMaterial(GlassRole.CONTROL, GlassScope.HOST);

  build() {
    Column() {
      Image($r('app.media.aura_back'))
        .width(22)
        .height(22)
        .fillColor($r('app.color.icon_primary'))
    }
    .width(44)
    .height(44)
    .borderRadius(22)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .systemMaterial(this.glass)
    // 官方约定：材质自己管 backgroundColor / borderColor / borderWidth / shadow，
    // 生效时不要和这四项叠着用（会把材质盖住）。所以只在退档时自绘。
    .backgroundColor(this.glass === undefined ? glassFallbackColor() : Color.Transparent)
    .borderWidth(this.glass === undefined ? 0.5 : 0)
    .borderColor($r('app.color.divider'))
    .shadow(this.glass === undefined ? glassFallbackShadow() : glassNoneShadow())
    // 手写弹性只在没有材质时接管：有材质时系统 interactive 已经给了果冻形变，
    // 再叠一层 scale 会「弹两次」。
    .scale({ x: this.pressed ? 0.88 : 1, y: this.pressed ? 0.88 : 1 })
    .accessibilityText('返回')
    .onTouch((event: TouchEvent): void => {
      if (this.glass !== undefined) {
        return;
      }
      if (event.type === TouchType.Down) {
        animateTo({ duration: 90, curve: Curve.FastOutSlowIn }, (): void => {
          this.pressed = true;
        });
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        animateTo({ curve: curves.springMotion(0.3, 0.7) }, (): void => {
          this.pressed = false;
        });
      }
    })
    .onClick(() => {
      this.onAction();
    })
  }
}

/**
 * 内容区顶部的渐隐带：page_background 实底 → 透明的渐变遮罩。
 *
 * 放在页面内容层「Stack 的最上面」盖住滚上来的内容；自身不参与触摸测试，
 * 滚动/点击全部从它底下穿过去。
 */
@Component
export struct GlassContentHeader {
  build() {
    Column()
      .width('100%')
      .height(GLASS_TITLE_ZONE_VP)
      .linearGradient({
        angle: 180,
        colors: [
          [$r('app.color.page_background'), 0.0],
          [$r('app.color.page_background_fade'), 1.0]
        ]
      })
      .hitTestBehavior(HitTestMode.None)
  }
}

/**
 * 一页「全屏实底 + 玻璃标题栏」。用法（尾随闭包，别传方法引用）：
 *
 *   GlassPage({ title: '书签', onBack: (): void => { this.onBack(); } }) {
 *     Column() { ...原本的页面内容，滚动内容记得留 GLASS_TITLE_ZONE_VP 顶内边距... }
 *   }
 */
@Component
export struct GlassPage {
  @Prop title: string = '';
  onBack: () => void = (): void => {};
  @BuilderParam body: () => void;

  @Builder
  private TitleBar() {
    Row({ space: 12 }) {
      GlassBackButton({
        onAction: (): void => {
          this.onBack();
        }
      })
      Text(this.title)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height(GLASS_TITLE_BAR_HEIGHT_VP)
    .padding({ left: 16, right: 16 })
  }

  build() {
    Navigation() {
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          this.body()
        }
        .width('100%')
        .height('100%')

        GlassContentHeader()
      }
      .width('100%')
      .height('100%')
    }
    // 标题栏由我们自绘（返回钮 + 标题并排），系统返回箭头让位。
    // barStyle 不传 = STANDARD：内容区从标题栏下方开始，重叠物理上不可能。
    .hideBackButton(true)
    .titleMode(NavigationTitleMode.Mini)
    .title(this.TitleBar)
    .mode(NavigationMode.Stack)
    .backgroundColor($r('app.color.page_background'))
    .width('100%')
    .height('100%')
  }
}
