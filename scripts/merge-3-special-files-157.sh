#!/usr/bin/env bash
# ============================================================================
#  WSL 里跑：把 2 个「特殊文件」(aura_shell_runtime_bridge.cc/.h) 从「我们的 155 版本」
#  迁移到「157 上游版本」之上。shell_store_user_agent_ohos.cc 在 155 未改，直接用 157 上游版。
#
#  背景：
#   prepare-local-157.sh 阶段5 把本仓 overlay/ 原样 rsync 进 157 树（去前缀），
#   所以这 2 个文件目前在 157 树里是【157 上游版】，并非我们 155 的改法。
#   我们要把 155 上叠加的本土优化（UA-pin / AuraShell 桥）再叠到 157 上游结构上。
#
#  三方合并： ours=我们的155版(SRC155_MOD)  base=上游155版(UP@BR155)  theirs=上游157版(UP@BR157)
#  结果 = 157 上游版之上叠加我们的 UA-pin / AuraShell 桥逻辑。
#
#  稳健性：克隆后分支只是 origin/ 远程跟踪分支，脚本自动解析 ref（本地 / origin/ / refs/remotes/origin/）；
#   并自动探测上游仓内路径前缀（UP_REL / chrome/browser/ui/ohos / overlay/chrome/browser/ui/ohos）。
# ============================================================================
set -euo pipefail

# ---- 可调环境变量 ----------------------------------------------------------
UPSTREAM_DIR="${UPSTREAM_DIR:-/home/administrator/upstream-chromium-hmos}"   # 克隆的上游只读副本（需含 hmos-155-adapter 与 hmos-157-adapter）
BR155="${BR155:-hmos-155-adapter}"                                           # 上游 155 分支
BR157="${BR157:-hmos-157-adapter}"                                           # 上游 157 分支
SRC155_MOD="${SRC155_MOD:-/home/administrator/chromium-155/src}"             # 我们的 155 树（含 155 本土优化）
SRC157="${SRC157:-/home/administrator/chromium-157/src}"                      # 准备好的 157 树
REL="chrome/browser/ui/ohos"                                                # 157 树内相对路径
UP_REL="${UP_REL:-chrome/browser/ui/ohos}"                                   # 上游仓内相对路径（可覆盖）
# ---------------------------------------------------------------------------

if [[ ! -d "$UPSTREAM_DIR/.git" ]]; then
  cat >&2 <<EOF
✗ UPSTREAM_DIR 没指向克隆好的上游仓库：$UPSTREAM_DIR
  先做一次只读 clone（零打扰允许 clone，不会触发任何公开互动）：
    git clone --filter=blob:none https://github.com/miramira8295/chromium-hmos.git "$UPSTREAM_DIR"
  然后确保两个分支都在（本地或 origin/ 均可）：
    git -C "$UPSTREAM_DIR" fetch origin hmos-155-adapter hmos-157-adapter
  若分支名不同，用 BR155=... BR157=... 覆盖。
EOF
  exit 1
fi
if [[ ! -f "$SRC155_MOD/$REL/aura_shell_runtime_bridge.cc" ]]; then
  echo "✗ 在 SRC155_MOD 找不到我们的 155 版：$SRC155_MOD/$REL/aura_shell_runtime_bridge.cc" >&2; exit 1
fi
if [[ ! -f "$SRC157/$REL/aura_shell_runtime_bridge.cc" ]]; then
  echo "✗ 在 SRC157 找不到目标文件：$SRC157/$REL/aura_shell_runtime_bridge.cc" >&2; exit 1
fi

norm() { sed 's/\r$//'; }   # CRLF→LF，避免 merge-file 因行尾误判

# 解析分支 ref：本地分支 → origin/xxx → refs/remotes/origin/xxx
resolve_ref() {
  local b="$1" r
  for r in "$b" "origin/$b" "refs/remotes/origin/$b"; do
    if git -C "$UPSTREAM_DIR" rev-parse --quiet --verify "$r" >/dev/null 2>&1; then
      echo "$r"; return 0
    fi
  done
  return 1
}

# 在 ref 的树里找文件（自动探测前缀）
find_up_path() {
  local ref="$1" name="$2" p
  for p in "$UP_REL/$name" "chrome/browser/ui/ohos/$name" "overlay/chrome/browser/ui/ohos/$name"; do
    if git -C "$UPSTREAM_DIR" cat-file -e "$ref:$p" 2>/dev/null; then
      echo "$p"; return 0
    fi
  done
  return 1
}

up_show() { git -C "$UPSTREAM_DIR" show "$1:$2" 2>/dev/null | norm; }

