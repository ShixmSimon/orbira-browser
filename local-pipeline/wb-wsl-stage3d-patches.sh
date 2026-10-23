#!/usr/bin/env bash
# chromium-hmos / WSL stage 3d: 按权威顺序应用增量补丁（原 44 个 + 2026-10-14
# 从上游 4ec4b24 同步的新增 10 个 + 2026-10-23 本地固化的 ohos-extension-origin，
# 共 55 个），并把 overlay 同步进树。
#
# 【2026-10-14 同步说明】
#   上游 miramira8295/chromium-hmos 在 34534541..4ec4b24 间新增 10 个增量补丁
#   （防钓鱼/URL 防护三件套、手机 fork GPU 三件套、IME、Skia Vulkan 两件、
#   ANGLE MSRT 一件），已全部拉进本地仓库 patches/。上游 apply-adapter.sh 与
#   ci-incremental-build.sh 也已更新（ANGLE 补丁作用于 third_party/angle 子仓，
#   构建脚本为此支持 patch_root；防钓鱼有 retire 逻辑）。
#   ⚠️ 增量更新（不重跑 stage3a）时 overlay 不会自动进树 —— 本脚本新增步骤 3.5
#      复刻上游 ci-incremental-build.sh 的 overlay 同步（内容比较 + CRLF 归一
#      + 跳过符号链接），否则新 BUILD.gn/源文件不进构建图 → 链接期报错。
#
# 【根因，有据可查】
#   scripts/ci-incremental-build.sh 第 170-228 行写明：主补丁之外还有 44 个增量补丁
#   必须在 overlay 同步之前按固定顺序应用。而 scripts/apply-adapter.sh 只做
#   「chromium-154-harmonyos.patch + patches/deps/series + overlay rsync」，
#   漏了这 44 个 —— 于是树里缺了它们的 BUILD.gn 条目和部分源文件改动，
#   表现为链接期 undefined symbol（web_render 19 个：picker/speech/accessibility/
#   password-sync/video-frame-converter/cenc/audio-decoder/vsync 等）。
#
# 【为什么只应用"非 overlay 文件"的改动】
#   作者 CI 的顺序是：主补丁 → 44 增量补丁 → overlay 覆盖（ci-incremental-build.sh
#   第 230-263 行）。因此对「被 overlay 覆盖的文件」，补丁内容最终被 overlay 盖掉，
#   不影响最终状态；只有非 overlay 文件的补丁改动真正留在树里。
#   本脚本只应用这一部分 —— 与作者 CI 的最终状态等价，且避免把 overlay 的
#   最终内容回退成补丁里的旧版本。
#
# 【前置】已跑过 stage3a（apply-adapter）；本脚本会先把上一轮 4 处手工补丁
#         还原成作者原版，让补丁能干净落地。
#
# 用法: bash /mnt/d/WorkBuddy/鸿蒙Chrome/wb-wsl-stage3d-patches.sh
# 之后: bash /mnt/d/WorkBuddy/鸿蒙Chrome/wb-wsl-stage3c-build.sh

set -uo pipefail

REPO="/mnt/d/WorkBuddy/鸿蒙Chrome/chromium-hmos"
SRC="/home/administrator/chromium-work/chromium/src"
OUT="$SRC/out/plan_kirin_pc"
WORK="/home/administrator/chromium-work"
LOG="/home/administrator/wb-stage3d-patches.txt"

exec > >(tee "$LOG") 2>&1
ts() { echo "[$(date '+%F %T')] $*"; }

