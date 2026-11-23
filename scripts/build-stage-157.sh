#!/usr/bin/env bash
# One-click 157 build + stage.
#
# Chains the two existing WSL scripts in order:
#   1) scripts/build-157-now.sh      (incremental engine rebuild)
#   2) scripts/package-157-stage.sh   (stage .so/paks into the Windows HAP project)
#
# Run it inside WSL. If you launch it from a Windows shell (Git Bash / cmd),
# it re-executes itself under WSL automatically, so a single command works
# from anywhere.
#
# After this finishes, run the Windows-side packager:
#   scripts\package-157-hap.cmd [release]
#
# Optional: pass --hap to ALSO launch scripts\package-157-hap.cmd via cmd.exe
# once staging is done (skips the manual Windows step). Experimental: relies on
# hdc / the signing tool being reachable from the cmd.exe WSL launches.
#
# All text is ASCII on purpose: WSL bash under a non-UTF-8 locale has been
# observed to mis-parse multi-byte characters in comments.

set -uo pipefail

# --- auto re-exec under WSL if launched from a Windows shell ----------------
if [[ ! -f /proc/version ]] || ! grep -qi microsoft /proc/version 2>/dev/null; then
  if command -v wsl >/dev/null 2>&1 && [[ "${0:0:1}" == "/" ]]; then
    # Git-Bash-style path like /d/WorkBuddy/.../scripts/build-stage-157.sh
    s="${0#/}"                     # d/WorkBuddy/.../scripts/build-stage-157.sh
    dl="${s%%/*}"; rest="${s#*/}"  # d , WorkBuddy/.../scripts/build-stage-157.sh
    wsl_self="/mnt/$(echo "$dl" | tr '[:lower:]' '[:upper:]')/$rest"
    args=()
    for a in "$@"; do args+=("$(printf '%q' "$a")"); done
    echo "=== [wrapper] not in WSL; re-executing under WSL: $wsl_self ==="
    exec wsl bash -c "bash $(printf '%q' "$wsl_self") ${args[*]}"
  fi
  echo "ERROR: not running under WSL and cannot re-exec. Please run inside WSL:" >&2
  echo "  wsl bash -c \"cd /mnt/d/WorkBuddy/鸿蒙Chrome/chromium-hmos-157 && bash scripts/build-stage-157.sh\"" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HAP_FLAG=0
for a in "$@"; do
  [[ "$a" == "--hap" ]] && HAP_FLAG=1
done

echo "########## [1/2] build 157 engine ##########"
bash "$SCRIPT_DIR/build-157-now.sh"
build_rc=$?
if [[ $build_rc -ne 0 ]]; then
  echo "ERROR: build-157-now.sh failed (exit $build_rc). Aborting before stage." >&2
  exit $build_rc
fi

echo
echo "########## [2/2] stage into Windows HAP project ##########"
bash "$SCRIPT_DIR/package-157-stage.sh"
stage_rc=$?
if [[ $stage_rc -ne 0 ]]; then
  echo "ERROR: package-157-stage.sh failed (exit $stage_rc)." >&2
  exit $stage_rc
fi

echo
echo "########## ALL DONE ##########"

if [[ $HAP_FLAG -eq 1 ]]; then
  # Packaging is deliberately NOT launched from here. WSL->cmd.exe interop
  # re-escapes quotes in argv, so a Windows path sent from this script arrives
  # as  \"D:\...\package-157-hap.cmd\"  and cmd treats the whole thing as a
  # literal command name (observed 2026-11-23). Keep the boundary at the OS
  # edge: WSL builds + stages, the Windows one-click wrapper does the packaging.
  echo "=== [wrapper] build + stage done; packaging is handled on the Windows side ==="
else
  echo "Next (on Windows): scripts\\package-157-hap.cmd [release]"
fi

exit 0
