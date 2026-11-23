#!/usr/bin/env bash
# 在 WSL 原生文件系统里「重新应用 157 快照 + overlay」（不重跑昂贵的 gclient sync）。
# 等价于 prepare-local-157.sh 的阶段 3~7，用于：树被 reset 后重贴本土改动、或上游更新后重锚。
# 幂等：apply-157-snapshot.py 用 receipt 防重复；rsync 天然幂等。
# 跑完本脚本后，再跑 apply-our-157-mods.sh 叠加我们的 155 优化即可编译。
set -u
SRC=/home/administrator/chromium-157/src
REPO=/mnt/d/WorkBuddy/鸿蒙Chrome/chromium-hmos-157
P="$REPO/patches"
LOG=/tmp/refresh-157.log
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
say(){ printf '\n=== %s\n' "$*"; }

say "1) 157 迁移快照（migration-157 + 13 included_incremental_patches，幂等）"
python3 - "$REPO/scripts/apply-157-snapshot.py" "$SRC" || { echo "迁移快照失败，停在上面"; exit 1; }

say "2) overlay + deps_code 重新同步（含我们的 155→157 壳移植）"
rsync -a --checksum --no-times "$REPO/overlay/" "$SRC/"
mkdir -p "$(dirname "$SRC")/deps_code/webview"
rsync -a --checksum --no-times "$REPO/external/deps_code/webview/" "$(dirname "$SRC")/deps_code/webview/"

say "3) 工具链 hooks（已就绪则跳过）"
root="$(dirname "$SRC")"
revision=7d4508cbfffd289d7015f7703bce215d3ab123bf
if [[ ! -f "$root/.hooks-$revision" ]]; then
  (cd "$root" && gclient runhooks)
  touch "$root/.hooks-$revision"
fi

say "4) 修正 args.gn（157 移除了 enterprise_client_certificates）"
out_dir="$SRC/out/plan_kirin_pc"
mkdir -p "$out_dir"
[[ -f "$out_dir/args.gn" ]] || cp "$REPO/config/args.plan_kirin_pc.gn" "$out_dir/args.gn"
python3 - "$out_dir/args.gn" <<'PY'
from pathlib import Path
import re
p = Path(sys.argv[1]); b = p.read_text()
a = re.sub(r'^\s*enterprise_client_certificates\s*=.*\n', '', b, flags=re.M)
if a != b: p.write_text(a)
PY

say "完成：迁移+overlay 已重新应用（日志 $LOG）。下一步：bash $REPO/scripts/apply-our-157-mods.sh"