# ci-incremental-build.sh 第 183-228 行的顺序，原文照抄
PATCHES="
ohos-cached-shader-no-crash.patch
ohos-phone-ua-openharmony.patch
ohos-external-protocol-to-shell.patch
ohos-phone-android-web-prefs.patch
ohos-web-share.patch
ohos-file-chooser-accept-capture.patch
ohos-popup-blocked-notice.patch
ohos-downloads-narrow.patch
ohos-enterkeyhint.patch
ohos-fullscreen-video-orientation.patch
ohos-scripted-print-to-system.patch
ohos-native-pickers.patch
ohos-shell-date-picker.patch
ohos-contacts-picker.patch
ohos-speech-recognition.patch
ohos-nfc.patch
ohos-password-vault.patch
ohos-popup-below-browser-controls.patch
ohos-location-bar-bubble-below-shell.patch
ohos-emoji-font-fallback.patch
ohos-password-fill-always-auth.patch
ohos-phone-popups-as-tabs.patch
ohos-single-process-keep-browsing-instance.patch
ohos-touch-menu-below-shell-bar.patch
ohos-touch-caret-drag.patch
ohos-egl-bottom-left-surface.patch
ohos-password-sync.patch
ohos-log-url-host-only.patch
ohos-web-accessibility.patch
ohos-media-artwork.patch
ohos-quick-menu-system-paste.patch
ohos-autofill-follows-keyboard.patch
ohos-autofill-popup-above-keyboard.patch
ohos-child-startup-resources.patch
ohos-csv-import-lifecycle.patch
ohos-memfd-shared-memory.patch
ohos-child-exit-observation.patch
ohos-phone-fork.patch
ohos-phone-gpu-shared-output.patch
ohos-ime-explicit-keyboard-request.patch
ohos-video-zero-copy.patch
ohos-hevc-capability.patch
ohos-adaptive-vsync.patch
ohos-phone-skia-vulkan.patch
ohos-skia-output-format-diagnostics.patch
ohos-vulkan-sdr-output.patch
ohos-tab-discarding.patch
ohos-camera-frame-layout.patch
ohos-camera-lifecycle.patch
ohos-camera-timeline.patch
ohos-paint-hold-a.patch
ohos-paint-hold-b.patch
ohos-bottom-crop.patch
ohos-extension-origin.patch
ohos-url-protection.patch
ohos-url-protection-updates.patch
ohos-rule-sources.patch
ohos-angle-vulkan-msrt.patch
"

ts "STAGE3D START"
[ -d "$SRC/.git" ] || { echo "!! 找不到源树 $SRC"; exit 1; }
[ -d "$REPO/patches" ] || { echo "!! 找不到仓库 $REPO"; exit 1; }

# ---------------------------------------------------------------------------
# 1) 还原上一轮的 4 处手工补丁（让补丁干净落地；overlay 侧也一并还原）
# ---------------------------------------------------------------------------
ts "1) 还原手工补丁 -> 作者原版"
# 安全阀：若增量补丁已在树里（例如上一轮已跑过），绝不重复还原 ——
# git checkout 会把刚应用上去的补丁改动一起抹掉。
if grep -q "void SetOhosPopupMenuHandler" \
     "$SRC/content/browser/renderer_host/render_frame_host_impl.cc" 2>/dev/null; then
  echo "   检测到增量补丁已在树里 -> 跳过还原步骤（避免抹掉已应用的补丁改动）"
else
  git -C "$REPO" checkout -- \
    overlay/ui/ozone/platform/ohos/ohos_surface_factory.cc \
    overlay/ui/ozone/platform/ohos/ohos_vsync_provider.h 2>&1 | sed 's/^/   /'
  rm -rf "$REPO/overlay/chrome/browser/ui/zoom" "$REPO/overlay/media/base"
  echo "   已删除自建 overlay: chrome/browser/ui/zoom/, media/base/"
  for f in ui/ozone/platform/ohos/ohos_surface_factory.cc \
           ui/ozone/platform/ohos/ohos_vsync_provider.h ; do
    cp -f "$REPO/overlay/$f" "$SRC/$f" && echo "   已还原树内 overlay 文件: $f"
  done
  git -C "$SRC" checkout -- \
    media/base/cdm_context.h media/base/cdm_context.cc \
    chrome/browser/ui/zoom/chrome_zoom_level_prefs.h \
    chrome/browser/ui/zoom/chrome_zoom_level_prefs.cc 2>&1 | sed 's/^/   /'
  echo "   已还原树内文件: cdm_context.{h,cc}, chrome_zoom_level_prefs.{h,cc}"

  # 还原校验：确认手工补丁真的没了（不然后面补丁会因为上下文不符而失败）
  bad=0
  if grep -q "b510e9d7 does not declare" "$SRC/ui/ozone/platform/ohos/ohos_vsync_provider.h" 2>/dev/null; then
    echo "   !! vsync_provider.h 还原失败（仍有手工注释）"; bad=1
  fi
  if ! grep -q "OhosVSyncProvider" "$SRC/ui/ozone/platform/ohos/ohos_surface_factory.cc" 2>/dev/null; then
    echo "   !! surface_factory.cc 还原失败（缺 OhosVSyncProvider 第 3 参数）"; bad=1
  fi
  if grep -q "IS_OHOS" "$SRC/media/base/cdm_context.h" 2>/dev/null; then
    echo "   !! cdm_context.h 还原失败（仍有 IS_OHOS 块）"; bad=1
  fi
  if [ "$bad" != "0" ]; then
    echo "   !! 还原不完整，停在补丁应用之前，请把上面几行贴给我。"
    exit 1
  fi
  echo "   还原校验通过（3 项）"
