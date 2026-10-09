/*
 * 全屏页 + 沉浸光感标题栏的统一外壳（v5，2026-10-10「顶部虚化包含状态栏」）。
 *
 * 布局（从上到下）：
 *   ① 状态栏区 [0, S)：滚动内容会**穿到它后面**（虚化可见），系统时钟/图标
 *      由系统画在最上层。
 *   ② Navigation 标题栏 [S, S+56)：圆形玻璃返回钮 + 页面标题（22fp）并排，
 *      悬浮在内容上层（barStyle: STACK）。Row 自身 hitTestBehavior(None)，
 *      滚动手势可以从标题行穿过（按钮自己仍可点）。
 *   ③ 内容区：STACK 模式下从状态栏下沿开始，再对内容根节点 expandSafeArea
 *      把视口顶到 y=0 —— 滚动时内容从状态栏和标题行底下穿过。
 *   ④ 虚化幕布 GlassContentHeader：从 y=0 铺到 S+56+16，85% page_background
 *      「纱幕」盖住状态栏+标题行（内容隐约可见），标题行下方 16vp 渐隐到 0。
 *      各页滚动内容顶部内边距 = glassHeaderInsetVp()（= S+56+16，动态含状态栏）。
 *
 * ⚠️ 几何全部由 AppStorage 的 auraTopSafeVp（状态栏高度，AuraShell 启动时写入）
 *    推导，不要手写常量 —— 前两版「标题/内容和返回钮重叠」就是拍脑袋定位的后果。
 * ⚠️ barStyle 必须显式 STACK：SDK 注释 STANDARD="标题栏排在内容区上方"（内容
 *    到不了状态栏后面），STACK="标题栏悬浮在内容区上方"。重叠问题由上面的
 *    动态内边距解决，不再靠换 barStyle。
 *
 * 实底原则不变：Navigation 与内容层都铺 page_background，玻璃只用在标题栏
 * 那颗圆钮（和菜单卡）上。虚化幕布只对**原生滚动内容**生效（同窗口采样），
 * 网页 SURFACE 上方的浮层仍然禁用模糊（见 MobileBrowserOverlay 菜单卡注释）。
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

/** 标题行下方的间隙 + 渐隐带宽度（vp），用户定「约一个标题字高」。 */
export const GLASS_TITLE_ZONE_VP: number = 16;

/** 状态栏高度（vp），AuraShell 启动时写入 AppStorage。 */
export function glassTopSafeVp(): number {
  return Number(AppStorage.get('auraTopSafeVp') ?? 0);
}

/**
 * 各页**滚动内容**的顶部内边距（vp）= 状态栏 + 标题行 + 间隙渐隐带。
 * 静态时首行内容正好落在渐隐带下缘；滚动时内容从状态栏/标题行底下穿过，
 * 被 85% 纱幕逐渐盖住（真机反馈：顶部虚化要包含状态栏）。
 */
export function glassHeaderInsetVp(): number {
  return glassTopSafeVp() + GLASS_TITLE_BAR_HEIGHT_VP + GLASS_TITLE_ZONE_VP;
}

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
 * 顶部虚化幕布：从屏幕最顶端（含状态栏）铺到标题行下方渐隐带底部。
 *
 * 85% 纱幕盖住状态栏+标题行 —— 滚上来的内容在这里隐约可见（虚化），
 * 标题行下方 16vp 渐隐到 0。放在页面内容层 Stack 的最上面；
 * 自身不参与触摸测试，滚动/点击全部从它底下穿过去。
 */
@Component
export struct GlassContentHeader {
  @StorageProp('auraTopSafeVp') topSafeVp: number = 0;

  build() {
    Column()
      .width('100%')
      .height(this.topSafeVp + GLASS_TITLE_BAR_HEIGHT_VP + GLASS_TITLE_ZONE_VP)
      .linearGradient({
        angle: 180,
        colors: [
          [$r('app.color.page_background_veil'), 0.0],
          [$r('app.color.page_background_veil'),
            (this.topSafeVp + GLASS_TITLE_BAR_HEIGHT_VP) /
            (this.topSafeVp + GLASS_TITLE_BAR_HEIGHT_VP + GLASS_TITLE_ZONE_VP)],
          [$r('app.color.page_background_fade'), 1.0]
        ]
      })
      .hitTestBehavior(HitTestMode.None)
  }
}

/**
 * 一页「全屏实底 + 玻璃标题栏 + 顶部虚化」。用法（尾随闭包，别传方法引用）：
 *
 *   GlassPage({ title: '书签', onBack: (): void => { this.onBack(); } }) {
 *     Column() { ...滚动内容的 Column 记得 .padding({ top: glassHeaderInsetVp() })... }
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
    // 标题行浮在滚动内容上层（STACK），行内非按钮区域让手势穿过去，
    // 否则标题行那 56vp 会成为滚动手势死区。
    .hitTestBehavior(HitTestMode.None)
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
      // 内容视口顶到屏幕最顶端：滚动内容才能从状态栏后面穿过（用户要求
      // 「顶部虚化包含状态栏」）。STACK 把标题行悬浮到内容上层。
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    }
    .hideBackButton(true)
    .titleMode(NavigationTitleMode.Mini)
    .title(this.TitleBar, { barStyle: BarStyle.STACK })
    .mode(NavigationMode.Stack)
    .backgroundColor($r('app.color.page_background'))
    .width('100%')
    .height('100%')
  }
}
