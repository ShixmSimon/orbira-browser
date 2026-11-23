#!/bin/bash
# Full 157 engine build inside WSL (same shape as build155-now.sh).
# Prereqs: prepare-local-157.sh + apply-our-157-mods.sh have been run.
#
# NOTE: keep ALL comments and echo text ASCII. WSL bash under a non-UTF-8
# locale has been observed to mis-parse multi-byte chars and try to execute
# part of a comment as a command ("command not found" at that line).
export PATH="${CHROMIUM_157_ROOT:-/home/administrator/chromium-157}/depot_tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games"
export DEPOT_TOOLS_METRICS=0
cd /home/administrator/chromium-157/src || exit 3

# overlay/ohos_nweb, ohos_build, ohos_glue are git symlinks (mode 120000),
# but the repo has core.symlinks=false, so Windows checkout degrades them to
# plain text files whose content is the link target. rsync into WSL keeps them
# as files. GN needs //ohos_nweb/src/aura_shell/BUILD.gn, so ohos_nweb must be
# a directory/link or gn gen fails with "Unable to load ... BUILD.gn".
# 155 had a real symlink there and built fine. Heal idempotently per run.
for link in ohos_nweb:arkweb/ohos_nweb ohos_build:arkweb/build ohos_glue:arkweb/glue; do
  name=${link%%:*}
  target=${link#*:}
  if [[ -L "$name" ]]; then
    continue  # already a symlink
  fi
  if [[ -f "$name" && ! -d "$name" && "$(cat "$name")" == "$target" ]]; then
    echo "=== [build-157-now] heal symlink: $name -> $target (was degraded to text) ==="
    rm -f "$name" || exit 6
    ln -s "$target" "$name" || exit 6
  elif [[ -e "$name" ]]; then
    echo "WARNING: $name exists but is not the expected link-target text; check manually" >&2
  else
    echo "=== [build-157-now] create symlink: $name -> $target ==="
    ln -s "$target" "$name" || exit 6
  fi
done

# 155 bottom-crop engine fix (analysis 2026-11-15): upstream 157
# GetOhosReservedHeight() reserves controls_px = top+bottom while browser
# controls are shown, so the renderer shrinks and the page jumps / a bottom
# strip appears and disappears. 155 forces {0,true} so the page always lays
# out at full height. Reanchor/prepare can restore the upstream version, so
# reapply idempotently before every build.
RWHV=content/browser/renderer_host/render_widget_host_view_aura.cc
UPSTREAM_RET='return {view->DoBrowserControlsShrinkRendererSize() ? controls : 0, true};'
FIXED_RET='return {0, true};  // [155 port] keep renderer full height, no bottom reserved strip'
if [[ -f "$RWHV" ]] && grep -qF "$UPSTREAM_RET" "$RWHV"; then
  echo "=== [build-157-now] apply bottom-crop reserved-height fix ==="
  sed -i "s|$UPSTREAM_RET|$FIXED_RET|" "$RWHV" || exit 8
  grep -qF "$FIXED_RET" "$RWHV" || { echo "bottom-crop fix did not apply" >&2; exit 8; }
elif [[ -f "$RWHV" ]] && ! grep -qF "$FIXED_RET" "$RWHV"; then
  echo "WARNING: $RWHV has an unexpected GetOhosReservedHeight; check manually" >&2
fi

# Build-registry guard (2026-11-23). The proxy service implementations
# (shell_proxy_ohos, shell_proxy_vault_ohos, proxy_config_service_ohos_native)
# are registered into chrome/browser/BUILD.gn and net/BUILD.gn by
# patches/migration-157/chromium.patch. A tree bootstrapped from an OLDER patch
# lacks those lines, and the link then fails with undefined
# chrome::ohos::settings_internal::*Proxy* symbols. Fail fast with a matching
# hint instead of a 25-minute build that dies at 99%.
for entry in \
  "chrome/browser/BUILD.gn:ui/ohos/shell_proxy_ohos.cc" \
  "chrome/browser/BUILD.gn:ui/ohos/shell_proxy_vault_ohos.cc" \
  "net/BUILD.gn:proxy_resolution/proxy_config_service_ohos_native.cc"; do
  registry="${entry%%:*}"
  needle="${entry#*:}"
  if ! grep -qF "$needle" "$registry" 2>/dev/null; then
    echo "ERROR: $registry does not register $needle" >&2
    echo "       This tree was bootstrapped from an older migration patch." >&2
    echo "       Add the line (see patches/migration-157/chromium.patch) and rerun." >&2
    exit 9
  fi
done

# Use in-tree ELF binaries directly, bypassing depot_tools gn/ninja/autoninja
# wrappers. This depot_tools was never bootstrapped (no python3_bin_reldir.txt),
# so python-bin/python3 in those wrappers fails immediately.
# 155 also built via in-tree binaries (its build.ninja header is
#   ../../buildtools/linux64/gn --root=../.. -q gen .) and build.ninja has no
# vpython3/depot_tools rules, so bare ninja == autoninja with explicit -j.
# runhooks may leave these binaries without +x; chmod idempotently.
GN_BIN=buildtools/linux64/gn
NINJA_BIN=third_party/ninja/ninja
for bin in "$GN_BIN" "$NINJA_BIN"; do
  if [[ ! -f "$bin" ]]; then
    echo "Missing binary: $bin (run prepare-local-157.sh runhooks first)" >&2
    exit 5
  fi
  [[ -x "$bin" ]] || chmod +x "$bin"
done

# gn gen is needed when:
#   1) build.ninja is absent (first build / cleaned out dir);
#   2) args.gn is newer than build.ninja (GN args changed);
#   3) GN sources changed -> handled by ninja's own regeneration rule.
# Otherwise skip, preserving gn output and the incremental cache.
out=out/plan_kirin_pc
if [[ ! -f "$out/build.ninja" || "$out/args.gn" -nt "$out/build.ninja" ]]; then
  if [[ -f "$out/build.ninja" ]]; then
    echo "=== [build-157-now] args.gn changed, re-running gn gen $out ==="
  else
    echo "=== [build-157-now] build.ninja missing, running gn gen $out ==="
  fi
  "./$GN_BIN" gen "$out" > "$out/gn-gen.log" 2>&1
  gn_rc=$?
  cat "$out/gn-gen.log"
  if [[ $gn_rc -ne 0 ]]; then
    echo "gn gen failed (see $out/gn-gen.log), aborting build" >&2
    echo "EXIT=$gn_rc"
    exit $gn_rc
  fi
  echo "=== gn gen done, starting build ==="
fi

# Rotate the previous log instead of overwriting it (tee truncates).
if [[ -s "$out/build.log" ]]; then
  stamp=$(date +%Y%m%d-%H%M%S)
  mv "$out/build.log" "$out/build.log.$stamp" || exit 7
  echo "=== [build-157-now] previous log saved as $out/build.log.$stamp ==="
fi

# Live progress: tee ninja output to both terminal and build.log.
# NINJA_STATUS adds [done/total]; a second terminal can also tail -f build.log.
export NINJA_STATUS='[%f/%t] '
echo "=== [build-157-now] Build starting, live progress below (log: $out/build.log) ==="
set -o pipefail
"./$NINJA_BIN" -j 8 -C "$out" libweb_engine web_render libnweb_render 2>&1 | tee "$out/build.log"
rc=${PIPESTATUS[0]}
echo
echo "=== [build-157-now] Build finished, exit $rc (full log: $out/build.log) ==="
if [[ $rc -ne 0 ]]; then
  echo "--- Error summary (FAILED / error lines, max 40) ---"
  grep -nE "FAILED:|error:|fatal error:|ninja: error" "$out/build.log" 2>/dev/null | head -40
fi
echo "EXIT=$rc"
exit $rc
