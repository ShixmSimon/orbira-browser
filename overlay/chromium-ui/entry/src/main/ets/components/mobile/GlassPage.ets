/*
 * 全屏页 + 沉浸光感标题栏的统一外壳。
 *
 * 为什么不是「自己画一个 Row 当标题栏」：
 *   HarmonyOS 7 收紧沉浸光感生效范围后，systemMaterial 只在
 *   Navigation/NavDestination 标题栏、底部 TabBar（barPosition=End）、
 *   以及弹窗类组件/接口里才会渲染（见 GlassMaterial.ets 文件头）。
 *   设置页、书签页这些是「页面内容区」，自己画的标题栏挂材质 = 静默失效，
 *   而材质又会顶掉 backgroundColor → 整颗圆钮变透明。
 *   官方给的迁移方式就是：把自定义标题栏塞进 Navigation 的 title 属性。
 *   所以这里统一用 Navigation 承载标题栏，圆钮再挂材质就落在允许区里了。
 *
 * 实底原则不变：Navigation 与内容层都铺 page_background，仍是「全屏实底」
 * （UI-DESIGN-SPEC §18），玻璃只用在标题栏那颗圆钮上。
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

/** 标题栏高度（vp）：与旧的页内 Header 一致，切过去页面不跳。 */
export const GLASS_TITLE_BAR_HEIGHT_VP: number = 56;

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
 * 一页「全屏实底 + 玻璃标题栏」。用法（尾随闭包，别传方法引用）：
 *
 *   GlassPage({ title: '书签', onBack: (): void => { this.onBack(); } }) {
 *     Column() { ...原本的页面内容，不要再画 Header... }
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
      Column() {
        this.body()
      }
      .width('100%')
      .height('100%')
    }
    // 标题栏由我们自绘（圆钮 + 大字），系统返回箭头让位。
    .hideBackButton(true)
    .titleMode(NavigationTitleMode.Mini)
    .title(this.TitleBar, { barStyle: BarStyle.STACK })
    .mode(NavigationMode.Stack)
    .backgroundColor($r('app.color.page_background'))
    .width('100%')
    .height('100%')
  }
}
