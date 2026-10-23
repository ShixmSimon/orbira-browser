#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Apply engine patches to the Chromium source tree inside WSL.

STATUS 2026-10-23 (read before running):

Origin (blocks 1-2 below): SHIPPED AND FOSSILIZED. Both edits now live in the
git-tracked patch chromium-hmos/patches/ohos-extension-origin.patch, which is
registered in apply-adapter.sh, ci-incremental-build.sh and
wb-wsl-stage3d-patches.sh -- a fresh tree gets them from there. Keep the two
blocks below in sync with that patch if the upstream code ever moves; this
patcher remains only as a hot-fix tool for a src tree that lost them.

Desktop-site persistence (blocks 3-5 below): OBSOLETE, DO NOT RE-RUN. The
authoritative version is the OVERLAY file
overlay/chrome/browser/ui/ohos/aura_shell_runtime_bridge.cc (git-tracked,
commits 220f64f1..9359b9d5), and apply-adapter.sh rsyncs overlay/ over src/
on every build, so patching src here is overwritten before it can matter. The
NavigationThrottle block was reverted in commit 8de67840 (CHECK crash in
SetIsOverridingUserAgent) -- do not resurrect it.

Run from Windows:
    wsl -d Ubuntu -- python3 /mnt/d/hmos-build/apply-engine-patches.py
Check only:
    wsl -d Ubuntu -- python3 /mnt/d/hmos-build/apply-engine-patches.py --check
"""

import os
import sys

SRC = "/home/administrator/chromium-work/chromium/src"
PATCHES = []


def add(rel, old, new, marker):
    PATCHES.append((rel, old, new, marker))


# ---------------------------------------------------------------- Origin #1
add(
    "third_party/blink/renderer/platform/loader/fetch/resource_request.cc",
    """void ResourceRequestHead::SetHTTPOrigin(const SecurityOrigin* origin) {
  SetHttpHeaderField(http_names::kOrigin, origin->ToAtomicString());
}""",
    """void ResourceRequestHead::SetHTTPOrigin(const SecurityOrigin* origin) {
  // OHOS: requests made by an extension (its pages, service worker and
  // offscreen document) do not advertise "chrome-extension://..." as their
  // Origin. Sites that validate Origin for CSRF reject that value outright,
  // and extension requests bypass CORS anyway, so leaving the header out is
  // both safe and what the sites expect.
  if (origin->Protocol() == "chrome-extension") {
    http_header_fields_.Remove(http_names::kOrigin);
    return;
  }
  SetHttpHeaderField(http_names::kOrigin, origin->ToAtomicString());
}""",
    "// OHOS: requests made by an extension",
)

# ---------------------------------------------------------------- Origin #2
add(
    "services/network/cors/cors_url_loader.cc",
    """    if (!has_custom_origin_header_with_bypass) {
      if (tainted_) {
        request_.headers.SetHeader(net::HttpRequestHeaders::kOrigin,
                                   url::Origin().Serialize());
      } else {
        request_.headers.SetHeader(net::HttpRequestHeaders::kOrigin,
                                   request_.request_initiator->Serialize());
      }
    }""",
    """    if (!has_custom_origin_header_with_bypass) {
      // OHOS: extension-initiated requests do not advertise
      // "chrome-extension://..." as their Origin. Sites that validate Origin
      // for CSRF reject that value, and extension requests bypass CORS anyway,
      // so leave the header out instead of synthesising it.
      if (request_.request_initiator &&
          request_.request_initiator->scheme() == "chrome-extension") {
        request_.headers.RemoveHeader(net::HttpRequestHeaders::kOrigin);
      } else if (tainted_) {
        request_.headers.SetHeader(net::HttpRequestHeaders::kOrigin,
                                   url::Origin().Serialize());
      } else {
        request_.headers.SetHeader(net::HttpRequestHeaders::kOrigin,
                                   request_.request_initiator->Serialize());
      }
    }""",
    "// OHOS: extension-initiated requests do not advertise",
)

BRIDGE = "chrome/browser/ui/ohos/aura_shell_runtime_bridge.cc"

# ------------------------------------------------------- Desktop sites 3a
add(
    BRIDGE,
    "// Anchor rectangles the shell reported, per window.",
    """// Hosts the shell wants opened as desktop sites, kept in sync by its
