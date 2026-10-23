#!/usr/bin/env bash
# Save the local (user-authored) patches out of the WSL trees so they can be
# re-applied after a future upstream re-sync.
#
# REALITY CHECK (probed 2026-10-13, confirmed by user):
#   - c33736b (touch slop fix) IS compiled into libweb_engine.so -> current HAP keeps the fix.
#     Its SOURCE lives in the OVERLAY repo (chromium-hmos), file:
#       overlay/arkweb/ohos_nweb/src/aura_shell/ohos_aura_input_router.cc
#     NOT in the grafted main chromium src repo -> that is why 'git log' in src found nothing.
#     NOTE: the saved 01-*.patch must be applied in the OVERLAY repo, not src.
#   - A (aura.cc Init transparent) : in src tree (committed to HEAD) -> copy verified stage3f patch.
#   - B (delegated_frame_host deadline hold) : in src tree (uncommitted edit) -> diff it out.
#
# CRITICAL (2026-10-13 bug): a 'git log -S "touch_major"' search also matches the
# grafted HEAD "Roll WebView ARM Orderfile" commit, which exported a 4.5 GB
# garbage patch. Fixes below:
#   1) scan the OVERLAY repo FIRST (c33736b definitively lives there);
#   2) validate every candidate by commit MESSAGE before format-patch;
#   3) guard: reject any exported patch larger than 5 MB (c33736b is ~7 KB).
#
# Usage:
#   bash /mnt/d/WorkBuddy/鸿蒙Chrome/wb-wsl-save-local-patches.sh
#   C337_REF=<sha-or-name> bash /mnt/d/WorkBuddy/鸿蒙Chrome/wb-wsl-save-local-patches.sh
# (SRC defaults to the known chromium src tree; do NOT rely on $(pwd).)

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Fixed absolute src path so the script works no matter where it is launched from.
SRC="${SRC:-/home/administrator/chromium-work/chromium/src}"
OUT="$SCRIPT_DIR/local-patches"
OVERLAY_REPO="/mnt/d/WorkBuddy/鸿蒙Chrome/chromium-hmos"
AURA="content/browser/renderer_host/render_widget_host_view_aura.cc"
DELEG="content/browser/renderer_host/delegated_frame_host.cc"
OVL_TOUCH="overlay/arkweb/ohos_nweb/src/aura_shell/ohos_aura_input_router.cc"

echo "== SRC: $SRC =="
if [ ! -f "$SRC/$DELEG" ]; then
  echo "!! SRC does not look like the chromium src tree (missing $DELEG)"
  echo "   Set SRC=<path to chromium/src> and re-run."
  exit 1
fi
cd "$SRC" || { echo "!! cannot cd to $SRC"; exit 1; }
mkdir -p "$OUT"

# ---------------------------------------------------------------------------
# B : deadline hold  (present in src tree as uncommitted edit -> diff it out;
#                      otherwise fall back to verified stage3b patch)
# ---------------------------------------------------------------------------
echo "== B : delegated_frame_host.cc deadline hold =="
if grep -q "UseSpecifiedDeadline(60u)" "$DELEG"; then
  echo "[OK] B present in tree -> extracting from 'git diff HEAD'"
  git diff HEAD -- "$DELEG" > "$OUT/02b-paint-hold-b.patch"
  if [ -s "$OUT/02b-paint-hold-b.patch" ]; then
    echo "    wrote $OUT/02b-paint-hold-b.patch ($(wc -l < "$OUT/02b-paint-hold-b.patch") lines)"
  else
    echo "    B grep matched but git diff HEAD EMPTY (committed to HEAD?) -> try HEAD~1..HEAD"
    git diff HEAD~1 HEAD -- "$DELEG" > "$OUT/02b-paint-hold-b.patch" 2>/dev/null || true
    if [ -s "$OUT/02b-paint-hold-b.patch" ]; then
      echo "    wrote $OUT/02b-paint-hold-b.patch from HEAD~1..HEAD"
    else
      echo "!! could not extract B automatically; copying verified stage3b patch"
      cp "$SCRIPT_DIR/wb-wsl-stage3b-paint-hold-b.patch" "$OUT/02b-paint-hold-b.patch"
      echo "    copied -> $OUT/02b-paint-hold-b.patch"
    fi
  fi
