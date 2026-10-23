#!/bin/bash
# chromium-hmos / WSL stage 3c: the multi-hour native compile.
# Builds the OHOS arm64 engine libs that go into the phone HAR.
# Run AFTER stage 3a (and 3b only if host deps were missing).
#   bash /mnt/d/WorkBuddy/鸿蒙Chrome/wb-wsl-stage3c-build.sh
# Resumable: ninja skips already-built objects, so Ctrl+C + re-run is safe.

WORK=/home/administrator/chromium-work
CHROMIUM_SRC=$WORK/chromium/src
OUT=$CHROMIUM_SRC/out/plan_kirin_pc
JOBS="${BUILD_JOBS:-8}"     # keep <= .wslconfig processors (8); lower to 6/4 if OOM

export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
export no_proxy=localhost,127.0.0.1,::1
export PATH="$WORK/tools/depot_tools:$PATH"
export DEPOT_TOOLS_METRICS=0
export VPYTHON_VIRTUALENV_ROOT="$WORK/.vpython-root"
export CIPD_CACHE_DIR="$WORK/.cipd-cache"
export PYTHONDONTWRITEBYTECODE=1

OUT_FILE=/home/administrator/wb-stage3c-out.txt
LOG=$OUT/build.log
exec > >(tee "$OUT_FILE") 2>&1
ts() { echo "[$(date '+%F %T')] $*"; }

ts "STAGE3c START  jobs=$JOBS"
cd "$CHROMIUM_SRC"
# NOTE: dropped 'chrome' — that target pulls devtools-frontend (remote-debug
# frontend) which fails to esbuild-bundle (missing accessibility.skill.js) and
# is NOT needed for the phone HAP. We only need the engine .so files below.
autoninja -C "$OUT" libweb_engine web_render libnweb_render
rc=$?
ts "autoninja exit=$rc"
if [ "$rc" = "0" ]; then
  echo "BUILD OK. Engine artifacts in $OUT:"
  ls -la "$OUT"/*.so 2>/dev/null
  echo ""
  echo "NEXT: copy libweb_engine.so + libnweb_render.so into the engine module of"
  echo "      the chromium-ui build tree, then rebuild the HAP (build-hap.cmd)."
  echo "      The touch-radius fix (c33736b) is already compiled into libweb_engine.so."
else
  echo "BUILD FAILED. Inspect the log:  tail -f $OUT_FILE"
fi