// "setDesktopSites" command. The shell owns the persistent copy; the engine
// only needs the current list so it can apply it to every tab, including tabs
// the shell never navigates itself (background tabs opened by an extension).
std::set<std::string>& DesktopSiteHosts() {
  static base::NoDestructor<std::set<std::string>> hosts;
  return *hosts;
}

bool& DesktopSiteEverywhere() {
  static bool everywhere = false;
  return everywhere;
}

void SetDesktopSites(const std::string* sites, bool everywhere) {
  DesktopSiteEverywhere() = everywhere;
  std::set<std::string>& hosts = DesktopSiteHosts();
  hosts.clear();
  if (!sites) {
    return;
  }
  for (const std::string& line :
       base::SplitString(*sites, "\\n", base::TRIM_WHITESPACE,
                         base::SPLIT_WANT_NONEMPTY)) {
    hosts.insert(base::ToLowerASCII(line));
  }
}

bool IsDesktopSiteHost(const GURL& url) {
  if (DesktopSiteEverywhere()) {
    return true;
  }
  if (!url.SchemeIsHTTPOrHTTPS()) {
    return false;
  }
  return DesktopSiteHosts().count(base::ToLowerASCII(url.host())) > 0;
}

// Anchor rectangles the shell reported, per window.""",
    "std::set<std::string>& DesktopSiteHosts()",
)

# ------------------------------------------------------- Desktop sites 3b
add(
    BRIDGE,
    """  void OnAudioStateChanged(bool audible) override {
    RequestBrowserStateUpdate();
  }
};""",
    """  void OnAudioStateChanged(bool audible) override {
    RequestBrowserStateUpdate();
  }

  // Applies the shell's per-site desktop choice to every tab, active or not.
  // A tab opened by an extension never passes through the shell's navigate
  // command, so this is the only place that can give it a desktop user agent.
  //
  // Order matters: SetIsOverridingUserAgent() rebuilds the User-Agent header
  // from the WebContents override, so setting the override first means the
  // very first request already carries the desktop agent. No reload is
  // needed, which keeps a script's background tab on its original timing.
  void DidStartNavigation(content::NavigationHandle* handle) override {
    if (!handle->IsInOutermostMainFrame()) {
      return;
    }
    content::WebContents* contents = web_contents();
    if (!contents) {
      return;
    }
    if (!IsDesktopSiteHost(handle->GetURL())) {
      // Leaving a desktop site also leaves its user agent behind, or every
      // later site in this tab would keep asking for desktop pages.
      if (!contents->GetUserAgentOverride().ua_string_override.empty()) {
        contents->SetUserAgentOverride(blink::UserAgentOverride(),
                                       /*override_in_new_tabs=*/false);
      }
      return;
    }
    contents->SetUserAgentOverride(AuraShellDesktopSiteUserAgent(),
                                   /*override_in_new_tabs=*/false);
    handle->SetIsOverridingUserAgent(true);
  }
};""",
    "void DidStartNavigation(content::NavigationHandle* handle) override {",
)

# ------------------------------------------------------- Desktop sites 3c
add(
    BRIDGE,
    """  } else if (*name == "setRequestDesktopSite" && active) {
    SetRequestDesktopSite(active, command.FindBool("enabled").value_or(false));
  } else if (*name == "setTabMuted") {""",
    """  } else if (*name == "setRequestDesktopSite" && active) {
    SetRequestDesktopSite(active, command.FindBool("enabled").value_or(false));
  } else if (*name == "setDesktopSites") {
    SetDesktopSites(command.FindString("sites"),
                    command.FindBool("allSites").value_or(false));
  } else if (*name == "setTabMuted") {""",
    '} else if (*name == "setDesktopSites") {',
)


# ------------------------------------------------- Desktop sites: include
add(
    BRIDGE,
    '#include "content/public/browser/navigation_entry.h"',
    '#include "content/public/browser/navigation_entry.h"\n'
    '#include "content/public/browser/navigation_handle.h"',
    "content/public/browser/navigation_handle.h",
)



# ------------------------------------------- Desktop sites: navigation throttle
THROTTLES = "chrome/browser/chrome_content_browser_client_navigation_throttles.cc"