else
  echo "[NOTE] B NOT in tree -> using verified stage3b patch for replay"
  cp "$SCRIPT_DIR/wb-wsl-stage3b-paint-hold-b.patch" "$OUT/02b-paint-hold-b.patch"
  echo "    copied $SCRIPT_DIR/wb-wsl-stage3b-paint-hold-b.patch -> $OUT/02b-paint-hold-b.patch"
  echo "    (saved patch for future re-apply; NOT evidence B is currently in the tree)"
fi

# ---------------------------------------------------------------------------
# A : aura.cc Init transparent  (in tree, committed to HEAD -> copy stage3f)
# ---------------------------------------------------------------------------
echo "== A : aura.cc Init transparent =="
if grep -q "SK_ColorTRANSPARENT" "$AURA"; then
  echo "[OK] A present in tree -> extracting from 'git diff HEAD'"
  git diff HEAD -- "$AURA" > "$OUT/02a-paint-hold-a.patch"
  if [ -s "$OUT/02a-paint-hold-a.patch" ]; then
    echo "    wrote $OUT/02a-paint-hold-a.patch ($(wc -l < "$OUT/02a-paint-hold-a.patch") lines)"
  else
    echo "    A matched grep but diff empty (committed to HEAD) -> copying verified stage3f patch"
    cp "$SCRIPT_DIR/wb-wsl-stage3f-paint-hold-a.patch" "$OUT/02a-paint-hold-a.patch"
    echo "    copied -> $OUT/02a-paint-hold-a.patch"
  fi
else
  echo "[NOTE] A NOT in tree (lost to graft/re-sync) -> using verified stage3f patch for replay"
  cp "$SCRIPT_DIR/wb-wsl-stage3f-paint-hold-a.patch" "$OUT/02a-paint-hold-a.patch"
  echo "    copied $SCRIPT_DIR/wb-wsl-stage3f-paint-hold-a.patch -> $OUT/02a-paint-hold-a.patch"
  echo "    (saved patch for future re-apply; NOT evidence A is currently in the tree)"
fi

# ---------------------------------------------------------------------------
# c33736b : touch slop fix
#   Source is in the OVERLAY repo (chromium-hmos), not the grafted src repo.
#   IMPORTANT: scan overlay FIRST. A broad '-S touch_major' also matches the
#   grafted HEAD "Roll WebView ARM Orderfile" commit; we therefore validate
#   every candidate by commit MESSAGE and reject anything that is not the slop
#   fix. We also guard against exporting a multi-GB garbage patch.
# ---------------------------------------------------------------------------
echo "== c33736b : touch slop fix =="

C337_REF="${C337_REF:-}"

write_patch_for_sha () {
  # $1 = sha ; writes 01-c33736b-touch.patch, with a size guard.
  local sha="$1"
  local f
  git format-patch -1 "$sha" -o "$OUT" --start-number 1 >/dev/null 2>&1 || return 1
  f=$(ls "$OUT"/0001-*.patch 2>/dev/null | head -1)
  [ -z "$f" ] && return 1
  # size guard: c33736b is ~7 KB; anything > 5 MB is almost certainly a wrong commit
  local sz; sz=$(wc -c < "$f")
  if [ "$sz" -gt 5242880 ]; then
    echo "    !! exported patch is ${sz} bytes (>5 MB) -- WRONG commit, discarding"
    rm -f "$f"
    return 1
  fi
  mv "$f" "$OUT/01-c33736b-touch.patch" 2>/dev/null \
    && { echo "    wrote $OUT/01-c33736b-touch.patch ($(wc -l < "$OUT/01-c33736b-touch.patch") lines, VERIFY it is the slop fix)"; return 0; } \
    || return 1
}

