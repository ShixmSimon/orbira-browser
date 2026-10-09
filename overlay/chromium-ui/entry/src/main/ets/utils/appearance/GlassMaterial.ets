/*
 * 沉浸光感「真材质」统一入口（ArkUI 标准轨道 uiMaterial）。
 *
 * 与 dock 走的 HDS 轨道（HdsTabs + systemMaterialEffect）并列，是第二条系统材质路径：
 *   uiMaterial.ImmersiveMaterial 通过 CommonMethod.systemMaterial() 挂到**任意组件**
 *   上 —— 这是 API 26.0.0 才开放到通用组件的写法（本工程 targetSdkVersion = 26.0.0）。
 *
 * 拿到的是系统级真效果，不是自绘半透明纯色能比的：
 *   - 毛玻璃（风格档位 ImmersiveStyle 决定模糊强度 + 底色厚度）
 *   - applyShadow 系统自带宽阴影（比自绘 shadow 更贴材质边缘）
 *   - interactive 按压形变（果冻手感，系统托管，无需自写动画曲线）
 *   - lightEffect 触摸流光 —— 就是「高光偏在一侧、跟着手指流动」的那个光效，
 *     与 dock 栏按压流光同一套系统能力
 *
 * 调用约定（重要）：
 *   1) 材质会接管 backgroundColor / borderColor / borderWidth / shadow，
 *      挂了材质的节点**不要再自绘这四项**，否则会把材质压住。
 *   2) 设备不支持（低算力机 / 用户在系统里关掉沉浸光感）时本函数返回 undefined，
 *      调用方此时退回 glass_tint 自绘兜底，外观不退化。
 */
import uiMaterial from '@ohos.arkui.uiMaterial';

/** 材质档位：按承载内容挑厚度，别按设备硬编码。 */
export enum GlassRole {
  /** 悬浮卡片 / 菜单 / 弹窗：要压得住下层网页，正文才读得清。 */
  CARD = 0,
  /** 小圆钮 / 胶囊控件：更透，保留底层网页的色彩。 */
  CONTROL = 1
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
 * 造一个可挂到 systemMaterial() 上的材质对象。
 * 设备不支持时返回 undefined —— 调用方据此回退自绘兜底色。
 */
export function glassMaterial(role: GlassRole): uiMaterial.Material | undefined {
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
