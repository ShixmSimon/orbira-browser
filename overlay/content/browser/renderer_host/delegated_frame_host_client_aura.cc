// Copyright 2016 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "content/browser/renderer_host/delegated_frame_host_client_aura.h"

#include "content/browser/renderer_host/render_widget_host_impl.h"
#include "content/browser/renderer_host/render_widget_host_view_aura.h"
#include "ui/aura/window.h"
#include "ui/aura/window_event_dispatcher.h"
#include "ui/aura/window_tree_host.h"
#include "ui/compositor/layer.h"
#include "ui/native_theme/native_theme.h"

namespace content {

DelegatedFrameHostClientAura::DelegatedFrameHostClientAura(
    RenderWidgetHostViewAura* render_widget_host_view)
    : render_widget_host_view_(render_widget_host_view) {}

DelegatedFrameHostClientAura::~DelegatedFrameHostClientAura() {}

ui::LayerSurface* DelegatedFrameHostClientAura::GetDelegatedFrameHostLayer()
    const {
  return render_widget_host_view_->window()->layer()->AsSurface();
}

bool DelegatedFrameHostClientAura::DelegatedFrameHostIsVisible() const {
  return render_widget_host_view_->host() &&
         !render_widget_host_view_->host()->IsHidden();
}

SkColor DelegatedFrameHostClientAura::DelegatedFrameHostGetGutterColor() const {
  // When making an element on the page fullscreen the element's background
  // may not match the page's, so use black as the gutter color to avoid
  // flashes of brighter colors during the transition.
  if (render_widget_host_view_->host() &&
      render_widget_host_view_->host()->delegate() &&
      render_widget_host_view_->host()->delegate()->IsFullscreen()) {
    return SK_ColorBLACK;
  }
#if defined(OS_OHOS)
  // EmbedSurface installs this colour on the surface layer every time a new
  // surface arrives, which is exactly the one-frame gap on a history
  // navigation. The page-driven background is white on most sites and
  // force-dark never touches it, so dark mode used to flash white for one
  // frame. Pin the gutter to the shell's dark canvas instead; the page's own
  // painting is unaffected.
  ui::NativeTheme* web_theme = ui::NativeTheme::GetInstanceForWeb();
  ui::NativeTheme* ui_theme = ui::NativeTheme::GetInstanceForNativeUi();
  if ((web_theme && web_theme->preferred_color_scheme() ==
                        ui::NativeTheme::PreferredColorScheme::kDark) ||
      (ui_theme && ui_theme->preferred_color_scheme() ==
                       ui::NativeTheme::PreferredColorScheme::kDark)) {
    return 0xFF141416;
  }
#endif
  if (render_widget_host_view_->GetBackgroundColor())
    return *render_widget_host_view_->GetBackgroundColor();
  return SK_ColorWHITE;
}

void DelegatedFrameHostClientAura::OnFrameTokenChanged(
    uint32_t frame_token,
    base::TimeTicks activation_time) {
  render_widget_host_view_->OnFrameTokenChangedForView(frame_token,
                                                       activation_time);
}

float DelegatedFrameHostClientAura::GetDeviceScaleFactor() const {
  return render_widget_host_view_->device_scale_factor_;
}

void DelegatedFrameHostClientAura::InvalidateLocalSurfaceIdOnEviction() {
  render_widget_host_view_->InvalidateLocalSurfaceIdOnEviction();
}

viz::FrameEvictorClient::EvictIds
DelegatedFrameHostClientAura::CollectSurfaceIdsForEviction() {
  viz::FrameEvictorClient::EvictIds ids;
  if (render_widget_host_view_->host()) {
    ids.embedded_ids =
        render_widget_host_view_->host()->CollectSurfaceIdsForEviction();
  }
  return ids;
}

bool DelegatedFrameHostClientAura::ShouldShowStaleContentOnEviction() {
  return render_widget_host_view_->ShouldShowStaleContentOnEviction();
}

cc::DeadlinePolicy DelegatedFrameHostClientAura::GetResizeDeadlinePolicy()
    const {
  if (render_widget_host_view_->ShouldUseDefaultDeadlineOnResize()) {
    return cc::DeadlinePolicy::UseDefaultDeadline();
  }
  return DelegatedFrameHostClient::GetResizeDeadlinePolicy();
}

}  // namespace content
