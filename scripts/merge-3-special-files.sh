#!/usr/bin/env bash
# ============================================================================
#  WSL 里跑：把 3 个「特殊文件」从「我们的 154 版本」迁移到「155 上游版本」之上。
#
#  背景（必读）：
#   prepare-local-155.sh 阶段5 把本仓 overlay/ 原样 rsync 进 155 树（去前缀），
#   所以这 3 个文件目前在 155 树里是【我们的 154 版本】，并非 155 上游版。
#   155 上游版只存在于上游仓库 miramira8295/chromium-hmos，需只读 clone 一次。
#
#  策略（对应《155升级-本土优化迁移清单.md》§2）：
#   - shell_store_user_agent_ohos.cc : 我们的是 155 上游的严格子集(0/71) → 直接用 155 上游版覆盖。
#   - aura_shell_runtime_bridge.h    : 小差异(12/4) → 三方合并。
#   - aura_shell_runtime_bridge.cc   : 大幅分叉(545/365) → 三方合并；冲突处保留 155 结构 + 补回我们的独有逻辑。
#
#  三方合并： ours=我们的154版(SRC154)  base=上游154版(UP@BR154)  theirs=上游155版(UP@BR155)
#  结果 = 155 上游版之上叠加我们的自定义（UA-pin / AuraShell 桥等）。
#
#  稳健性：克隆后 hmos-154/hmos-155-adapter 只是 origin/ 远程跟踪分支，没有本地分支，
#   故脚本自动解析 ref（本地 / origin/ / refs/remotes/origin/）；并自动探测上游仓内路径前缀。
# ============================================================================
set -euo pipefail

# ---- 可调环境变量（按你本机实际情况改）------------------------------------
UPSTREAM_DIR="${UPSTREAM_DIR:-/home/administrator/upstream-chromium-hmos}"   # 克隆的上游只读副本
BR154="${BR154:-hmos-154-adapter}"                                           # 上游 154 分支（注意带 -adapter 后缀）
BR155="${BR155:-hmos-155-adapter}"                                           # 上游 155 分支
SRC154="${SRC154:-/home/administrator/chromium-work/chromium/src}"           # 我们的 154 树
SRC155="${SRC155:-/home/administrator/chromium-155/src}"                     # 准备好的 155 树
REL="chrome/browser/ui/ohos"                                                # 155 树内相对路径
UP_REL="${UP_REL:-chrome/browser/ui/ohos}"                                   # 上游仓内相对路径（可覆盖；脚本会同时尝试候选前缀）
# ---------------------------------------------------------------------------

if [[ ! -d "$UPSTREAM_DIR/.git" ]]; then
  cat >&2 <<EOF
✗ UPSTREAM_DIR 没指向克隆好的上游仓库：$UPSTREAM_DIR
  先做一次只读 clone（零打扰允许 clone，不会触发任何公开互动）：
    git clone --filter=blob:none https://github.com/miramira8295/chromium-hmos.git "$UPSTREAM_DIR"
  若上游分支名不是 hmos-154-adapter / hmos-155-adapter，用 BR154=... BR155=... 覆盖。
  若上游仓内路径不是 chrome/browser/ui/ohos，用 UP_REL=... 覆盖。
EOF
  exit 1
fi
if [[ ! -f "$SRC154/$REL/aura_shell_runtime_bridge.cc" ]]; then
  echo "✗ 在 SRC154 找不到我们的 154 版：$SRC154/$REL/aura_shell_runtime_bridge.cc" >&2; exit 1
fi
if [[ ! -f "$SRC155/$REL/aura_shell_runtime_bridge.cc" ]]; then
  echo "✗ 在 SRC155 找不到目标文件：$SRC155/$REL/aura_shell_runtime_bridge.cc" >&2; exit 1
fi

norm() { sed 's/\r$//'; }   # CRLF→LF，避免 merge-file 因行尾误判（本仓 overlay 是 CRLF）

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

# 在 ref 的树里找文件（自动探测前缀：UP_REL 优先，再退而求其次试常见前缀）
find_up_path() {
  local ref="$1" name="$2" p
  for p in "$UP_REL/$name" "chrome/browser/ui/ohos/$name" "overlay/chrome/browser/ui/ohos/$name"; do
    if git -C "$UPSTREAM_DIR" cat-file -e "$ref:$p" 2>/dev/null; then
      echo "$p"; return 0
    fi
  done
  return 1
}

# 上游版本抽取（base=154, theirs=155），归一化到 LF
up_show() { git -C "$UPSTREAM_DIR" show "$1:$2" 2>/dev/null | norm; }

