#!/usr/bin/env bash
# verify-originals.sh — 在 Chromium src 树里核验 7 块本地原创引擎修改是否存活。
#
# 必须在 apply-adapter.sh（打 master patch + 增量 patch + rsync overlay）之后运行。
# 实现方式：对每块在 src 里的"唯一标记字符串"做 grep，缺一块即报错。
# 这是"同步上游不会覆盖本地改动"的运行时兜底——编译前必跑。
#
# 用法（在 WSL 中）：
#   bash verify-originals.sh /home/administrator/chromium-work/chromium/src
set -uo pipefail

SRC="${1:-/home/administrator/chromium-work/chromium/src}"
if [[ ! -d "${SRC}" ]]; then
  echo "usage: $0 /path/to/chromium/src"
  exit 2
fi

check() {
  local label="$1" file="$2" marker="$3"
  if grep -qF -- "${marker}" "${SRC}/${file}" 2>/dev/null; then
    echo "  [OK]    ${label}"
    return 0
  else
    echo "  [FAIL]  ${label}  (marker not found: '${marker}' in ${file})"
    return 1
  fi
}

fail=0
echo "Verifying protected originals in: ${SRC}"
check "1-UA-PIN (bridge)"    chrome/browser/ui/ohos/aura_shell_runtime_bridge.cc                "DesktopSiteHosts"                            || fail=1
check "1-UA-PIN (store)"     chrome/browser/ui/ohos/shell_store_user_agent_ohos.cc               "SetAuraShellUserAgentPinned"                || fail=1
check "2-BOTTOM-CROP"        content/browser/renderer_host/render_widget_host_view_aura.cc       "[鸿蒙Chrome] 关掉浏览器控件对渲染尺寸的收缩"     || fail=1
check "2-PAINT-HOLD-A"       content/browser/renderer_host/render_widget_host_view_aura.cc       "cold-start / new-tab gap reveals"            || fail=1
check "2-PAINT-HOLD-B"       content/browser/renderer_host/delegated_frame_host.cc               "UseSpecifiedDeadline(60u)"                  || fail=1
check "3-TOUCH-SLOP"         arkweb/ohos_nweb/src/aura_shell/ohos_aura_input_router.cc           "kDefaultTouchRadiusDip"                     || fail=1
check "4-VULKAN-GATE"        ui/ozone/platform/ohos/ohos_phone_gpu_channel.cc                   "ohos-disable-vulkan"                        || fail=1
check "5-EXT-ORIGIN (blink)"   third_party/blink/renderer/platform/loader/fetch/resource_request.cc "requests made by an extension"              || fail=1
check "5-EXT-ORIGIN (network)" services/network/cors/cors_url_loader.cc                           "extension-initiated requests do not advertise" || fail=1
check "6-BROWSE-COUNT"       chrome/browser/ui/ohos/shell_browsing_data_counts_ohos.cc            "PasswordsCounter"                            || fail=1
check "7-EXT-LOGO"           chrome/browser/ui/ohos/aura_shell_runtime_bridge.cc                  "The page draws the extension"               || fail=1

if [[ "${fail}" == 0 ]]; then
  echo "ORIGINALS_VERIFY_OK: all 7 original blocks present in src."
else
  echo "ORIGINALS_VERIFY_FAIL: one or more originals missing — DO NOT build until restored."
fi
exit "${fail}"
