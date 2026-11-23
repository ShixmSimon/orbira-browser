#!/usr/bin/env bash
# 本地 WSL 用：搭建 /home/administrator/chromium-157/src（157 pin = 157.0.8103.77 / 7d4508cb）。
# 源自上游 scripts/prepare-chromium-157.sh + 155 的 prepare-local-155.sh，仅去掉 CI 守卫、改本地路径、
# 用 155 树作种子（而不是 154），并支持「部分拉取」（详见下方说明）。
#
# 关于「拉全树可以拉一部分，不需要完整内容」（用户要求）：
#   - gclient sync 已带 --no-history --shallow（不拉 git 历史，省大量磁盘）；
#   - 以已存在的 155 树（$seed_src）作种子，绝大多数 blob 已本地命中，157 相对 155 的新增下载很小；
#   - 若仍想进一步瘦身，可在 .gclient 里设 "custom_deps" 去掉不需要的子仓，或在 gclient sync 后
#     `git -C src remote set-url origin <blobless>`（git clone --filter=blob:none 风格）。
#   本脚本默认走「种子 + 浅同步」这条最稳最快的路。
set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 157 目标根目录：默认 /home/administrator/chromium-157（WSL 原生文件系统，比 9P 挂载快得多）
readonly root="${CHROMIUM_157_ROOT:-/home/administrator/chromium-157}"
export CHROMIUM_157_ROOT="${root}"
readonly src="${root}/src"

# 种子：默认用本机已有的 155 树（含 .git 与 .gclient）。只传 src 目录。
readonly seed_src="${CHROMIUM_155_SRC:-${CHROMIUM_155_ROOT:-/home/administrator/chromium-155}/src}"
readonly seed_root="$(dirname "$seed_src")"

# 157 pin（来自 patches/migration-157/manifest.json 的 target_revision）
readonly revision="${CHROMIUM_REVISION:-7d4508cbfffd289d7015f7703bce215d3ab123bf}"

# 代理：与 155 线完全一致——完全依赖环境里已有的配置（~/.bashrc 由 WorkBuddy 注入的
#   export http_proxy=http://127.0.0.1:7890 / https_proxy=...），gclient/git/uv/pip 均会读取，
# 无需脚本任何额外处理。早期版本曾在此写入 uv.toml/pip.conf 反而破坏 uv 解析，故此处不写。
# 仅清理「本脚本旧版本」可能留下的坏 uv.toml（若有），让 uv 回退到环境变量代理。
if [[ -f "$HOME/.config/uv/uv.toml" ]] && grep -q "由 prepare-local-157.sh 生成" "$HOME/.config/uv/uv.toml" 2>/dev/null; then
  rm -f "$HOME/.config/uv/uv.toml"
  echo "     已清理旧版脚本写入的坏 uv.toml（避免 uv 解析失败），代理改用环境 http_proxy"
fi

if [[ ! -d "$seed_src/.git" || ! -f "$seed_root/.gclient" ]]; then
  cat >&2 <<EOF
找不到 155 种子树：$seed_src
（需要该目录下有 .git，且其父目录有 .gclient）

请确认 155 的 Chromium 源码 checkout 在哪，然后用环境变量指过去，例如：
  CHROMIUM_155_SRC=/home/administrator/chromium-155/src \\
    bash /mnt/d/WorkBuddy/鸿蒙Chrome/chromium-hmos-157/scripts/prepare-local-157.sh

若不确定位置，可在 WSL 里执行：
  find /root /home /mnt -maxdepth 3 -name .gclient 2>/dev/null
EOF
  exit 1
fi

mkdir -p "$root" "$repo_root/build-status"
exec > >(tee -a "$repo_root/build-status/preparation-157-local.log") 2>&1

echo "=== prepare-local-157.sh 启动 @ $(date '+%Y-%m-%d %H:%M:%S') ==="
echo "    155 种子 : $seed_src"
echo "    157 目标: $src"
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

# 阶段1：从 155 种子播种（不含 out/ 与 .git），改 origin 为 chromium 官方 GitHub 镜像
if [[ ! -f "$root/.seed-complete" ]]; then
  echo "[1/8] 开始从 155 种子播种整棵树到 157（不含 out/.git）"
  echo "      155 源大小 : $(du -sh "$seed_src" 2>/dev/null | cut -f1)  目标=$src"
  mkdir -p "$src"
  rsync -a --info=progress2 --exclude='/out/' --exclude='/.git/' "$seed_src/" "$src/"
  echo "      播种后 157 src 大小 : $(du -sh "$src" 2>/dev/null | cut -f1)"
  if [[ ! -d "$src/.git" ]]; then
    echo "      克隆 155 的 .git 作为 157 的 git 对象库（no-hardlinks）..."
    rm -rf "$root/git-seed"
    git clone --no-hardlinks --no-checkout "$seed_src" "$root/git-seed"
    mv "$root/git-seed/.git" "$src/.git"
    rmdir "$root/git-seed"
  fi
  cp "$seed_root/.gclient" "$root/.gclient"
  git -C "$src" remote set-url origin https://github.com/chromium/chromium.git
  touch "$root/.seed-complete"
  echo "[1/8] 播种完成（来自 155，不含 out/.git）"
fi

