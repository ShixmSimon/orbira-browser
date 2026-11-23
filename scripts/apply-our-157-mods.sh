#!/usr/bin/env bash
# 在 157 源码树（prepare-local-157.sh 已就绪）之上，叠加我们的 155 本土优化。
# 前置：prepare-local-157.sh 已跑完，且 /home/administrator/chromium-157/src 已存在。
#
# 与 155 的差异（重要）：
#   155 的本土优化在 overlay/ 里，prepare 阶段 rsync 直接落地；157 的 overlay 是「157 上游版」，
#   引擎文件需三方重锚才能落到 157 树。所以本脚本直接调用 157-reanchor-patches.py：
#     - 阶段 A：overlay 引擎文件 3-way 重锚，直接写回 src157（ours=155版 / base=155-adapter / theirs=157版）
#     - 阶段 B：3 个改谷歌原版文件的核心补丁（白闪A+底部裁切⑧ / 白闪B / 小锁③+扩展origin）
#               重锚并【直接写回 src157】，同时产出 patches/157-port/ohos-157-*.patch 留档（用于后续同步上游）。
#   因此本脚本【不再 git apply 这 3 个补丁】——它们已被阶段 B 写回；补丁文件是给未来上游同步用的记录。
set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 155 工作仓（Windows 路径在 WSL 下需换成 /mnt/d/...）；155 完整树（阶段B 还原 base 用）
readonly repo155="${CHROMIUM_155_REPO:-/mnt/d/WorkBuddy/鸿蒙Chrome/chromium-hmos-155}"
readonly src155="${CHROMIUM_155_SRC:-/home/administrator/chromium-155/src}"
readonly src157="${CHROMIUM_157_SRC:-/home/administrator/chromium-157/src}"
readonly pp="$repo_root/patches/157-port"

if [[ ! -d "$src157/.git" ]]; then echo "157 源码树不存在: $src157（请先跑 prepare-local-157.sh）" >&2; exit 1; fi
if [[ ! -d "$repo155/.git" ]]; then echo "155 工作仓不存在: $repo155" >&2; exit 1; fi

# 1) 重锚（阶段 A 写回 overlay 引擎文件 + 阶段 B 写回 3 个核心补丁并产出留档 patch）
echo ">>> [1/2] 155→157 引擎重锚（需 155 工作仓 + 155 树 + 157 树都在）"
python3 "$repo_root/scripts/157-reanchor-patches.py" \
    --repo155 "$repo155" \
    --src155  "$src155" \
    --src157  "$src157"
echo "    重锚产物见 $pp/ohos-157-*.patch（阶段 B 已直接写回 157 树，此文件为留档/上游同步用）。"

# 2) 特殊文件 3-way 合并（aura_shell_runtime_bridge.cc/.h；shell_store_user_agent_ohos.cc 直接用 157 上游版）
echo ">>> [2/2] 特殊文件 3-way 合并（UA-pin / AuraShell 桥）"
bash "$repo_root/scripts/merge-3-special-files-157.sh"

echo
echo "✅ 157 本土优化已叠加："
echo "   - 阶段 A：overlay 引擎文件（白闪A/B、底部裁切⑧、扩展管理、ChatGPT 分配器、小锁③、桌面版④ 等）已重锚写回"
echo "   - 阶段 B：3 个核心补丁（含白闪A）已写回 157 树"
echo "   - 特殊文件：aura_shell_runtime_bridge.cc/.h 已 3-way 合并（如有 <<<<<<< 需手解）"
echo "之后即可全量编 157 引擎（build-157-now.sh）。"
