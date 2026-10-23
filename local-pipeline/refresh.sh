#!/usr/bin/env bash
# refresh.sh — 从仓外原件刷新 local-pipeline/ 里的保险副本。
#
# 规则：管线脚本的原件优先（工作区根目录 / D:/hmos-build）；本目录只是 git
# 跟踪的保险。改完原件后跑一次本脚本，再 git commit，副本才算跟上。
#
# 用法（Git Bash 或 WSL）：
#   bash local-pipeline/refresh.sh
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS="/d/WorkBuddy/鸿蒙Chrome"
BUILD="/d/hmos-build"

# 原件在工作区根目录的
WS_FILES="
wb-wsl-stage3d-patches.sh
wb-wsl-stage3c-build.sh
wb-wsl-stage3e-resources.sh
wb-wsl-sync-fixes.sh
wb-wsl-save-local-patches.sh
Vulkan开关-一键构建.cmd
vulkan-toggle-build.ps1
sync-154.cmd
"
# 原件在 D:/hmos-build 的
BUILD_FILES="
apply-engine-patches.py
打补丁-引擎.cmd
"

echo "== refresh local-pipeline copies =="
echo "   workspace originals : $WS"
echo "   build-tree originals: $BUILD"
echo

miss=0
for f in $WS_FILES; do
  if [ -f "$WS/$f" ]; then
    cp -f "$WS/$f" "$REPO/local-pipeline/$f" && echo "  [OK]   $f"
  else
    echo "  [MISS] $WS/$f (原件不在，保留旧副本)"; miss=$((miss+1))
  fi
done
for f in $BUILD_FILES; do
  if [ -f "$BUILD/$f" ]; then
    cp -f "$BUILD/$f" "$REPO/local-pipeline/$f" && echo "  [OK]   $f"
  else
    echo "  [MISS] $BUILD/$f (原件不在，保留旧副本)"; miss=$((miss+1))
  fi
done

echo
echo "== git status of local-pipeline/ (非空 = 有变化待 commit) =="
git -C "$REPO" status --porcelain local-pipeline/
git -C "$REPO" diff --stat local-pipeline/
echo
if [ "$miss" != "0" ]; then
  echo "注意：$miss 个原件缺失。若是换机/迁移导致，按 README.md 的路径表核对。"
fi
echo "done."
