#!/usr/bin/env bash
# 把 overlay 里"已修好"的文件同步进 WSL 的 Chromium 源树（幂等，可反复跑）。
# 用法： bash /mnt/d/WorkBuddy/鸿蒙Chrome/wb-wsl-sync-fixes.sh
set -u

OVL="/mnt/d/WorkBuddy/鸿蒙Chrome/chromium-hmos/overlay"
SRC="$HOME/chromium-work/chromium/src"

FILES="
ui/ozone/platform/ohos/ohos_vsync_provider.h
ui/ozone/platform/ohos/ohos_surface_factory.cc
media/base/cdm_context.h
media/base/cdm_context.cc
chrome/browser/ui/zoom/chrome_zoom_level_prefs.h
chrome/browser/ui/zoom/chrome_zoom_level_prefs.cc
"

echo "=== 同步 overlay 修复文件 -> WSL 源树 ==="
echo "overlay: $OVL"
echo "src    : $SRC"
echo

if [ ! -d "$SRC" ]; then
  echo "!! 源树不存在：$SRC"
  exit 1
fi

ok=0
bad=0
for f in $FILES; do
  if [ ! -f "$OVL/$f" ]; then
    echo "  [overlay 缺文件] $f"
    bad=$((bad + 1))
    continue
  fi
  if cp -f "$OVL/$f" "$SRC/$f"; then
    echo "  [OK]   $f"
    ok=$((ok + 1))
  else
    echo "  [FAIL] $f"
    bad=$((bad + 1))
  fi
done

echo
echo "结果：$ok 个成功，$bad 个失败"
echo

echo "=== 校验（本轮 vsync/factory/cdm/zoom 修复标志）==="
printf 'vsync 去 override      : '; grep -c "void SetPreferredFrameInterval(base::TimeDelta interval);" "$SRC/ui/ozone/platform/ohos/ohos_vsync_provider.h" 2>/dev/null || echo 0
printf 'Vulkan 2 参构造        : '; grep -c "VulkanImplementationOhos>(" "$SRC/ui/ozone/platform/ohos/ohos_surface_factory.cc" 2>/dev/null || echo 0
printf 'CdmContext OHOS 虚函数 : '; grep -c "GetOhosMediaKeySession" "$SRC/media/base/cdm_context.h" 2>/dev/null || echo 0
printf 'zoom NoDestructor      : '; grep -c "NoDestructor" "$SRC/chrome/browser/ui/zoom/chrome_zoom_level_prefs.cc" 2>/dev/null || echo 0
printf 'zoom 转换函数(应 2 处) : '; grep -c "blink::ZoomFactorToZoomLevel" "$SRC/chrome/browser/ui/zoom/chrome_zoom_level_prefs.cc" 2>/dev/null || echo 0
echo
echo "全部 >=1（zoom 转换函数应为 2）即同步成功。接着跑："
echo "  bash /mnt/d/WorkBuddy/鸿蒙Chrome/wb-wsl-stage3c-build.sh"
