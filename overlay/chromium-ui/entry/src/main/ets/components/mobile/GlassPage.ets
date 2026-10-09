/*
 * 全屏页 + 沉浸光感标题栏的统一外壳（v2，2026-10-10 真机反馈改版）。
 *
 * 布局（从上到下）：
 *   ① 状态栏区（系统，页面实底延伸上去）
 *   ② Navigation 标题栏：**只有一颗圆形玻璃返回钮**，独占一行（56vp）。
 *      —— 材质必须落在 Navigation 标题栏里才生效（HarmonyOS 7 收紧沉浸光感
 *      范围，见 GlassMaterial.ets 文件头），所以返回钮必须留在标题栏里。
 *   ③ 内容区顶部「大标题带」（GLASS_TITLE_ZONE_VP = 64vp）：
 *      大标题 + 渐变虚化遮罩，由 GlassContentHeader 画在内容层之上。
 *      各页内容在**滚动内容里**留出同样的顶部内边距，滚动时内容从大标题
 *      底下穿过、越往上越淡（对齐系统设置页"状态栏/标题 逐渐虚化"的观感）。
 *
 * 为什么标题不再和返回钮同一行：
 *   ① 用户真机反馈「标题/内容和返回按钮重叠」——两行分开最稳；
 *   ② 大标题要盖在可滚动内容上、随滚动虚化，只有放在内容层才做得到。
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

/** 标题栏（返回钮那一行）高度（vp）。 */
export const GLASS_TITLE_BAR_HEIGHT_VP: number = 56;

/**
 * 内容区顶部「返回钮行 + 大标题带」的总高度（vp）。
 * 各页面要把它加在**滚动内容**的顶部内边距里（不是外层容器），
 * 这样静态时首行内容正好落在渐隐带下缘，滚动时内容会从返回钮行/大标题
 * 底下穿过并淡出。BarStyle.STACK 下内容区从状态栏下方就开始（见
 * GlassContentHeader 文件头），所以这个值必须覆盖返回钮行(56)+大标题(约54)
 * +渐隐带(约30)，与 iOS 大标题页的首屏留白手感一致。
 */
export const GLASS_TITLE_ZONE_VP: number = 140;

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
 * 内容区顶部「返回钮行 + 大标题带」的渐隐盖片。
 *
 * ⚠️ 几何关键（真机实测 2026-10-10）：Navigation 的 title 用
 * `barStyle: BarStyle.STACK` 时，**内容区从状态栏下方就开始**，标题栏只是
 * 悬浮在内容上层（旧版「标题/内容和返回钮重叠」的根源：内容首行顶到了
 * 返回钮那一行）。所以这片盖片必须从内容区顶部一直铺到大标题带底部：
 *   - 高度 = GLASS_TITLE_ZONE_VP(140) = 返回钮行(56) + 大标题(约54) + 渐隐带(约30)
 *   - 上 78% 实底 page_background：把滚上来的内容挡在返回钮行/大标题后面
 *   - 下沿渐隐：内容在这里「逐渐虚化」（对齐系统设置页的观感）
 *   - 大标题从 56+12 处起画，和返回钮行物理错开
 * 各页滚动内容顶部内边距 = GLASS_TITLE_ZONE_VP(120)，静态时首行正好落在
 * 渐隐带下缘。整片 hitTestBehavior(None)，触摸全部穿到底下的滚动区。
 */
@Component
export struct GlassContentHeader {
  @Prop title: string = '';

  build() {
    Column() {
      Text(this.title)
        .fontSize(30)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding({ left: 20, right: 20, top: GLASS_TITLE_BAR_HEIGHT_VP + 12 })
        // 文字也不吃触摸：整条大标题带对滚动/点击完全透明。
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height(GLASS_TITLE_ZONE_VP)
    .alignItems(HorizontalAlign.Start)
    // 上段实底（返回钮行 + 大标题区干净），下沿渐隐 —— 滚动上来的内容在这里淡出。
    .linearGradient({
      angle: 180,
      colors: [
        [$r('app.color.page_background'), 0.0],
        [$r('app.color.page_background'), 0.78],
        [$r('app.color.page_background_fade'), 1.0]
      ]
    })
    .hitTestBehavior(HitTestMode.None)
  }
}

/**
 * 一页「全屏实底 + 玻璃返回钮 + 渐隐大标题」。用法（尾随闭包，别传方法引用）：
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
    Row() {
      GlassBackButton({
        onAction: (): void => {
          this.onBack();
        }
      })
      Blank()
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

        GlassContentHeader({ title: this.title })
      }
      .width('100%')
      .height('100%')
    }
    // 标题栏由我们自绘（只放返回钮），系统返回箭头让位。
    .hideBackButton(true)
    .titleMode(NavigationTitleMode.Mini)
    .title(this.TitleBar, { barStyle: BarStyle.STACK })
    .mode(NavigationMode.Stack)
    .backgroundColor($r('app.color.page_background'))
    .width('100%')
    .height('100%')
  }
}
