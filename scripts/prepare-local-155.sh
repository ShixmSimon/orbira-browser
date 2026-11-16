#!/usr/bin/env bash
# 本地 WSL 用：搭建 /root/chromium-155/src（155 pin = 155.0.8059.91 / f043649a0e）。
# 源自上游 scripts/prepare-chromium-155.sh，仅去掉 CI 守卫、加本地提示。
# 安全约定：只读从 /root/chromium-154 播种，绝不改 154 树。
set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 155 目标根目录：默认 /root/chromium-155（CI 约定）。本地若以普通用户跑、/root 不可写，
# 请用 CHROMIUM_155_ROOT 指到有权限的位置，例如 $HOME/chromium-155
readonly root="${CHROMIUM_155_ROOT:-/root/chromium-155}"
export CHROMIUM_155_ROOT="${root}"
readonly src="${root}/src"
# 154 源码树位置：默认 /root/chromium-154/src，可用环境变量覆盖（只传 src 目录）
readonly seed_src="${CHROMIUM_154_SRC:-/root/chromium-154/src}"
readonly seed_root="$(dirname "$seed_src")"
readonly revision="${CHROMIUM_REVISION:-f043649a0ef1fd96e48d56ddbfc8a4a99aa2ca37}"

if [[ ! -d "$seed_src/.git" || ! -f "$seed_root/.gclient" ]]; then
  cat >&2 <<EOF
找不到 154 源码树：$seed_src
（需要该目录下有 .git，且其父目录有 .gclient）

请确认你本机 154 的 Chromium 源码 checkout 在哪，然后用环境变量指过去，例如：
  CHROMIUM_154_SRC=$HOME/chromium-154/src \\
    bash /mnt/d/WorkBuddy/鸿蒙Chrome/chromium-hmos-155/scripts/prepare-local-155.sh

若不确定位置，可在 WSL 里执行：
  find /root /home /mnt -maxdepth 3 -name .gclient 2>/dev/null
EOF
  exit 1
fi

mkdir -p "$root" "$repo_root/build-status"
exec > >(tee -a "$repo_root/build-status/preparation-155-local.log") 2>&1

echo "=== prepare-local-155.sh 启动 @ $(date '+%Y-%m-%d %H:%M:%S') ==="
echo "    154 源  : $seed_src"
echo "    155 目标: $src"
echo "    pin     : $revision"
echo

readonly tools="$root/depot_tools"
prepare_tools() {
  if [[ ! -f "$tools/.ohos-bootstrap-ready" ]]; then
    mkdir -p "$tools"
    rsync -a "$seed_src/third_party/depot_tools/" "$tools/"
    tools_revision=$(python3 - "$src/DEPS" <<'PY'
import re, sys
from pathlib import Path
s = Path(sys.argv[1]).read_text()
s = s[s.index("'src/third_party/depot_tools':"):]
print(re.search(r'[0-9a-f]{40}', s).group())
PY
    )
    git -C "$tools" -c gc.auto=0 fetch --depth=1 origin "$tools_revision"
    git -C "$tools" reset --hard "$tools_revision"
    touch "$tools/.ohos-bootstrap-ready"
  fi
}
export PATH="$tools:$PATH"
export DEPOT_TOOLS_UPDATE=0
export DEPOT_TOOLS_METRICS=0

# 阶段1：从 154 播种（不含 out/ 与 .git），改 origin 为 chromium 官方镜像
if [[ ! -f "$root/.seed-complete" ]]; then
  echo "[1/7] 开始从 154 播种整棵树到 155（不含 out/.git，这步最费时，请耐心等待）"
  echo "      154 源大小 : $(du -sh "$seed_src" 2>/dev/null | cut -f1)  目标=$src"
  mkdir -p "$src"
  rsync -a --info=progress2 --exclude='/out/' --exclude='/.git/' "$seed_src/" "$src/"
  echo "      播种后 155 src 大小 : $(du -sh "$src" 2>/dev/null | cut -f1)"
  if [[ ! -d "$src/.git" ]]; then
    echo "      克隆 154 的 .git 作为 155 的 git 对象库（no-hardlinks）..."
    rm -rf "$root/git-seed"
    git clone --no-hardlinks --no-checkout "$seed_src" "$root/git-seed"
    mv "$root/git-seed/.git" "$src/.git"
    rmdir "$root/git-seed"
  fi
  cp "$seed_root/.gclient" "$root/.gclient"
  git -C "$src" remote set-url origin https://github.com/chromium/chromium.git
  touch "$root/.seed-complete"
  echo "[1/7] 播种完成（来自 154，不含 out/.git）"
fi

# 阶段2：把树钉到 155 pin 并同步 DEPS（耗时最长的一棒，可后台跑；但下载量不大：
#   154 树已整体播种到本地、--no-history --shallow 不拉历史、相邻版本 DEPS 极少变动，
#   实际新增下载通常个位数 GB，与 154 当初相近；真正吃盘的是后续 out/ 构建产物）
if [[ ! -f "$root/.deps-$revision" ]]; then
  python3 - "$src" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1]).resolve()
