// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "chrome/browser/ui/ohos/shell_page_position_ohos.h"

#include <string>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/logging.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "chrome/browser/ui/ohos/aura_shell_runtime_bridge.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "third_party/blink/public/common/input/web_input_event.h"

namespace chrome::ohos {

namespace {

// Long enough that a flick's momentum has run out and the reader has settled,
// short enough that it is still the position they are looking at when the
// system asks where they are.
constexpr base::TimeDelta kScrollSettleDelay = base::Milliseconds(300);

// If the page never finishes loading -- a video stream, an advert that hangs
// -- the position is restored anyway rather than never.
constexpr base::TimeDelta kRestoreFallbackDelay = base::Seconds(4);

// A moment later than the load event, so pages that fill in their content
// from script have laid out before their scrollability is judged. Reading
// too early reported a normal feed as "cannot scroll" and pinned its bar.
constexpr base::TimeDelta kLoadProbeDelay = base::Milliseconds(600);

// Both numbers the shell needs, in CSS pixels, read from the document rather
// than from the compositor: the compositor's copy of the scroll offset is
// marked "only sent during tests" and its document size is compiled in for
// Android and iOS only.
//
// scrollHeight is taken from whichever of the two roots is larger, because
// which one scrolls depends on the page's own CSS.
constexpr char16_t kReadPositionScript[] =
    uR"(JSON.stringify({
      scrollX: Math.round(window.scrollX),
      scrollY: Math.round(window.scrollY),
      // 1 = the page can scroll (so the reader can collapse the top bar),
      // 0 = it cannot, either because the document fits the viewport or a
      // modal has locked scrolling. Reported to the shell, which pins the
      // top bar on such a page; the engine itself changes no geometry here.
      scrollable: (function() {
        try {
          // While the document is still filling in, say "scrollable" -- a
          // half-built page must never pin the top bar.
          if (document.readyState !== 'complete') { return 1; }
          var de = document.documentElement;
          var b = document.body;
          var root = de || b;
          if (!root) { return 1; }
          var cs = window.getComputedStyle(root);
          var bs = b ? window.getComputedStyle(b) : null;
          if (cs.overflowY === 'hidden' || cs.overflow === 'hidden' ||
              (bs && (bs.overflowY === 'hidden' || bs.overflow === 'hidden'))) {
            return 0;
          }
          var h = Math.max(de ? de.scrollHeight : 0, b ? b.scrollHeight : 0);
          var v = window.innerHeight || (de ? de.clientHeight : 0);
          return (h - v > 24) ? 1 : 0;
        } catch (err) {}
        return 1;
      })(),
      pageWidth: Math.round(Math.max(
          document.documentElement ? document.documentElement.scrollWidth : 0,
          document.body ? document.body.scrollWidth : 0)),
      pageHeight: Math.round(Math.max(
          document.documentElement ? document.documentElement.scrollHeight : 0,
          document.body ? document.body.scrollHeight : 0))
    }))";

std::optional<base::DictValue> ParsePosition(const base::Value& result) {
  if (!result.is_string()) {
    return std::nullopt;
  }
  std::optional<base::DictValue> parsed = base::JSONReader::ReadDict(
      result.GetString(), base::JSON_PARSE_CHROMIUM_EXTENSIONS);
  if (!parsed || !parsed->FindDouble("pageHeight")) {
    return std::nullopt;
  }
  return parsed;
}

void ReadPosition(content::WebContents* contents,
                  base::OnceCallback<void(base::Value)> done) {
  if (!contents) {
    return;
  }
  content::RenderFrameHost* frame = contents->GetPrimaryMainFrame();
  if (!frame || !frame->IsRenderFrameLive()) {
    return;
  }
  // An isolated world, so a page cannot see itself being asked, nor answer
  // with something of its own by redefining JSON.stringify.
  frame->ExecuteJavaScriptInIsolatedWorld(kReadPositionScript, std::move(done),
                                          ISOLATED_WORLD_ID_CHROME_INTERNAL);
}