export_patch_from_repo () {
  # $1 = repo dir ; exports the first message-validated slop/touch commit.
  local repo="$1"
  (
    cd "$repo" || return 1
    local CAND=""
    # precise message grep first (unique to c33736b)
    CAND=$(git log --all --oneline --grep="fingertip radius" 2>/dev/null | head -20)
    [ -z "$CAND" ] && CAND=$(git log --all --oneline --grep="standard tap slop" 2>/dev/null | head -20)
    # content search as fallback (still message-validated below)
    [ -z "$CAND" ] && CAND=$(git log --all --oneline -S "kExpandSlopFactorForZeroTouchMajor" 2>/dev/null | head -20)
    [ -z "$CAND" ] && CAND=$(git log --all --oneline -S "touch_major" 2>/dev/null | head -40)
    if [ -n "$CAND" ]; then
      local sha
      for sha in $(echo "$CAND" | awk '{print $1}'); do
        local MSG; MSG=$(git log -1 --format="%s" "$sha" 2>/dev/null)
        echo "    candidate $sha : $MSG"
        if echo "$MSG" | grep -qi "fingertip\|standard tap slop\|kExpandSlopFactorForZeroTouchMajor\|touch_major"; then
          echo "    -> message matches slop fix; trying $sha"
          if write_patch_for_sha "$sha"; then return 0; fi
        fi
      done
      echo "    !! no candidate passed message validation in $repo"
      return 2
    fi
    # dangling scan
    local DANGLING FOUND=""
    DANGLING=$(git fsck --no-reflogs 2>/dev/null | grep -i "dangling commit" | awk '{print $3}')
    for c in $DANGLING; do
      local MSG; MSG=$(git log -1 --format="%s" "$c" 2>/dev/null)
      if echo "$MSG" | grep -qi "fingertip\|standard tap slop\|kExpandSlopFactorForZeroTouchMajor\|touch_major\|caret\|smooth native touch"; then FOUND="$c"; break; fi
    done
    if [ -n "$FOUND" ]; then
      echo "    found dangling $FOUND : $(git log -1 --format='%s' "$FOUND")"
      if write_patch_for_sha "$FOUND"; then return 0; fi
    fi
    return 2
  )
}

FOUND_ANY=0
if [ -n "$C337_REF" ]; then
  echo "[using C337_REF=$C337_REF]"
  if git -C "$SRC" cat-file -e "$C337_REF^{commit}" 2>/dev/null; then
    if write_patch_for_sha "$C337_REF"; then FOUND_ANY=1; else echo "!! format-patch failed for $C337_REF"; fi
  else
    echo "!! C337_REF=$C337_REF not valid in src; will still try overlay repo below"
  fi
fi

if [ "$FOUND_ANY" = "0" ]; then
  echo "[scan overlay repo FIRST: $OVERLAY_REPO]"
  if [ -d "$OVERLAY_REPO/.git" ]; then
    if export_patch_from_repo "$OVERLAY_REPO"; then FOUND_ANY=1; fi
  else
    echo "    $OVERLAY_REPO is not a git repo (or no .git). Checking the overlay file as a plain diff instead..."
    if [ -f "$OVERLAY_REPO/$OVL_TOUCH" ]; then
      echo "    found overlay file: $OVL_TOUCH"
      echo "    (manual step: 'cd $OVERLAY_REPO && git diff -- $OVL_TOUCH' to capture it)"
    fi
  fi
fi

if [ "$FOUND_ANY" = "0" ]; then
  echo "[scan src repo (fallback)]"
  if export_patch_from_repo "$SRC"; then FOUND_ANY=1; fi
fi

if [ "$FOUND_ANY" = "0" ]; then
  echo "!! c33736b NOT found in overlay nor src git history."
  echo "   The fix IS in the compiled libweb_engine.so (current HAP is fine)."
  echo "   To save the source for future rebuilds, locate the commit manually:"
  echo "     - in src:     git log --all -S touch_major   (or pass C337_REF=<sha>)"
  echo "     - in overlay: cd $OVERLAY_REPO && git log --all -S touch_major"
  echo "   -> 01-c33736b-touch.patch NOT written."
fi

echo "== done =="
echo "local-patches contents:"
ls -la "$OUT" 2>/dev/null

echo ""
echo "== RE-APPLY ORDER (on a fresh upstream re-sync, AFTER author's 44 incremental patches + overlay) =="
echo "  1) OVERLAY repo (chromium-hmos):  git apply 01-c33736b-touch.patch"
echo "     (it patches overlay/arkweb/ohos_nweb/src/aura_shell/ohos_aura_input_router.cc)"
echo "  2) SRC repo (chromium/src):       git apply 02a-paint-hold-a.patch"
echo "  3) SRC repo (chromium/src):       git apply 02b-paint-hold-b.patch"
echo "  NOTE: c33736b must be applied in the OVERLAY repo, A+B in the SRC repo."