merge_one() {
  local base="$1" ours="$2" theirs="$3" out="$4" label="$5"
  norm < "$base"   > "$tmp/base"
  norm < "$ours"   > "$tmp/ours"
  norm < "$theirs" > "$tmp/theirs"
  echo ">>> $label"
  if git merge-file -p --diff3 \
        -L "157-upstream" -L "155-upstream" -L "our-155" \
        "$tmp/theirs" "$tmp/base" "$tmp/ours" > "$tmp/merged"; then
    cp "$tmp/merged" "$out"
    echo "    ✅ 干净合并 → $out"
    return 0
  else
    cp "$tmp/merged" "$out"
    local n; n=$(grep -c '^<<<<<<< ' "$out" || true)
    echo "    ⚠ 有 $n 处冲突，已带 <<<<<<< 标记写入 $out，需手动解冲突"
    return 1
  fi
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
echo "=== merge-3-special-files-157.sh @ $(date '+%H:%M:%S') ==="
echo "  UP=$UPSTREAM_DIR  BR155=$BR155  BR157=$BR157"
echo "  SRC155_MOD=$SRC155_MOD"
echo "  SRC157=$SRC157"
echo

ref155=$(resolve_ref "$BR155") || {
  echo "✗ 无法解析上游 155 分支：$BR155" >&2
  git -C "$UPSTREAM_DIR" for-each-ref --format='     %(refname:short)' 2>/dev/null | grep -iE '154|155|157|hmos' >&2 || true
  exit 1
}
ref157=$(resolve_ref "$BR157") || {
  echo "✗ 无法解析上游 157 分支：$BR157（需先 fetch hmos-157-adapter）" >&2
  git -C "$UPSTREAM_DIR" for-each-ref --format='     %(refname:short)' 2>/dev/null | grep -iE '154|155|157|hmos' >&2 || true
  exit 1
}
echo "  resolved: 155=$ref155  157=$ref157"
echo

# 1) shell_store_user_agent_ohos.cc —— 155 未改它，直接用 157 上游版
echo ">>> shell_store_user_agent_ohos.cc（155 未改，直接用 157 上游版）"
p157=$(find_up_path "$ref157" "shell_store_user_agent_ohos.cc") || {
  echo "    ✗ 上游 157 找不到 shell_store_user_agent_ohos.cc" >&2; exit 1
}
echo "    upstream path: $p157"
up_show "$ref157" "$p157" > "$tmp/theirs_cc"
cp "$tmp/theirs_cc" "$SRC157/$REL/shell_store_user_agent_ohos.cc"
echo "    ✅ 已用 157 上游版覆盖 $SRC157/$REL/shell_store_user_agent_ohos.cc"

# 2) aura_shell_runtime_bridge.h
echo
ph_base=$(find_up_path "$ref155" "aura_shell_runtime_bridge.h") || {
  echo "    ✗ 上游 155 找不到 aura_shell_runtime_bridge.h" >&2; exit 1
}
ph_theirs=$(find_up_path "$ref157" "aura_shell_runtime_bridge.h") || {
  echo "    ✗ 上游 157 找不到 aura_shell_runtime_bridge.h" >&2; exit 1
}
echo "    upstream base: $ph_base   theirs: $ph_theirs"
up_show "$ref155" "$ph_base" > "$tmp/base_h"
up_show "$ref157" "$ph_theirs" > "$tmp/theirs_h"
merge_one "$tmp/base_h" "$SRC155_MOD/$REL/aura_shell_runtime_bridge.h" "$tmp/theirs_h" \
          "$SRC157/$REL/aura_shell_runtime_bridge.h" "aura_shell_runtime_bridge.h" || true

# 3) aura_shell_runtime_bridge.cc
echo
pc_base=$(find_up_path "$ref155" "aura_shell_runtime_bridge.cc") || {
  echo "    ✗ 上游 155 找不到 aura_shell_runtime_bridge.cc" >&2; exit 1
}
pc_theirs=$(find_up_path "$ref157" "aura_shell_runtime_bridge.cc") || {
  echo "    ✗ 上游 157 找不到 aura_shell_runtime_bridge.cc" >&2; exit 1
}
echo "    upstream base: $pc_base   theirs: $pc_theirs"
up_show "$ref155" "$pc_base" > "$tmp/base_cc"
up_show "$ref157" "$pc_theirs" > "$tmp/theirs_cc2"
merge_one "$tmp/base_cc" "$SRC155_MOD/$REL/aura_shell_runtime_bridge.cc" "$tmp/theirs_cc2" \
          "$SRC157/$REL/aura_shell_runtime_bridge.cc" "aura_shell_runtime_bridge.cc" || true

echo
echo "=== 冲突汇总（需手动解）==="
c_h=$(grep -c '^<<<<<<< ' "$SRC157/$REL/aura_shell_runtime_bridge.h" 2>/dev/null || true)
c_cc=$(grep -c '^<<<<<<< ' "$SRC157/$REL/aura_shell_runtime_bridge.cc" 2>/dev/null || true)
echo "  aura_shell_runtime_bridge.h : ${c_h:-0} 处"
echo "  aura_shell_runtime_bridge.cc: ${c_cc:-0} 处"
echo "  shell_store_user_agent_ohos.cc: 0（已直接用 157 上游版覆盖）"
echo
echo "✅ 处理完毕。下一步："
echo "   1) 在 $SRC157/$REL 里搜 <<<<<<< 解冲突（保留 157 结构，补回我们的 UA-pin / AuraShell 桥逻辑）。"
echo "   2) 解完用下面命令核对关键符号是否还在："
echo "      grep -nE 'PinnedUserAgent|SetAuraShellUserAgentPinned|IsAuraShellUserAgentPinned|ApplyUserAgentToAllTabs|UpdateBrowserStateOnUiThread' \\"
echo "        $SRC157/$REL/aura_shell_runtime_bridge.cc"
echo "   3) 解完冲突后全量编 157 引擎。"