// Watches one tab: reports where the page ended up each time scrolling stops,
// and, when the shell asked for it, puts the page back where it was on the
// device the reader came from.
class PagePositionWatcher
    : public content::WebContentsObserver,
      public content::RenderWidgetHost::InputEventObserver,
      public content::WebContentsUserData<PagePositionWatcher> {
 public:
  ~PagePositionWatcher() override { StopWatchingInput(); }

  void RestoreOnce(double ratio) {
    restore_ratio_ = std::clamp(ratio, 0.0, 1.0);
    reader_has_scrolled_ = false;
    restore_fallback_.Start(
        FROM_HERE, kRestoreFallbackDelay,
        base::BindOnce(&PagePositionWatcher::ApplyRestore,
                       base::Unretained(this)));
  }

  // content::RenderWidgetHost::InputEventObserver:
  void OnInputEvent(const content::RenderWidgetHost& host,
                    const blink::WebInputEvent& event,
                    InputEventSource source) override {
    switch (event.GetType()) {
      case blink::WebInputEvent::Type::kGestureTap:
        // A modal opened by a tap often locks page scrolling. Re-read the
        // page state once it has had time to appear, without touching the
        // restore bookkeeping below (a tap is not the reader scrolling).
        probe_timer_.Start(
            FROM_HERE, kScrollSettleDelay,
            base::BindOnce(&PagePositionWatcher::ReportSettled,
                           weak_factory_.GetWeakPtr()));
        return;
      case blink::WebInputEvent::Type::kGestureScrollUpdate:
      case blink::WebInputEvent::Type::kGestureScrollEnd:
      case blink::WebInputEvent::Type::kMouseWheel:
        break;
      default:
        return;
    }
    // The reader took over. Whatever the other device said no longer applies.
    reader_has_scrolled_ = true;
    restore_ratio_.reset();
    restore_fallback_.Stop();
    // Restarted on every scroll, so a flick reports once when it stops rather
    // than sixty times on the way.
    settle_timer_.Start(FROM_HERE, kScrollSettleDelay,
                        base::BindOnce(&PagePositionWatcher::ReportSettled,
                                       base::Unretained(this)));
  }

  // content::WebContentsObserver:
  void RenderFrameHostChanged(content::RenderFrameHost* old_host,
                              content::RenderFrameHost* new_host) override {
    StopWatchingInput();
    StartWatchingInput();
  }

  void PrimaryPageChanged(content::Page& page) override {
    settle_timer_.Stop();
    probe_timer_.Stop();
    StartWatchingInput();
  }

  void DocumentOnLoadCompletedInPrimaryMainFrame() override {
    ApplyRestore();
    // A page that cannot scroll never produces a scroll-settled event, so
    // report its state after load instead of waiting for a gesture that will
    // never come. Delayed so script-built pages have finished laying out.
    probe_timer_.Start(FROM_HERE, kLoadProbeDelay,
                       base::BindOnce(&PagePositionWatcher::ReportSettled,
                                      weak_factory_.GetWeakPtr()));
  }

  void WebContentsDestroyed() override { StopWatchingInput(); }

 private:
  friend class content::WebContentsUserData<PagePositionWatcher>;

  explicit PagePositionWatcher(content::WebContents* contents)
      : content::WebContentsObserver(contents),
        content::WebContentsUserData<PagePositionWatcher>(*contents) {
    StartWatchingInput();
  }

  void StartWatchingInput() {
    content::RenderWidgetHost* host = CurrentWidget();
    if (host == watched_) {
      return;
    }
    StopWatchingInput();
    if (host) {
      host->AddInputEventObserver(this);
      watched_ = host;
    }
  }

  void StopWatchingInput() {
    if (watched_) {
      watched_->RemoveInputEventObserver(this);
      watched_ = nullptr;
    }
  }

  content::RenderWidgetHost* CurrentWidget() {
    content::RenderFrameHost* frame =
        web_contents() ? web_contents()->GetPrimaryMainFrame() : nullptr;
    return frame ? frame->GetRenderWidgetHost() : nullptr;
  }

  void ReportSettled() {
    ReadPosition(web_contents(),
                 base::BindOnce(&PagePositionWatcher::OnSettledPositionRead,
                                weak_factory_.GetWeakPtr()));
  }

  void OnSettledPositionRead(base::Value result) {
    std::optional<base::DictValue> position = ParsePosition(result);
    if (!position || !web_contents()) {
      return;
    }
    base::DictValue event = std::move(*position);
    event.Set("event", "pageScrollSettled");
    event.Set("url", web_contents()->GetVisibleURL().possibly_invalid_spec());
    DispatchAuraShellRuntimeEvent(web_contents(), std::move(event));
  }

  void ApplyRestore() {
    restore_fallback_.Stop();
    if (!restore_ratio_ || reader_has_scrolled_) {
      return;
    }
    const double ratio = *restore_ratio_;
    restore_ratio_.reset();
    content::RenderFrameHost* frame =
        web_contents() ? web_contents()->GetPrimaryMainFrame() : nullptr;
    if (!frame || !frame->IsRenderFrameLive()) {
      return;
    }
    // A fraction of the document rather than a pixel offset, because the
    // window this page arrived in is a different width and the text has been
    // laid out again. 'instant', so the reader does not watch the page fly
    // past on the way to where they left off.
    const std::u16string script =
        u"(function(r){var h=Math.max("
        u"document.documentElement?document.documentElement.scrollHeight:0,"
        u"document.body?document.body.scrollHeight:0);"
        u"window.scrollTo({top:h*r,left:0,behavior:'instant'});"
        u"return Math.round(window.scrollY);})(" +
        base::UTF8ToUTF16(base::NumberToString(ratio)) + u")";
    LOG(WARNING) << "OHOS continuation: restoring to " << ratio;
    frame->ExecuteJavaScriptInIsolatedWorld(script, base::DoNothing(),
                                            ISOLATED_WORLD_ID_CHROME_INTERNAL);
  }

  raw_ptr<content::RenderWidgetHost> watched_ = nullptr;
  base::OneShotTimer settle_timer_;
  base::OneShotTimer probe_timer_;
  base::OneShotTimer restore_fallback_;
  std::optional<double> restore_ratio_;
  bool reader_has_scrolled_ = false;
  base::WeakPtrFactory<PagePositionWatcher> weak_factory_{this};

  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(PagePositionWatcher);

}  // namespace