fi
echo

# ---------------------------------------------------------------------------
# 2) 生成「overlay 最终生效文件集」（补丁对这些文件的改动会被 overlay 覆盖 → 跳过）
#    复刻 ci-incremental-build.sh 的 overlay 过滤规则
# ---------------------------------------------------------------------------
ts "2) 生成 overlay 生效文件集"
git -C "$REPO" ls-files overlay/ \
  | sed 's|^overlay/||' \
  | awk '
      /^chromium-ui\//          { next }   # 外壳侧，不进 Chromium 树
      /^ohos_arkweb_playground\// { next }
      /^arkweb\/ohos_nweb\//    { print; next }   # //ohos_nweb 走 overlay
      /^arkweb\//               { next }   # 其余 arkweb 由补丁负责
      { print }
    ' | sort -u > /tmp/ovl_final.txt
echo "   overlay 生效文件数: $(wc -l < /tmp/ovl_final.txt)"
echo

# ---------------------------------------------------------------------------
# 2.5) 防钓鱼 retire 逻辑 + DEPS 子仓补丁根（2026-10-14 同步上游新增）
# ---------------------------------------------------------------------------
# 上游 ci-incremental-build.sh 的逻辑：若 ohos-url-protection.patch 不能反向
# check（树里没有它、或只有旧版 updates），先把 ohos-url-protection-updates.patch
# 从树里退役，再按序应用 protection -> updates -> rule-sources。防钓鱼三件套在
# PATCHES 列表末尾，故在循环前统一执行，等价且安全（树里没有时退役为空操作）。
# 另：DEPS 子仓（ANGLE）有独立 git 根，apply 必须 -C 到 third_party/angle。
declare -A PATCH_ROOT=(
  [ohos-angle-vulkan-msrt.patch]="$SRC/third_party/angle"
)

retire_patch() {
  local patch="$1" name rev rel
  name="${patch##*/}"
  rel="${patch#"${REPO}/"}"
  for rev in $(git -C "$REPO" log --format=%H -n 20 -- "$rel" 2>/dev/null); do
    if git -C "$REPO" show "${rev}:${rel}" 2>/dev/null |
        git -C "$SRC" apply --reverse --check - 2>/dev/null; then
      git -C "$REPO" show "${rev}:${rel}" | git -C "$SRC" apply --reverse ||
        { echo "  !! 退役 $name 失败"; return 1; }
      echo "  [退役] $name @ ${rev:0:8}"
      return 0
    fi
  done
  echo "  [退役] $name 未应用（无需退役）"
  return 0
}

if ! git -C "$SRC" apply -C0 --reverse --check \
    "$REPO/patches/ohos-url-protection.patch" 2>/dev/null; then
  retire_patch "$REPO/patches/ohos-url-protection-updates.patch"
fi
echo

