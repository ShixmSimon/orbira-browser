#!/usr/bin/env bash
# Stage the freshly built 157 engine into the Windows-side HAP project.
#
# Run this in WSL before scripts/package-157-hap.cmd on Windows.
#
# Why this exists:
#   build-157-now.sh builds only libweb_engine / web_render / libnweb_render.
#   That produces the .so files but NOT the aggregate resource paks and
#   locales that the shell needs. The 2026-11-13 verification packages proved
#   that a 157 engine paired with stale/155-era rawfile crashes at startup
#   ("Error loading V8 startup snapshot file"), and that runtime.version must
#   be a legal 64-char lowercase hex. So we build the resource targets, then
#   delegate to the repository's authoritative stage-runtime-assets.sh.
#
# Usage:
#   bash scripts/package-157-stage.sh
#
# All text is ASCII: WSL bash under a non-UTF-8 locale has been observed to
# mis-parse multi-byte characters in comments and try to execute them.

set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly root="${CHROMIUM_157_ROOT:-/home/administrator/chromium-157}"
readonly src="${root}/src"
readonly out="${src}/out/plan_kirin_pc"
readonly ninja="${src}/third_party/ninja/ninja"
readonly stage_script="${repo_root}/scripts/stage-runtime-assets.sh"

# Windows-side project, addressed through the WSL /mnt/d mount.
readonly project="${HAP_PROJECT:-/mnt/d/hmos-build-157/chromium-ui}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -d "$src" ]]          || die "157 source tree missing: $src"
[[ -f "$out/args.gn" ]]  || die "no args.gn; run build-157-now.sh first"
[[ -f "$ninja" ]]        || die "ninja missing: $ninja"
[[ -f "$stage_script" ]] || die "stage script missing: $stage_script"
[[ -d "$project" ]]      || die "HAP project missing: $project"
# Line guard: three lines share one bundleName, so staging into a 154/155 site
# would quietly pair a 157 engine with the wrong resources (startup crash).
app_json="$project/AppScope/app.json5"
[[ -f "$app_json" ]] || die "app.json5 missing in project: $app_json"
grep -Eq '"versionName"[[:space:]]*:[[:space:]]*"1\.2\.' "$app_json" \
  || die "not a 157-line project (versionName != 1.2.x): $app_json"
[[ -x "$ninja" ]] || chmod +x "$ninja"

echo "=== [stage] building missing resource targets (packed_resources) ==="
# These paks/locales are not produced by the 3 engine targets. They are cheap
# and mostly up-to-date already. Failure here is fatal: shipping a HAP with a
# 157 engine and stale resources is a known startup crash.
"$ninja" -j 8 -C "$out" packed_resources

echo
echo "=== [stage] stage-runtime-assets.sh: $out -> $project ==="
# stage-runtime-assets.sh expects liblumie_adblock.so. Our build emits
# libadblock.so (same library, different name). Provide the expected name as a
# copy rather than editing the authoritative staging script.
if [[ ! -f "$out/liblumie_adblock.so" && -f "$out/libadblock.so" ]]; then
  echo "  providing liblumie_adblock.so (copy of libadblock.so)"
  cp -a "$out/libadblock.so" "$out/liblumie_adblock.so"
fi

bash "$stage_script" "$out" "$project"

# The engine dlopen()s "libadblock.so" (de-branded name) with no fallback, but
# the authoritative stage script only ships liblumie_adblock.so. Ship both, like
# the 155 line does: the ABI is identical and the dlopen then succeeds.
libs_dir="${project}/engine/libs/arm64-v8a"
if [[ -f "$out/libadblock.so" ]]; then
  cp -a "$out/libadblock.so" "$libs_dir/libadblock.so"
  echo "  staged libadblock.so (engine dlopen target)"
else
  die "missing ${out}/libadblock.so (engine dlopen target)"
fi