# Repair: the class body below was first written with a literal "/n" instead of
# a newline after "public:". Fix it in place; the marker is the repaired text,
# so this runs once.
add(
    THROTTLES,
    " public:/n  explicit DesktopSiteUserAgentThrottle(",
    " public://n  explicit DesktopSiteUserAgentThrottle(",
    " public://n  explicit DesktopSiteUserAgentThrottle(",
)

add(
    THROTTLES,
    '#include "chrome/browser/ohos/url_protection/navigation_throttle.h"',
    '#include "chrome/browser/ohos/url_protection/navigation_throttle.h"\n'
    '#include "chrome/browser/ui/ohos/aura_shell_runtime_bridge.h"',
    "chrome/browser/ui/ohos/aura_shell_runtime_bridge.h",
)

add(
    THROTTLES,
    "void CreateAndAddChromeThrottlesForNavigation(\n"
    "    content::NavigationThrottleRegistry& registry) {",
    "#if BUILDFLAG(IS_OHOS)\n"
    "namespace {\n"
    "// Gives a navigation the desktop user agent before its request goes out.\n"
    "// A NavigationThrottle sees every navigation of every WebContents, so this\n"
    "// also covers tabs an extension opens in the background -- tabs that never\n"
    "// pass through the shell's own navigation path.\n"
    "class DesktopSiteUserAgentThrottle : public content::NavigationThrottle {\n"
    " public:/n"
    "  explicit DesktopSiteUserAgentThrottle(\n"
    "      content::NavigationThrottleRegistry& registry)\n"
    "      : content::NavigationThrottle(registry) {}\n"
    "\n"
    "  ThrottleCheckResult WillStartRequest() override {\n"
    "    content::NavigationHandle* handle = navigation_handle();\n"
    "    content::WebContents* contents = handle->GetWebContents();\n"
    "    if (handle->IsInOutermostMainFrame() && contents &&\n"
    "        chrome::ohos::IsAuraShellDesktopSite(handle->GetURL())) {\n"
    "      contents->SetUserAgentOverride(\n"
    "          chrome::ohos::AuraShellDesktopSiteUserAgent(),\n"
    "          /*override_in_new_tabs=*/false);\n"
    "      handle->SetIsOverridingUserAgent(true);\n"
    "    }\n"
    "    return PROCEED;\n"
    "  }\n"
    "\n"
    "  const char* GetNameForLogging() override {\n"
    "    return \"DesktopSiteUserAgentThrottle\";\n"
    "  }\n"
    "};\n"
    "}  // namespace\n"
    "#endif  // BUILDFLAG(IS_OHOS)\n"
    "\n"
    "void CreateAndAddChromeThrottlesForNavigation(\n"
    "    content::NavigationThrottleRegistry& registry) {",
    "class DesktopSiteUserAgentThrottle",
)

add(
    THROTTLES,
    "#if BUILDFLAG(IS_OHOS)\n"
    "  chrome::ohos::url_protection::NavigationThrottle::MaybeCreateAndAdd(registry);\n"
    "#endif",
    "#if BUILDFLAG(IS_OHOS)\n"
    "  chrome::ohos::url_protection::NavigationThrottle::MaybeCreateAndAdd(registry);\n"
    "  registry.AddThrottle(\n"
    "      std::make_unique<DesktopSiteUserAgentThrottle>(registry));\n"
    "#endif",
    "std::make_unique<DesktopSiteUserAgentThrottle>",
)


def main():
    check_only = "--check" in sys.argv
    failed = 0
    for rel, old, new, marker in PATCHES:
        path = os.path.join(SRC, rel)
        if not os.path.exists(path):
            print("[MISS] file not found: " + rel)
            failed += 1
            continue
        with open(path, "r", encoding="utf-8", newline="") as f:
            text = f.read()
        if marker in text:
            print("[SKIP] already patched: " + rel)
            continue
        if text.count(old) != 1:
            print("[FAIL] anchor found %d times (expected 1): %s"
                  % (text.count(old), rel))
            failed += 1
            continue
        if check_only:
            print("[TODO] patch pending: " + rel)
            continue
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(text.replace(old, new))
        print("[OK] patched: " + rel)
    if failed:
        print("\n%d patch(es) not handled. Do NOT build." % failed)
        return 1
    print("\nAll patches done. Now run the engine build script.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