void WatchPageScroll(content::WebContents* contents) {
  if (contents) {
    PagePositionWatcher::CreateForWebContents(contents);
  }
}

void ReadPageContinuation(content::WebContents* contents, int request_id) {
  if (!contents) {
    return;
  }
  ReadPosition(
      contents,
      base::BindOnce(
          [](base::WeakPtr<content::WebContents> contents, int request_id,
             base::Value result) {
            if (!contents) {
              return;
            }
            std::optional<base::DictValue> position = ParsePosition(result);
            base::DictValue event =
                position ? std::move(*position) : base::DictValue();
            event.Set("event", "pageContinuation");
            event.Set("requestId", request_id);
            event.Set("url",
                      contents->GetVisibleURL().possibly_invalid_spec());
            event.Set("title", base::UTF16ToUTF8(contents->GetTitle()));
            DispatchAuraShellRuntimeEvent(contents.get(), std::move(event));
          },
          contents->GetWeakPtr(), request_id));
}

void RestoreScrollRatioOnce(content::WebContents* contents, double ratio) {
  if (!contents) {
    return;
  }
  PagePositionWatcher::CreateForWebContents(contents);
  PagePositionWatcher::FromWebContents(contents)->RestoreOnce(ratio);
}

}  // namespace chrome::ohos
