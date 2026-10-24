#!/usr/bin/env bash
# 在 155 源码树就绪后，叠加我们的本地优化（5 个 patch + 手动合并 3 个特殊文件）。
# 前置：prepare-local-155.sh 已跑完，且 /root/chromium-154/src 仍在（重锚需要）。
set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 154 源与 155 目标都可用环境变量覆盖：
#   CHROMIUM_154_SRC   = 154 的 src 目录（含 .git）
#   CHROMIUM_155_ROOT  = 155 目标根目录（脚本内派生 src = <root>/src）
readonly src154="${CHROMIUM_154_SRC:-/root/chromium-154/src}"
readonly src155="${CHROMIUM_155_SRC:-${CHROMIUM_155_ROOT:-/root/chromium-155}/src}"
readonly pp="$repo_root/patches/155-port"
readonly pin="f043649a0ef1fd96e48d56ddbfc8a4a99aa2ca37"

if [[ ! -d "$src155/.git" ]]; then echo "155 源码树不存在: $src155" >&2; exit 1; fi
if [[ "$(git -C "$src155" rev-parse HEAD)" != "$pin" ]]; then
  echo "155 树 HEAD 不是 155 pin，请先跑 prepare-local-155.sh" >&2; exit 1
fi
if [[ ! -d "$src154/.git" ]]; then echo "154 源码树不存在: $src154（重锚需要）" >&2; exit 1; fi

# 1) 重锚 4 个改谷歌原版文件的 patch → 生成 patches/155-port/ohos-155-*.patch
echo ">>> [1/2] 3-way 重锚 155 patch（需要两棵树都在）"
python3 "$repo_root/scripts/155-reanchor-patches.py" --src154 "$src154" --src155 "$src155"
echo "    重锚产物见 $pp/ohos-155-*.patch；冲突见 $repo_root/reanchor-conflicts/"

# 2) 叠加本地优化 patch（仅重锚产出的 3 个改谷歌原版文件的 patch）
#    ⚠ 重要：155-port 里另有两个 patch（vulkan-gate / touch-slop）打的是 overlay/ 下的文件
#    （ui/ozone/platform/ohos/ohos_phone_gpu_channel.* 与 arkweb/.../ohos_aura_input_router.cc）。
#    这两个文件属于 miramira 的 overlay 目录，prepare-local-155.sh 阶段5 已把整个 overlay/
#    原样 rsync 进 155 的 src/（落地时去掉 overlay/ 前缀），而我们对它们的修改早已 bake 进
#    本仓 overlay/ 目录自身。因此它们是“冗余 + 旧路径前缀错误”，绝不能再 git apply，否则会
#    报 No such file（旧前缀）或 already applied（改前缀后）。下面只叠加 3 个谷歌原版文件的 patch。
apply_one() {
  local p="$1"
  if [[ ! -f "$p" ]]; then echo "  [MISSING] $(basename "$p")" >&2; return 1; fi
  if git -C "$src155" apply --check "$p" 2>/dev/null; then
    if git -C "$src155" apply "$p" 2>/dev/null; then
      echo "  [applied] $(basename "$p")"; return 0
    fi
    echo "  [FAIL]    $(basename "$p") apply 中途失败" >&2; return 1
  fi
  echo "  [FAIL]    $(basename "$p") 无法干净 apply —— 见下方 check 输出，需手动处理" >&2
  git -C "$src155" apply --check "$p" || true
  return 1
}

applied=(); failed=()
echo ">>> [2/2] 叠加本地优化 patch（仅 3 个重锚 patch；vulkan-gate/touch-slop 由 overlay 承载，跳过）"
for p in \
    "$pp/ohos-155-bottom-crop-painthold-a.patch" \
    "$pp/ohos-155-paint-hold-b.patch" \
    "$pp/ohos-155-extension-origin.patch"; do
  if apply_one "$p"; then applied+=("$(basename "$p")"); else failed+=("$(basename "$p")"); fi
done
echo
echo "  —— vulkan-gate / touch-slop 的修改已在本仓 overlay/ 内，prepare 阶段 rsync 直接落地，无需再 apply ——"
echo
echo "  [汇总] 已叠加 ${#applied[@]} 个：${applied[*]:-无}"
if ((${#failed[@]})); then
  echo "  [汇总] 失败 ${#failed[@]} 个：${failed[*]}（见上方 check 输出，需手动处理）"
fi

# 3) 手动合并提示
echo
echo "⚠ 仍需你手动合并 3 个特殊文件（155 基线 vs 我们的 UA-pin / AuraShell 桥增量）："
echo "   - content/browser/.../aura_shell_runtime_bridge.cc"
echo "   - content/browser/.../aura_shell_runtime_bridge.h"
echo "   - chrome/browser/.../shell_store_user_agent_ohos.cc"
echo "   方法：对比 $src154 里这些文件（我们的版本）与 $src155（当前为上游 155 版），"
echo "         把我们的增量段（UA pin 调用、桥接扩展逻辑）移植到 155 版本上。"
echo "   154 与本仓的对应关系见《155升级-本土优化迁移清单.md》§2。"
echo
echo "✅ patch 叠加完成（vulkan-gate/touch-slop 由 overlay 承载；3 个重锚 patch 见上方汇总；特殊文件需手动合）。之后即可全量编 155 引擎。"