# 阶段2：把树钉到 157 pin 并同步 DEPS（--no-history --shallow = 部分拉取，省磁盘）
if [[ ! -f "$root/.deps-$revision" ]]; then
  # bootstrap depot_tools（gclient 依赖；上游 prepare-chromium-157.sh 在 sync 前做，155 线第 118 行同）
  prepare_tools
  clean_stale_locks() {
    local stale
    stale=$(find "$root/depot_tools" -name '*.locked' 2>/dev/null || true)
    if [[ -n "$stale" ]]; then
      echo "     发现残留锁文件，清理中："
      echo "$stale" | sed 's/^/        /'
      find "$root/depot_tools" -name '*.locked' -delete 2>/dev/null || true
    fi
  }
  # 预同步 src 主仓库到 157 pin（关键步骤，对齐 155 线第 114-117 行）。
  # 先用 --depth=1 把 src 切到目标版本，gclient sync 时主仓库已就位、只需同步小的 DEPS 子仓库，
  # 可把下载量从上十 GB 压回个位数 GB；漏掉这步会让 gclient 内部 fetch 拉超大 pack（易 early EOF、流量翻倍）。
  rm -f "$src/.git/index.lock" 2>/dev/null || true
  if [[ "$(git -C "$src" rev-parse HEAD 2>/dev/null)" != "$revision" ]]; then
    echo "     预同步 src: fetch --depth=1 origin $revision ..."
    git -C "$src" -c gc.auto=0 fetch --depth=1 origin "$revision"
    git -C "$src" reset --hard "$revision"
  fi

  # 把 .gclient 里的 chromium 官方源换成 github 镜像（与 155 线/上游一致，避免走 googlesource 被墙）
  sed -i 's#https://chromium.googlesource.com/chromium/src.git#https://github.com/chromium/chromium.git#' "$root/.gclient"
  echo "[2/8] 开始 gclient sync 到 157 pin（$revision）..."
  max_sync_tries=3
  sync_ok=0
  for ((try=1; try<=max_sync_tries; try++)); do
    clean_stale_locks
    echo "     尝试 $try/$max_sync_tries ..."
    if (cd "$root" && gclient sync --nohooks --noprehooks --no-history --shallow --jobs=8 --reset --force -D --revision "src@$revision"); then
      sync_ok=1
      break
    fi
    echo "     gclient sync 第 $try 次失败，2 秒后重试..."
    sleep 2
  done
  if [[ "$sync_ok" -ne 1 ]]; then
    echo "gclient sync 连续 $max_sync_tries 次失败，请检查网络/磁盘后手动运行：" >&2
    echo "     cd $root && gclient sync --nohooks --noprehooks --no-history --shallow --jobs=8 --reset --force -D --revision src@$revision" >&2
    exit 1
  fi
  touch "$root/.deps-$revision"
  echo "[2/8] 157 DEPS 同步完成 @ $revision"
fi

# 阶段3：恢复私有 SDK 链接（只读 155 的，不写穿）
mkdir -p "$src/ohos_sdk"
rsync -a "$seed_src/ohos_sdk/" "$src/ohos_sdk/"
echo "[3/8] 私有 SDK 链接已恢复"

# 阶段4：应用 157 迁移快照（migration-157 + 13 个 included_incremental_patches）
python3 "$repo_root/scripts/apply-157-snapshot.py" "$src"
echo "[4/8] 157 适配快照已应用"

# 阶段5：覆盖 overlay（含我们的 155→157 壳移植 + 引擎本土修改）
rsync -a --checksum --no-times "$repo_root/overlay/" "$src/"
mkdir -p "$root/deps_code/webview"
rsync -a --checksum --no-times "$repo_root/external/deps_code/webview/" "$root/deps_code/webview/"
echo "[5/8] overlay + deps_code 已同步（我们的 155 移植壳）"

# 阶段6：工具链 hooks（拉 157 专属编译器/Rust/GN）
if [[ ! -f "$root/.hooks-$revision" ]]; then
  (cd "$root" && gclient runhooks)
  touch "$root/.hooks-$revision"
  echo "[6/8] 工具链 hooks 完成"
else
  echo "[6/8] 工具链 hooks 已就绪（跳过）"
fi

# 阶段7：生成 out/plan_kirin_pc/args.gn（与 build-157-now.sh 的构建目录一致；157 移除了 enterprise_client_certificates 参数）
readonly out_dir="$src/out/plan_kirin_pc"
mkdir -p "$out_dir"
if [[ ! -f "$out_dir/args.gn" ]]; then
  cp "$repo_root/config/args.plan_kirin_pc.gn" "$out_dir/args.gn"
fi
# 157 已移除该构建参数，清理掉避免 gn 报错
python3 - "$out_dir/args.gn" <<'PY'
from pathlib import Path
import re
path = Path(sys.argv[1])
before = path.read_text()
after = re.sub(r'^\s*enterprise_client_certificates\s*=.*\n', '', before, flags=re.M)
if after != before:
    path.write_text(after)
PY
echo "[7/8] args.gn 已生成/修正"

# 阶段8：本地静态检查（native-checks-157.txt 若可用）
if [[ -f "$repo_root/config/native-checks-157.txt" ]]; then
  echo "[8/8] 已就绪；native-checks 清单见 config/native-checks-157.txt（编译期由 CI 校验）"
else
  echo "[8/8] 已就绪"
fi

echo
echo "157 源码树就绪：$src @ $revision"
echo "下一步：在 WSL 跑  bash $repo_root/scripts/apply-our-157-mods.sh"