# ---------------------------------------------------------------------------
# 3) 按序应用全部增量补丁（每个只取非 overlay 文件的部分）
# ---------------------------------------------------------------------------
ts "3) 应用增量补丁（仅非 overlay 部分）"
OK=0; SKIP=0; FAIL=0; FAILED_LIST=""
for p in $PATCHES; do
  patch="$REPO/patches/$p"
  if [ ! -f "$patch" ]; then
    echo "  [缺失] $p"; FAIL=$((FAIL+1)); FAILED_LIST="$FAILED_LIST $p(missing)"; continue
  fi

  # 过滤：只保留非 overlay 覆盖文件的 hunk
  awk -v OFS='' 'NR==FNR { ovl[$0]=1; next }
      /^diff --git a\// {
        f=$0; sub(/^diff --git a\//,"",f); sub(/ b\/.*$/,"",f)
        keep = (f in ovl) ? 0 : 1
      }
      keep { print }
    ' /tmp/ovl_final.txt "$patch" > /tmp/filtered.patch

  if [ ! -s /tmp/filtered.patch ]; then
    echo "  [跳过] $p （改动全在 overlay 覆盖范围内）"; SKIP=$((SKIP+1)); continue
  fi
  nfiles=$(grep -c '^diff --git' /tmp/filtered.patch)

  # DEPS 子仓（ANGLE）有独立 git 根；其余补丁都在主源树
  root="${PATCH_ROOT[$p]:-$SRC}"

  # 幂等：已经在了就跳（CI 同款判断）
  if git -C "$root" apply --binary --reverse --check /tmp/filtered.patch 2>/dev/null; then
    echo "  [已在] $p （$nfiles 文件）"; SKIP=$((SKIP+1)); continue
  fi
  if git -C "$root" apply --binary --whitespace=nowarn /tmp/filtered.patch 2>/dev/null; then
    echo "  [OK]   $p （$nfiles 文件）"; OK=$((OK+1))
  else
    # 整体失败（git apply 是按补丁原子提交的）：常见于"其中一个文件已是新版"，
    # 结果另一个文件明明能打却没落。逐文件重试，把能打的打上、已是新版的记为"已在"。
    echo "  [部分] $p 整体失败 -> 逐文件重试"
    rm -rf /tmp/parts; mkdir -p /tmp/parts
    awk -v d=/tmp/parts 'BEGIN{n=0}
        /^diff --git /{n++}
        n>0{print > (d "/" sprintf("%03d", n) ".patch")}' /tmp/filtered.patch
    pok=0; palready=0; pbad=0
    for one in /tmp/parts/*.patch; do
      fname=$(grep -m1 '^diff --git a/' "$one" | sed 's|^diff --git a/||; s| b/.*$||')
      if git -C "$root" apply --binary --reverse --check "$one" 2>/dev/null; then
        echo "         已在: $fname"; palready=$((palready+1))
      elif git -C "$root" apply --binary --whitespace=nowarn "$one" 2>/dev/null; then
        echo "         OK  : $fname"; pok=$((pok+1))
      else
        echo "         失败: $fname"; pbad=$((pbad+1))
        git -C "$root" apply --binary --check "$one" 2>&1 | head -4 | sed 's/^/              /'
      fi
    done
    echo "         小计: 应用 $pok / 已在 $palready / 失败 $pbad"
    if [ "$pbad" = "0" ]; then OK=$((OK+1)); else FAIL=$((FAIL+1)); FAILED_LIST="$FAILED_LIST $p"; fi
  fi
done
echo
echo "补丁结果: 应用 $OK / 已在或跳过 $SKIP / 失败 $FAIL"
[ -n "$FAILED_LIST" ] && echo "失败清单:$FAILED_LIST"
echo

# ---------------------------------------------------------------------------
# 3.5) overlay 同步进源树（增量更新关键步骤，2026-10-14 新增）
#   增量更新（不重跑 stage3a/apply-adapter）时 overlay 不会自动进树，而本次
#   上游同步带进来 64 个 overlay 文件（url_protection 21 个、phone_gpu 8 个、
#   BUILD.gn 等）—— 不进树则 gn 看不到新源文件，链接期必炸。
#   逻辑复刻上游 ci-incremental-build.sh 的 overlay 同步段：
#     - chromium-ui/（应用侧）与 arkweb/ 非 nweb 部分不进 Chromium 树；
#     - 树里的符号链接（ohos_glue/ohos_nweb 是指向真实目录的链接）不写穿；
#     - 行尾归一后做内容比较：仓库在 Windows 检出带 CRLF、树是 LF，逐字节比
#       会误判全量不同 → 全量重写 → 触发全量重编（上游原注释）。
# ---------------------------------------------------------------------------
ts "3.5) overlay 同步进源树"
synced=0
while IFS= read -r -d '' f; do
  rel="${f#"${REPO}/overlay/"}"
  case "$rel" in
    chromium-ui/*|ohos_arkweb_playground/*) continue ;;  # 应用侧，不进 Chromium 树
    arkweb/ohos_nweb/*) ;;                                # //ohos_nweb 走 overlay
    arkweb/*) continue ;;
  esac
  dst="${SRC}/${rel}"
  [ -L "$dst" ] && continue
  if [[ ! -f "$dst" ]] || ! diff -q <(tr -d '\r' <"$f") <(tr -d '\r' <"$dst") >/dev/null 2>&1; then
    mkdir -p "$(dirname "$dst")"
    tr -d '\r' <"$f" >"$dst"
    echo "   + $rel"
    synced=$((synced+1))
  fi
done < <(find "${REPO}/overlay" -type f -print0)
echo "   overlay 同步文件数: $synced"
echo

# ---------------------------------------------------------------------------
# 4) gn gen（BUILD.gn/.gn/.gni 变了必须重跑，才会把新源文件纳入构建图）
# ---------------------------------------------------------------------------
ts "4) gn gen"
export PATH="$WORK/tools/depot_tools:$PATH"
export DEPOT_TOOLS_METRICS=0
export VPYTHON_VIRTUALENV_ROOT="$WORK/.vpython-root"
export CIPD_CACHE_DIR="$WORK/.cipd-cache"
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
export no_proxy=localhost,127.0.0.1,::1
cd "$SRC" && gn gen "$OUT"
rc=$?
if [ "$rc" != "0" ]; then
  echo "!! gn gen 失败（exit=$rc）—— 把上面的报错贴给我"
  exit 1
fi
echo

# ---------------------------------------------------------------------------
# 5) 校验：之前 undefined 的源文件是否已进入构建图
# ---------------------------------------------------------------------------
ts "5) 校验"
echo "   注：GN 不把源文件名写进 build.ninja，编译边在 obj/**/*.ninja 子文件里（早先查 build.ninja 是查错文件）"
echo "   -- 新增源文件是否进了构建图（各应 >=1）--"
for f in shell_accessibility_ohos shell_password_sync_ohos; do
  printf '   %-28s core.ninja=%s\n' "$f" "$(grep -c "$f" "$OUT/obj/chrome/browser/core.ninja" 2>/dev/null)"
