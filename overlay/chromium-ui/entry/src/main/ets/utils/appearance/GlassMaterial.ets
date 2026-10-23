/*
 * 沉浸光感「真材质」统一入口（ArkUI 标准轨道 uiMaterial）。
 *
 * ⚠️ 生效范围（关键，2026-09-03 官方变更 · 仅当 targetSdkVersion ≥ 26.0.0 生效）：
 *   HarmonyOS 7 Release 出于性能/功耗考虑，收紧了第三方应用调用沉浸光感的范围。
 *   收窄后仍会真正渲染材质的只有这几类 ——
 *
 *     · 弹窗类组件：AlertDialog / ActionSheet / CustomDialog / 各类 Picker /
 *       SelectionMenu / 文本选择菜单
 *     · 弹窗类接口：PromptAction / Popup / Tips / **菜单控制(bindMenu /
 *       bindContextMenu)** / 半模态转场(bindSheet)
 *     · Slider / Toggle / Select
 *     · Navigation / NavDestination 标题栏
 *     · 横向 Tabs 且 barPosition = BarPosition.End 的底部 TabBar（dock 走的就是这条）
 *
 *   **页面内容区里的普通 Column / Row / Stack / Button 一律不再生效**，而且是
 *   「静默失效」：hilog 里只有一行
 *       Material inactive: out of scope. Use component in navigation title bar or Tabbar.
 *   但肉眼看到的是「卡片整个变透明」——因为材质依然接管了 backgroundColor，而
 *   我们按官方约定又把底色让给了材质，两头落空就只剩全透明。
 *
 *   所以本模块把「位置」提升为显式参数（GlassScope）：
 *     HOST —— 上面那些允许区（弹窗/菜单内部、Navigation 标题栏内），返回真材质；
 *     FREE —— 自由区（内容区里的自绘卡片、工具栏、圆钮），**故意返回 undefined**，
 *             让调用方走自绘半透明玻璃，绝不出现「看不见」的回归。
 *
 * 材质本身给到的东西（真机验证过才相信）：
 *   - 毛玻璃（ImmersiveStyle 决定模糊强度 + 底色厚度）
 *   - applyShadow 系统自带宽阴影
 *   - interactive 按压形变（果冻手感，系统托管）
 *   - lightEffect 触摸流光（「高光偏在一侧、跟着手指流动」就是它）
 */
import uiMaterial from '@ohos.arkui.uiMaterial';

/** 材质档位：按承载内容挑厚度，别按设备硬编码。 */
export enum GlassRole {
  /** 悬浮卡片 / 菜单 / 弹窗：要压得住下层网页，正文才读得清。 */
  CARD = 0,
  /** 小圆钮 / 胶囊控件：更透，保留底层网页的色彩。 */
  CONTROL = 1
}

/**
 * 组件所在位置 —— 决定 systemMaterial 会不会真的渲染。
 * 传错只会「没材质」，但 FREE 传成 HOST 会直接「整块透明」，所以默认值是 FREE。
 */
export enum GlassScope {
  /** 允许区：弹窗/菜单/半模态内部，或 Navigation / NavDestination 标题栏内。 */
  HOST = 0,
  /** 自由区：页面内容区的普通容器。系统不会渲染材质（见文件头）。 */
  FREE = 1
}

let cachedSupported: boolean | undefined = undefined;

/** 设备是否支持系统沉浸材质（结果缓存，只在首次真调一次系统接口）。 */
export function immersiveGlassSupported(): boolean {
  if (cachedSupported === undefined) {
    try {
      cachedSupported = uiMaterial.isImmersiveMaterialSupported();
    } catch (error) {
      // 低版本 SDK / 老设备上该命名空间直接抛异常，视为不支持。
      cachedSupported = false;
    }
  }
  return cachedSupported;
}

/**
 * 造一个可挂到 systemMaterial() / Options.systemMaterial 上的材质对象。
 * scope = FREE 或设备不支持时返回 undefined —— 调用方据此回退自绘兜底色。
 */
export function glassMaterial(role: GlassRole, scope: GlassScope): uiMaterial.Material | undefined {
  if (scope !== GlassScope.HOST) {
    // 自由区的 systemMaterial 不会渲染，却会把 backgroundColor 顶掉 →
    // 宁可返回 undefined 走自绘玻璃，也不要一张看不见的卡片。
    return undefined;
  }
  if (!immersiveGlassSupported()) {
    return undefined;
  }
  const style: uiMaterial.ImmersiveStyle = role === GlassRole.CARD ?
    uiMaterial.ImmersiveStyle.THICK : uiMaterial.ImmersiveStyle.THIN;
  try {
    return new uiMaterial.ImmersiveMaterial({
      style: style,
      applyShadow: true,
      interactive: true,
      lightEffect: { color: Color.White }
    });
  } catch (error) {
    return undefined;
  }
}

/** 材质不可用时的自绘兜底色（浅色 #E0F7F7F8 / 深色 #E029292C）。 */
export function glassFallbackColor(): ResourceColor {
  return $r('app.color.glass_tint');
}

/** 材质不可用时的自绘阴影。材质生效时不要用（材质自带 shadow）。 */
export function glassFallbackShadow(): ShadowOptions {
  return { radius: 26, color: $r('app.color.shadow'), offsetY: 8 };
}

/** 材质生效时用的「无底色」占位。 */
export function glassNoneShadow(): ShadowOptions {
  return { radius: 0, color: Color.Transparent, offsetY: 0 };
}
