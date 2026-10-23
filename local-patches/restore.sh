#!/usr/bin/env bash
# restore.sh — 把 4 块本地原创引擎修改从 local-patches/snapshots 还原回仓库。
#
# 适用场景：万一某次同步上游（或误操作 git reset/checkout/merge）把 overlay/
# 或 patches/ 里的原创文件冲掉，用本脚本一键还原，并校验指纹是否一致。
#
# 用法（在 Git Bash / WSL 中，仓库根目录或任意位置）：
#   bash local-patches/restore.sh            # 自动定位仓库根
#   bash local-patches/restore.sh /path/to/chromium-hmos
set -euo pipefail

REPO="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SNAP="${REPO}/local-patches/snapshots"
MANIFEST="${REPO}/local-patches/MANIFEST.txt"

# 去掉字符串首尾空白
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

echo "Restoring protected originals into: ${REPO}"
[[ -f "${MANIFEST}" ]] || { echo "  [FAIL] MANIFEST.txt missing at ${MANIFEST}"; exit 1; }

ok=1
while IFS= read -r raw; do
  raw="${raw%$'\r'}"
  [[ "$raw" == \#* || -z "$raw" ]] && continue   # 注释/空行
  [[ "$raw" == BLOCK* ]] && continue              # 表头
  block="$(trim "${raw%%|*}")"
  file="$(trim "$(printf '%s' "$raw" | cut -d'|' -f2)")"
  sha="$(trim "$(printf '%s' "$raw" | cut -d'|' -f3)")"

  src="${SNAP}/${file}"
  dst="${REPO}/${file}"
  if [[ ! -f "${src}" ]]; then
    echo "  [MISSING] snapshot not found: ${file}"
    ok=0
    continue
  fi
  mkdir -p "$(dirname "${dst}")"
  cp -f "${src}" "${dst}"
  cur="$(git -C "${REPO}" hash-object "${dst}")"
  if [[ "${cur}" == "${sha}" ]]; then
    echo "  [OK]   ${file}  (restored, blob ${cur})"
  else
    echo "  [WARN] ${file}  restored but blob ${cur} != manifest ${sha}"
    ok=0
  fi
done < "${MANIFEST}"

if [[ "${ok}" == 1 ]]; then
  echo "RESTORE_OK: all protected originals restored and fingerprint-matched."
else
  echo "RESTORE_WARN: some files need attention (see above)."
fi
