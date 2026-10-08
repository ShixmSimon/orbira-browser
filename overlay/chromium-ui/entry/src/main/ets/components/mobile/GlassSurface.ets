/*
 * GlassSurface -- the shared material face for the floating shell bars.
 *
 * Two tracks, one face (pattern studied from the Aira browser; see
 * AIRA-REFERENCE-NOTES.md):
 *
 * 1. HDS backplate: an HdsTabs rendered as a bare backplate carries the
 *    system immersive-light material anywhere in the tree (6.1.0(23)+, no
 *    Navigation title bar / TabBar scope needed). uiMaterial cannot do this:
 *    its scope contract silently drops the effect on a free-floating Row,
 *    which is why the bars were painted by hand before. HDS is the way in.
 *
 * 2. Painted fallback: translucent resource color + component blur +
 *    hairline rim, used when the device cannot render the material (old
 *    system, material switch off, probe threw).
 *
 * The two tracks never stack. Whichever runs, the other contributes nothing:
 * a fill or border drawn on top of the material is exactly what hid it in
 * the earlier attempt (UI-DESIGN-SPEC.md section 8).
 */
import { hdsMaterial, HdsTabs, HdsTabsController, HdsTabsFloatingStyle } from '@kit.UIDesignKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

// One probe per process. getSystemMaterialTypes() reports what this device
// can actually render; all-NONE means a backplate would paint nothing, and
// any throw (older SDK) means the same. Read once, cached.
let cachedHdsMaterialAvailable: boolean | undefined = undefined;

export function isHdsMaterialAvailable(): boolean {
  if (cachedHdsMaterialAvailable !== undefined) {
    return cachedHdsMaterialAvailable;
  }
  try {
    const types: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
    cachedHdsMaterialAvailable = types.some((type: hdsMaterial.MaterialType): boolean =>
      type !== hdsMaterial.MaterialType.NONE);
  } catch (error) {
    cachedHdsMaterialAvailable = false;
  }
  hilog.info(0x0000, 'AuraGlass',
    'HDS immersive material available: %{public}s', String(cachedHdsMaterialAvailable));
  return cachedHdsMaterialAvailable;
}

// A bare HdsTabs whose only job is to materialize its bar. Geometry notes
// carried over from the reference study, all learned the hard way:
// - barOverlap must stay true with vertical false and barPosition End, or
//   the floating material never appears and the plate renders transparent;
// - a floating bar sizes itself from its tab count, so barWidth must carry
//   the concrete vp width on every breakpoint, or a single-item bar
//   collapses into a centered sliver;
// - the plate is rectangular underneath, so the host clips it to its own
//   outline -- anything that needs a drop shadow draws it on its own layer.
@Component
export struct HdsGlassBackplate {
  @Prop plateWidth: number = 0;
  @Prop plateHeight: number = 0;
  private controller: HdsTabsController = new HdsTabsController();

  build() {
    HdsTabs({ controller: this.controller }) {
      TabContent() {
        Column()
          .width('100%')
          .height('100%')
      }
      .tabBar(this.transparentBar)
    }
    .vertical(false)
    .scrollable(false)
    .barMode(BarMode.Fixed)
    .barPosition(BarPosition.End)
    .barOverlap(true)
    .barWidth(this.plateWidth)
    .barHeight(this.plateHeight)
    .barBackgroundColor(Color.Transparent)
    .barBackgroundBlurStyle(BlurStyle.NONE)
    .barFloatingStyle(this.resolveFloatingStyle())
    .width('100%')
    .height('100%')
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  private transparentBar() {
    // The bar must be physically present for HDS to materialize onto it,
    // but it carries no visible content of its own.
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
  }

  private resolveFloatingStyle(): HdsTabsFloatingStyle {
    const width: number = Math.max(1, this.plateWidth);
    const style: HdsTabsFloatingStyle = {
      barSideMargin: 0,
      barBottomMargin: 0,
      barOpacity: 1,
      // Symbolic widths are ignored here; the concrete vp width is required
      // on all three breakpoints.
      barWidth: {
        smallWidth: width,
        mediumWidth: width,
        largeWidth: width
      },
      // ADAPTIVE lets the system pick the material strength for the device,
      // which the power guidance recommends over pinning a level per class.
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    };
    return style;
  }
}

// The shared face: callers set the outer geometry (width / height / shadow)
// on the instance; the surface fills it and decides which material track
// runs. The fallback fill and the rim are drawn on their own layers rather
// than as component attributes, so the material track never has to fight a
// fill that would cover it.
@Component
export struct GlassSurface {
  @Prop fallbackColor: ResourceColor = $r('app.color.glass_tint');
  @Prop fallbackBlurStyle: BlurStyle = BlurStyle.COMPONENT_REGULAR;
  @Prop cornerRadius: number = 22;
  @Prop edgeHighlightWidth: number = 0.5;
  @Prop edgeHighlightColor: ResourceColor = $r('app.color.divider');
  @BuilderParam content: () => void = this.emptyBuilder;

  // Measured on the first layout pass; the HDS plate needs concrete vp
  // numbers, so it is mounted a frame later than the fallback would be.
  @State private measuredWidth: number = 0;
  @State private measuredHeight: number = 0;
  private readonly hdsAvailable: boolean = isHdsMaterialAvailable();

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.usesMaterial()) {
        if (this.measuredWidth > 0 && this.measuredHeight > 0) {
          HdsGlassBackplate({
            plateWidth: this.measuredWidth,
            plateHeight: this.measuredHeight
          })
        }
      } else {
        Stack()
          .width('100%')
          .height('100%')
          .backgroundColor(this.fallbackColor)
          .hitTestBehavior(HitTestMode.None)
      }

      this.content()

      if (!this.usesMaterial() && this.edgeHighlightWidth > 0) {
        Stack()
          .width('100%')
          .height('100%')
          .borderRadius(this.cornerRadius)
          .border({ width: this.edgeHighlightWidth, color: this.edgeHighlightColor })
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    .borderRadius(this.cornerRadius)
    .clip(true)
    .backgroundBlurStyle(
      this.usesMaterial() ? BlurStyle.NONE : this.fallbackBlurStyle,
      { adaptiveColor: AdaptiveColor.AVERAGE, policy: BlurStyleActivePolicy.ALWAYS_ACTIVE })
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      this.onMeasured(Number(newValue.width), Number(newValue.height));
    })
  }

  @Builder
  private emptyBuilder() {
  }

  private usesMaterial(): boolean {
    return this.hdsAvailable;
  }

  private onMeasured(width: number, height: number): void {
    if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
      return;
    }
    if (width === this.measuredWidth && height === this.measuredHeight) {
      return;
    }
    this.measuredWidth = width;
    this.measuredHeight = height;
  }
}