merge_one() {
  local base="$1" ours="$2" theirs="$3" out="$4" label="$5"
  norm < "$base"   > "$tmp/base"
  norm < "$ours"   > "$tmp/ours"
  norm < "$theirs" > "$tmp/theirs"
  echo ">>> $label"
  if git merge-file -p --diff3 \
        -L "155-upstream" -L "154-upstream" -L "our-154" \
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
echo "=== merge-3-special-files.sh @ $(date '+%H:%M:%S') ==="
echo "  UP=$UPSTREAM_DIR  BR154=$BR154  BR155=$BR155"
echo "  SRC154=$SRC154"
echo "  SRC155=$SRC155"
echo

# ---- 解析 ref（克隆后多为 origin/ 远程跟踪分支）---------------------------
ref154=$(resolve_ref "$BR154") || {
  echo "✗ 无法解析上游 154 分支：$BR154" >&2
  echo "   上游仓可用 refs（含 154/155/hmos）：" >&2
  git -C "$UPSTREAM_DIR" for-each-ref --format='     %(refname:short)' 2>/dev/null | grep -iE '154|155|hmos' >&2 || true
  exit 1
}
ref155=$(resolve_ref "$BR155") || {
  echo "✗ 无法解析上游 155 分支：$BR155" >&2
  echo "   上游仓可用 refs（含 154/155/hmos）：" >&2
  git -C "$UPSTREAM_DIR" for-each-ref --format='     %(refname:short)' 2>/dev/null | grep -iE '154|155|hmos' >&2 || true
  exit 1
}
echo "  resolved: 154=$ref154  155=$ref155"
echo

# 1) shell_store_user_agent_ohos.cc —— 直接用 155 上游版
echo ">>> shell_store_user_agent_ohos.cc（直接用 155 上游版，0/71 子集）"
p155=$(find_up_path "$ref155" "shell_store_user_agent_ohos.cc") || {
  echo "    ✗ 上游 155 找不到 shell_store_user_agent_ohos.cc（候选前缀均失败）" >&2
  echo "    ※ 上游仓全树搜索结果（若有，请用 UP_REL= 前缀覆盖）：" >&2
  git -C "$UPSTREAM_DIR" rev-list --all --objects 2>/dev/null | grep -i "shell_store_user_agent_ohos.cc" >&2 | head || true
  exit 1
}
echo "    upstream path: $p155"
up_show "$ref155" "$p155" > "$tmp/theirs_cc"
cp "$tmp/theirs_cc" "$SRC155/$REL/shell_store_user_agent_ohos.cc"
echo "    ✅ 已用 155 上游版覆盖 $SRC155/$REL/shell_store_user_agent_ohos.cc"

# 2) aura_shell_runtime_bridge.h
echo
ph_base=$(find_up_path "$ref154" "aura_shell_runtime_bridge.h") || {
  echo "    ✗ 上游 154 找不到 aura_shell_runtime_bridge.h" >&2
  git -C "$UPSTREAM_DIR" rev-list --all --objects 2>/dev/null | grep -i "aura_shell_runtime_bridge.h" >&2 | head || true
  exit 1
}
ph_theirs=$(find_up_path "$ref155" "aura_shell_runtime_bridge.h") || {
  echo "    ✗ 上游 155 找不到 aura_shell_runtime_bridge.h" >&2
  git -C "$UPSTREAM_DIR" rev-list --all --objects 2>/dev/null | grep -i "aura_shell_runtime_bridge.h" >&2 | head || true
  exit 1
}
echo "    upstream base: $ph_base   theirs: $ph_theirs"
up_show "$ref154" "$ph_base" > "$tmp/base_h"
up_show "$ref155" "$ph_theirs" > "$tmp/theirs_h"
merge_one "$tmp/base_h" "$SRC154/$REL/aura_shell_runtime_bridge.h" "$tmp/theirs_h" \
          "$SRC155/$REL/aura_shell_runtime_bridge.h" "aura_shell_runtime_bridge.h"

# 3) aura_shell_runtime_bridge.cc
echo
pc_base=$(find_up_path "$ref154" "aura_shell_runtime_bridge.cc") || {
  echo "    ✗ 上游 154 找不到 aura_shell_runtime_bridge.cc" >&2
  git -C "$UPSTREAM_DIR" rev-list --all --objects 2>/dev/null | grep -i "aura_shell_runtime_bridge.cc" >&2 | head || true
  exit 1
}
pc_theirs=$(find_up_path "$ref155" "aura_shell_runtime_bridge.cc") || {
  echo "    ✗ 上游 155 找不到 aura_shell_runtime_bridge.cc" >&2
  git -C "$UPSTREAM_DIR" rev-list --all --objects 2>/dev/null | grep -i "aura_shell_runtime_bridge.cc" >&2 | head || true
  exit 1
}
echo "    upstream base: $pc_base   theirs: $pc_theirs"
up_show "$ref154" "$pc_base" > "$tmp/base_cc"
up_show "$ref155" "$pc_theirs" > "$tmp/theirs_cc2"
merge_one "$tmp/base_cc" "$SRC154/$REL/aura_shell_runtime_bridge.cc" "$tmp/theirs_cc2" \
          "$SRC155/$REL/aura_shell_runtime_bridge.cc" "aura_shell_runtime_bridge.cc"

echo
echo "✅ 处理完毕。下一步："
echo "   1) 在 $SRC155 里搜 <<<<<<< 解冲突（保留 155 结构，补回我们的 UA-pin / AuraShell 桥逻辑）。"
echo "   2) 解完用下面的命令核对我们的关键符号是否还在："
echo "      grep -nE 'PinnedUserAgent|SetAuraShellUserAgentPinned|IsAuraShellUserAgentPinned|ApplyUserAgentToAllTabs|UpdateBrowserStateOnUiThread' \\"
echo "        $SRC155/$REL/aura_shell_runtime_bridge.cc"
echo "   3) git -C \"$SRC155\" status 看改动是否合理，再全量编 155 引擎。"
