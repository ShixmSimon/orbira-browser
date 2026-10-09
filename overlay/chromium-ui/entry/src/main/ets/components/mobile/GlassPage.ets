/*
 * 全屏页统一外壳 v6（2026-10-10）：改用华为官方 HdsNavigation。
 *
 * 为什么换：手搓纱幕（v5）不像官方观感、且 expandSafeArea 没把内容顶进
 * 状态栏。HdsNavigation 是 dock 同源的 HDS 组件（真机已验证材质可渲染），
 * 标题栏自带「渐变模糊滚动效果」（ScrollEffectType.GRADIENT_BLUR）+
 * 沉浸光感材质（systemMaterialEffect ADAPTIVE），状态栏/安全区全部由
 * HDS 内部处理 —— 这就是「直接用鸿蒙特性」。
 *
 * 结构约定：
 *   - 内容视口通过 ignoreLayoutSafeArea(SYSTEM/TOP) 顶到 y=0：滚动内容
 *     从状态栏和标题行底下穿过（顶部虚化包含状态栏）。
 *   - 各页滚动内容顶部内边距 = glassHeaderInsetVp()（= S+56+16），
 *     静态时首行内容正好落在标题行下方 16vp 处。
 *   - 滚动效果需要 bindToScrollable 绑定本页 Scroller（官方要求），
 *     由各面板创建 Scroller 并经 scrollers 参数传入（多视图页传数组）。
 *   - 返回钮/标题由 HDS 按系统规范绘制（沉浸光感自动作用在标题栏按钮上），
 *     不再自绘 GlassBackButton/GlassContentHeader（书签/密码/扩展三个
 *     自包面板暂未迁移，仍在用这两个导出件）。
 */
import { curves } from '@kit.ArkUI';
import uiMaterial from '@ohos.arkui.uiMaterial';
import {
  hdsMaterial,
  HdsNavigation,
  HdsNavigationMenuContentOptions,
  HdsNavigationTitleMode,
  ScrollEffectType
} from '@kit.UIDesignKit';
import {
  glassFallbackColor,
  glassFallbackShadow,
  glassMaterial,
  GlassRole,
  glassNoneShadow,
  GlassScope
} from '../../utils/appearance/GlassMaterial';

/** HDS MINI 标题行高度（vp），与官方 TITLE_BAR_HEIGHT_MINI 一致。 */
export const GLASS_TITLE_BAR_HEIGHT_VP: number = 56;

/** 标题行下方的间隙 + 渐隐带宽度（vp），用户定「约一个标题字高」。 */
export const GLASS_TITLE_ZONE_VP: number = 16;

/** 状态栏高度（vp），AuraShell 启动时写入 AppStorage。 */
export function glassTopSafeVp(): number {
  return Number(AppStorage.get('auraTopSafeVp') ?? 0);
}

/**
 * 各页**滚动内容**的顶部内边距（vp）= 状态栏 + 标题行 + 间隙渐隐带。
 * HdsNavigation 内容视口已通过 ignoreLayoutSafeArea 顶到 y=0，
 * 静态时首行内容正好落在标题行下方 16vp 处；滚动时内容从状态栏/
 * 标题行底下穿过，被官方渐变模糊逐渐盖住。
 */
export function glassHeaderInsetVp(): number {
  return glassTopSafeVp() + GLASS_TITLE_BAR_HEIGHT_VP + GLASS_TITLE_ZONE_VP;
}

/**
 * 圆形玻璃返回钮 —— 仅供尚未迁移 HdsNavigation 的自包面板使用
 * （书签/密码/扩展）。GlassPage 本体已改用 HDS 标题栏自带的返回钮。
 *
 * 材质生效时：系统毛玻璃 + 自带描边阴影 + interactive 按压形变 + 触摸流光。
 * 材质不可用时：退回 glass_tint 半透明圆底，并**自己补一个弹性缩放**。
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
    .backgroundColor(this.glass === undefined ? glassFallbackColor() : Color.Transparent)
    .borderWidth(this.glass === undefined ? 0.5 : 0)
    .borderColor($r('app.color.divider'))
    .shadow(this.glass === undefined ? glassFallbackShadow() : glassNoneShadow())
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
 * 顶部纱幕 —— 仅供尚未迁移 HdsNavigation 的自包面板使用（书签/密码/扩展）。
 * GlassPage 本体的顶部虚化已交由 HDS 官方渐变模糊 + 沉浸光感材质。
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
 * 一页「HDS 官方标题栏 + 顶部虚化包含状态栏」。用法（尾随闭包，别传方法引用）：
 *
 *   GlassPage({
 *     title: '书签',
 *     onBack: (): void => { this.onBack(); },
 *     scrollers: [this.listScroller]   // 本页滚动容器的 Scroller（官方要求绑定）
 *   }) {
 *     Column() { ...滚动内容的 Column 记得 .padding({ top: glassHeaderInsetVp() })... }
 *   }
 */
@Component
export struct GlassPage {
  @Prop title: string = '';
  onBack: () => void = (): void => {};
  /** 本页滚动容器的 Scroller（渐变模糊滚动效果按官方要求绑定它们）。 */
  scrollers: Scroller[] = [];
  /** 标题栏右侧动作（HDS menu，可选；书签/密码等带操作按钮的页面传入）。 */
  menus?: HdsNavigationMenuContentOptions;
  @BuilderParam body: () => void;

  build() {
    HdsNavigation() {
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          this.body()
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
    }
    .titleBar({
      content: {
        title: { mainTitle: this.title },
        backIcon: {
          icon: $r('app.media.aura_back'),
          isEnabled: true,
          action: (): void => {
            this.onBack();
          }
        },
        menu: this.menus
      },
      style: {
        // 官方渐变模糊滚动效果 + 沉浸光感材质（两者配套才是完整的
        // 沉浸光感渐变模糊，见 HDS 组件材质官方指南）。
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      // true = 标题行避开状态栏（返回钮/标题在状态栏下方，真机反馈要求）；
      // 材质纱幕仍会覆盖状态栏区域，内容从它后面穿过时是虚化的。
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: false
    })
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(false)
    .mode(NavigationMode.Stack)
    // 内容视口四边到屏幕物理边缘：顶部从状态栏后面穿过，
    // 底部直达指示条后面（真机反馈「底部隔着导航条没到底缘」）。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .bindToScrollable(this.scrollers)
    .backgroundColor($r('app.color.page_background'))
    .width('100%')
    .height('100%')
  }
}