echo
echo "=== [stage] ensure shell carries both v8_context_snapshot fixes ==="
# A 157 engine needs v8_context_snapshot.bin unpacked into the runtime dir.
# The 155-era shell never unpacked it -> FATAL:gin/v8_initializer.cc:640
# "Error loading V8 startup snapshot file" (confirmed on device 2026-11-15).
# Two fixes are required in WebWindow.ets:
#   1. add 'v8_context_snapshot.bin' to the optional rawfile array;
#   2. repair a stale runtime dir: an older build can leave a .complete marker
#      that skips the whole extraction block, so the file is never added.
#      Our shell extracts just that file when the marker exists but it is
#      missing (avoids wiping device data or faking a new runtime.version).
# The repo overlay's WebWindow.ets is authoritative and carries both. Sync it
# wholesale instead of injecting code with sed (fragile with CRLF / template
# literals / shell expansion).
webwindow="${project}/engine/src/main/ets/components/webwindow/WebWindow.ets"
[[ -f "$webwindow" ]] || die "WebWindow.ets missing: $webwindow"
reference="${repo_root}/overlay/chromium-ui/engine/src/main/ets/components/webwindow/WebWindow.ets"
[[ -f "$reference" ]] || die "authoritative WebWindow.ets missing: $reference"
grep -q "'v8_context_snapshot.bin'" "$reference" \
  || die "authoritative WebWindow.ets lacks the snapshot fix"
grep -q 'contextSnapshotPath' "$reference" \
  || die "authoritative WebWindow.ets lacks the stale-marker repair"

needs_sync=0
grep -q "'v8_context_snapshot.bin'" "$webwindow" || needs_sync=1
grep -q 'contextSnapshotPath' "$webwindow" || needs_sync=1
if [[ $needs_sync -eq 1 ]]; then
  echo "  syncing WebWindow.ets from repo overlay (shell fixes missing)"
  cp -f "$reference" "$webwindow" || die "failed to sync WebWindow.ets"
else
  echo "  shell has both v8_context_snapshot fixes"
fi
grep -q "'v8_context_snapshot.bin'" "$webwindow" && grep -q 'contextSnapshotPath' "$webwindow" \
  || die "shell fixes did not take effect"

echo
echo "=== [stage] verify ==="
runtime_version="${project}/engine/src/main/resources/rawfile/chromium/runtime.version"
[[ -f "$runtime_version" ]] || die "runtime.version not written"
v="$(tr -d '\r\n' < "$runtime_version")"
[[ "$v" =~ ^[0-9a-f]{64}$ ]] || die "runtime.version is not 64 lowercase hex: $v"
echo "  runtime.version = $v (valid)"
for f in libweb_engine.so libnweb_render.so; do
  [[ -s "${project}/engine/libs/arm64-v8a/$f" ]] || die "missing staged $f"
  echo "  staged $f"
done
# The settings page's "Vulkan 渲染加速" toggle only works if the runtime gate
# IsOhosPhoneVulkanEnabled() (which reads --ohos-disable-vulkan) is compiled
# into the engine. Measured 2026-11-23: the old so had 0 occurrences, i.e. the
# toggle was a no-op. Keep this check: a package without the string is broken
# exactly the way the user reported.
engine_so="${project}/engine/libs/arm64-v8a/libweb_engine.so"
if grep -aq 'ohos-disable-vulkan' "$engine_so"; then
  echo "  Vulkan runtime gate present (ohos-disable-vulkan)"
elif [[ "${SKIP_VULKAN_GATE_CHECK:-0}" == "1" ]]; then
  # Diagnostics-only builds may stage a stock lumie engine that has no gate.
  echo "  WARN: no Vulkan gate (SKIP_VULKAN_GATE_CHECK=1, engine-swap experiment)"
else
  die "libweb_engine.so lacks the 'ohos-disable-vulkan' gate; the settings toggle would be a no-op"
fi
[[ -s "${project}/engine/src/main/resources/rawfile/chromium/v8_context_snapshot.bin" ]] \
  || die "missing v8_context_snapshot.bin (known 157 startup crash)"
echo "  staged v8_context_snapshot.bin"
echo
echo "=== [stage] done. Now run on Windows: scripts\\package-157-hap.cmd [release] ==="