done
for f in ohos_video_frame_converter ohos_video_surface ohos_cenc_info ohos_audio_decoder ohos_cdm; do
  printf '   %-28s gpu.ninja=%s\n' "$f" "$(grep -c "$f" "$OUT/obj/media/gpu/gpu.ninja" 2>/dev/null)"
done
echo "   -- 补丁加的定义体是否存在（各应=1）--"
printf '   %-28s %s\n' "SetOhosPopupMenuHandler" "$(grep -c "void SetOhosPopupMenuHandler" "$SRC/content/browser/renderer_host/render_frame_host_impl.cc" 2>/dev/null)"
printf '   %-28s %s\n' "SetOhosContactsPickerHandler" "$(grep -c "void SetOhosContactsPickerHandler" "$SRC/content/browser/contacts/contacts_manager_impl.cc" 2>/dev/null)"
printf '   %-28s %s\n' "ui/gfx/vsync_provider.h 虚函数" "$(grep -c "SetPreferredFrameInterval" "$SRC/ui/gfx/vsync_provider.h" 2>/dev/null)"
echo "   变更文件数（git status）: $(git -C "$SRC" status --porcelain | wc -l)"
echo
ts "STAGE3D DONE  (log: $LOG)"
echo "接着跑:  bash /mnt/d/WorkBuddy/鸿蒙Chrome/wb-wsl-stage3c-build.sh"