assert src.name == 'src', src
assert src.parent.name == 'chromium-155', src.parent
lock = src / '.git/index.lock'
if lock.exists():
    owners = []
    for proc in Path('/proc').iterdir():
        if not proc.name.isdigit():
            continue
        try:
            for fd in (proc / 'fd').iterdir():
                try:
                    if fd.resolve() == lock:
                        owners.append(proc.name)
                except OSError:
                    pass
        except OSError:
            pass
    if owners:
        raise RuntimeError(f'155 Git index lock is held by live processes: {owners}')
    lock.unlink()
    print('Removed abandoned 155 Git index lock')
PY
  if [[ "$(git -C "$src" rev-parse HEAD)" != "$revision" ]]; then
    git -C "$src" -c gc.auto=0 fetch --depth=1 origin "$revision"
    git -C "$src" reset --hard "$revision"
  fi
  prepare_tools
  sed -i 's#https://chromium.googlesource.com/chromium/src.git#https://github.com/chromium/chromium.git#' "$root/.gclient"

  # 清掉可能残留的 depot_tools 锁文件（上次中断会留下 *.locked，导致 gclient 报 LockError）
  clean_stale_locks() {
    local stale
    stale=$(find "$root/depot_tools" -name '*.locked' 2>/dev/null || true)
    if [[ -n "$stale" ]]; then
      echo "      ⚠ 发现残留锁文件，清理中："
      echo "$stale" | sed 's/^/        /'
      find "$root/depot_tools" -name '*.locked' -delete 2>/dev/null || true
    fi
  }

  echo "[2/7] 开始 gclient sync 到 155 pin（$revision），这一步也会持续若干分钟，日志会持续刷新..."
  max_sync_tries=3
  sync_ok=0
  for ((try=1; try<=max_sync_tries; try++)); do
    clean_stale_locks
    echo "     尝试 $try/$max_sync_tries ..."
    if (cd "$root" && gclient sync --nohooks --noprehooks --no-history --shallow --jobs=8 --reset --force -D --revision "src@$revision"); then
      sync_ok=1
      break
    fi
    echo "     gclient sync 第 $try 次失败，2 秒后清理锁文件重试..."
    sleep 2
  done
  if [[ "$sync_ok" -ne 1 ]]; then
    echo "❌ gclient sync 连续 $max_sync_tries 次失败，请检查网络/磁盘后手动运行：" >&2
    echo "     cd $root && gclient sync --nohooks --noprehooks --no-history --shallow --jobs=8 --reset --force -D --revision src@$revision" >&2
    exit 1
  fi
  touch "$root/.deps-$revision"
  echo "[2/7] 155 DEPS 同步完成 @ $revision"
fi

# 阶段3：恢复私有 SDK 链接（只读 154 的，不写穿）
mkdir -p "$src/ohos_sdk"
rsync -a "$seed_src/ohos_sdk/" "$src/ohos_sdk/"
echo "[3/7] 私有 SDK 链接已恢复"

# 阶段4：应用 155 迁移快照（上游 155 适配基线）
python3 "$repo_root/scripts/apply-155-snapshot.py" "$src" 2>&1 | tee "$repo_root/build-status/migration-155-local.log"
echo "[4/7] 155 适配快照已应用"

# 阶段5：覆盖 overlay + deps_code/webview（含我们的外壳/功能 native 修改）
rsync -a --checksum --no-times "$repo_root/overlay/" "$src/"
mkdir -p "$root/deps_code/webview"
rsync -a --checksum --no-times "$repo_root/external/deps_code/webview/" "$root/deps_code/webview/"
echo "[5/7] overlay + deps_code 已同步"

# 阶段6：工具链 hooks（拉 155 专属编译器/Rust/GN）
if [[ ! -f "$root/.hooks-$revision" ]]; then
  (cd "$root" && gclient runhooks)
  touch "$root/.hooks-$revision"
  echo "[6/7] 工具链 hooks 完成"
else
  echo "[6/7] 工具链 hooks 已就绪（跳过）"
fi

# 阶段7：生成 out/ohos_arm64/args.gn
mkdir -p "$src/out/ohos_arm64"
if [[ ! -f "$src/out/ohos_arm64/args.gn" ]]; then
  cp "$repo_root/config/args.plan_kirin_pc.gn" "$src/out/ohos_arm64/args.gn"
  echo "[7/7] args.gn 已生成"
else
  echo "[7/7] args.gn 已存在（保留）"
fi

echo
echo "✅ 155 源码树就绪：$src @ $revision"
echo "下一步：在 WSL 跑  bash $repo_root/scripts/apply-our-155-mods.sh"
