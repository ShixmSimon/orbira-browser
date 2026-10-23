#!/bin/bash
# chromium-hmos / WSL stage 3e: build missing runtime resource paks + locales,
# then assemble the engine runtime into the chromium-ui build tree (HAP source).
#
# WHY THIS SCRIPT EXISTS
#   The main stage3c build intentionally dropped the `chrome` target (it pulls a
#   devtools-frontend esbuild step that fails and is NOT needed for the phone
#   HAP). That also means resources.pak / chrome_100_percent.pak /
#   chrome_200_percent.pak / locales/*.pak were never produced. The phone HAP
#   DOES need them (stage-runtime-assets.sh asserts they exist), so we build
#   just those two phony targets here — they are grit/repack only, not a
#   recompile, so it finishes in minutes.
#
#   `autoninja` lives in depot_tools. Running it from a fresh shell fails with
#   "command not found" because depot_tools isn't on PATH. This script exports
#   the same env as wb-wsl-stage3c-build.sh first, which fixes that.
#
# Run from WSL:
#   bash /mnt/d/WorkBuddy/鸿蒙Chrome/wb-wsl-stage3e-resources.sh
# Resumable: ninja skips already-built outputs, so re-running is safe.

WORK=/home/administrator/chromium-work
CHROMIUM_SRC=$WORK/chromium/src
OUT=$CHROMIUM_SRC/out/plan_kirin_pc
# The build tree the HAP is actually compiled from (NOT the overlay copy).
PROJECT=/mnt/d/hmos-build/chromium-ui

# --- build environment (same as wb-wsl-stage3c-build.sh) ---
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
export no_proxy=localhost,127.0.0.1,::1
export PATH="$WORK/tools/depot_tools:$PATH"
export DEPOT_TOOLS_METRICS=0
export VPYTHON_VIRTUALENV_ROOT="$WORK/.vpython-root"
export CIPD_CACHE_DIR="$WORK/.cipd-cache"
export PYTHONDONTWRITEBYTECODE=1

OUT_FILE=/home/administrator/wb-stage3e-out.txt
exec > >(tee "$OUT_FILE") 2>&1
ts() { echo "[$(date '+%F %T')] $*"; }

ts "STAGE3e START (build resource paks + locales)"
cd "$CHROMIUM_SRC" || { echo "cd $CHROMIUM_SRC failed"; exit 1; }

# Build the two phony targets. These expand to grit/repack rules only.
autoninja -C "$OUT" packed_resources packed_resources_locales
rc=$?
ts "autoninja(packed_resources) exit=$rc"

if [ "$rc" != "0" ]; then
  echo "RESOURCE BUILD FAILED."
  echo "  Inspect:  tail -f $OUT_FILE"
  echo "  Fallback if devtools esbuild gets pulled in: reuse the author HAR's"
  echo "  rawfile/chromium/* resource paks (runtime.version is only a cache"
  echo "  stamp in the shell, so reusing old paks is safe)."
  exit $rc
fi

# Sanity: stage-runtime-assets.sh will die if any of these are missing.
for f in resources.pak chrome_100_percent.pak chrome_200_percent.pak; do
  if [ ! -f "$OUT/$f" ]; then
    echo "ERROR: $OUT/$f still missing after build — aborting assembly."
    exit 1
  fi
done
if [ ! -d "$OUT/locales" ] || [ -z "$(ls -A "$OUT/locales" 2>/dev/null)" ]; then
  echo "ERROR: $OUT/locales empty/missing after build — aborting assembly."
  exit 1
fi

ts "resources built; staging runtime into $PROJECT"
bash /mnt/d/WorkBuddy/鸿蒙Chrome/chromium-hmos/scripts/stage-runtime-assets.sh "$OUT" "$PROJECT"
arc=$?
if [ "$arc" != "0" ]; then
  echo "ASSEMBLY FAILED (exit=$arc). Inspect above."
  exit $arc
fi

echo ""
echo "STAGE3e DONE. Engine runtime staged into $PROJECT/engine."
echo "NEXT: rebuild the HAP on Windows — run build-hap.cmd (in the"
echo "      chromium-ui tree). Do NOT push yet; verify on device first."
