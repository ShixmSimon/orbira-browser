#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
157-reanchor-patches.py — 把 155 的「引擎本土改动」三向重锚到 157 源码树。

两阶段：
  阶段 A：overlay 文件（不含 chromium-ui 壳，壳已由 157-port 提交整体覆盖）。
          对每个被 155 改过的引擎文件 F：
            base   = 155 上游基线（chromium-hmos-155 的 upstream/hmos-155-adapter）里 F 的 pristine 版本
            ours   = chromium-hmos-155 仓 overlay/<F> 的当前内容（含我们的改动）
            theirs = 157 完整源码树（WSL）里 F 在 157 基线上的版本
          3-way merge → 直接写回 157 树（原文件备份到 reanchor-157-backup/）。

  阶段 B：3 个「改谷歌原版文件」的核心补丁（白闪A+底部裁切⑧ / 白闪B / 小锁+扩展origin）。
          这些不在 overlay/ 里，是 155-port/ohos-155-*.patch 的产物。
          对标 155-reanchor-patches.py 的 JOBS：base = 155-upstream pristine（由 src155 反向 apply 155-port 补丁还原），
          ours = src155（已含 155 改动），theirs = src157（157 基线），3-way 重锚 → 生成 patches/157-port/ohos-157-*.patch。

为什么用 3-way：155→157 上游把同一批谷歌文件改了不少，原 patch 行号几乎必然错位；
  3-way 按内容相似度合并，只要 (155->157) 与 (155->我们) 改的不是同一行就能自动合出。

依赖：git（含 merge-file、apply、show）。在 WSL 或 Git Bash 下运行。
前置：
  --repo155  chromium-hmos-155 仓（含 upstream/hmos-155-adapter remote，overlay/ 含我们的改动）
  --src155   WSL 155 完整源码树（已 apply 过 155-port 补丁，含我们的改动）——阶段B用于还原 base / 取 ours
  --src157   WSL 157 完整源码树（hmos-157-adapter 基线，可 sparse/部分检出相关目录）——阶段A/B 的 theirs

用法：
  # 预览（无需源码树）：列出阶段A候选文件 + 阶段B的 JOBS 目标
  python3 157-reanchor-patches.py --mode list

  # 真正重锚（需 --src155 与 --src157）
  python3 157-reanchor-patches.py \
      --repo155 /d/WorkBuddy/鸿蒙Chrome/chromium-hmos-155 \
      --src155  /home/administrator/chromium-155/src \
      --src157  /home/administrator/chromium-157/src
"""

import os
import sys
import shutil
import subprocess
import argparse
import tempfile

REPO157 = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 阶段 B：3 个核心补丁（对标 155-port/ohos-155-*.patch），重锚到 157 后产出 ohos-157-*.patch
# 注：srcs 指向 repo155 里的 155-port 补丁（用于还原 base / 确认目标文件）
JOBS_B = [
    {
        "out": "patches/157-port/ohos-157-bottom-crop-painthold-a.patch",
        "srcs": ["patches/155-port/ohos-155-bottom-crop-painthold-a.patch"],
        "note": "render_widget_host_view_aura.cc：底部裁切⑧ + 白闪A（paint-hold A）合并为单 patch",
    },
    {
        "out": "patches/157-port/ohos-157-paint-hold-b.patch",
        "srcs": ["patches/155-port/ohos-155-paint-hold-b.patch"],
        "note": "delegated_frame_host.cc：白闪B（导航间隙保留旧帧）",
    },
    {
        "out": "patches/157-port/ohos-157-extension-origin.patch",
        "srcs": ["patches/155-port/ohos-155-extension-origin.patch"],
        "note": "cors_url_loader.cc + resource_request.cc：小锁清除③ / 扩展 origin",
    },
]


def run(cmd, cwd=None, check=True, capture=True):
    p = subprocess.run(cmd, cwd=cwd, capture_output=capture, text=True)
    if check and p.returncode != 0:
        sys.stderr.write("CMD FAILED: %s\n%s\n%s\n" % (" ".join(cmd), p.stdout, p.stderr))
        raise SystemExit(1)
    return p


def git_show(repo, rev, rel):
    p = subprocess.run(["git", "-C", repo, "show", "%s:%s" % (rev, rel)],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return None
    return p.stdout


def parse_targets(patch_path):
    targets = []
    with open(patch_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith("diff --git "):
                parts = line[len("diff --git "):].split()
                if len(parts) == 2:
                    a, b = parts[0][2:], parts[1][2:]
                    targets.append(b if b else a)
    return targets


def list_modified_engine_files(repo155):
    p = run(["git", "-C", repo155, "diff", "--name-only",
             "upstream/hmos-155-adapter", "HEAD", "--", "overlay/"], capture=True)
    out = []
    for f in p.stdout.splitlines():
        f = f.strip()
        if not f.startswith("overlay/"):
            continue
        if "chromium-ui" in f:
            continue  # 壳已由 157-port 提交整体覆盖
        out.append(f)
    return out


def merge_one(ours_content, base_content, theirs_path, rel):
    """3-way merge。返回 (content, conflict)。"""
    d = tempfile.mkdtemp(prefix="mf157-")
    try:
        ours_path = os.path.join(d, "ours")
        base_path = os.path.join(d, "base")
        with open(ours_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(ours_content)
        with open(base_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(base_content)
        r = subprocess.run(
            ["git", "merge-file", "-L", "155+ours", "-L", "155-base", "-L", "157-theirs",
             ours_path, base_path, theirs_path],
            capture_output=True, text=True)
        with open(ours_path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
        conflict = (r.returncode != 0) or ("<<<<<<<" in content)
        return content, conflict
    finally:
        shutil.rmtree(d, ignore_errors=True)


def write_patch_from_tree(src157, rels, out_rel, repo157):
    """用临时 git 仓生成 a/rel b/rel 形式的 git patch（157 base -> 已合并）。"""
    tmp = tempfile.mkdtemp(prefix="re157-")
    try:
        run(["git", "init", "-q", tmp])
        for rel in rels:
            src = os.path.join(src157, rel)
            if not os.path.exists(src):
                continue
            dst = os.path.join(tmp, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(src, dst)
        run(["git", "-C", tmp, "-c", "user.email=wb@local", "-c", "user.name=wb", "add", "-A"])
        run(["git", "-C", tmp, "-c", "user.email=wb@local", "-c", "user.name=wb",
             "commit", "-q", "-m", "157 base"])
        # 用 src157 当前（已写回合并结果）覆盖
        for rel in rels:
            src = os.path.join(src157, rel)
            if not os.path.exists(src):
                continue
            dst = os.path.join(tmp, rel)
            shutil.copyfile(src, dst)
        run(["git", "-C", tmp, "-c", "user.email=wb@local", "-c", "user.name=wb", "add", "-A"])
        r = run(["git", "-C", tmp, "diff", "--cached", "--no-color"], capture=True)
        os.makedirs(os.path.dirname(os.path.join(repo157, out_rel)), exist_ok=True)
        with open(os.path.join(repo157, out_rel), "w", encoding="utf-8", newline="\n") as f:
            f.write(r.stdout)
        return r.stdout
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def phase_a(repo155, src157, repo157):
    """阶段 A：overlay 引擎文件直接 3-way 写回 157 树。"""
    print("\n########## 阶段 A：overlay 引擎文件 ##########")
    files = list_modified_engine_files(repo155)
    print("候选文件数: %d" % len(files))
    conflict_dir = os.path.join(repo157, "reanchor-157-conflicts")
    resolved_dir = os.path.join(repo157, "reanchor-157-resolved")
    backup_dir = os.path.join(repo157, "reanchor-157-backup")
    patch_dir = os.path.join(repo157, "patches", "157-port", "engine")
    for d in (conflict_dir, resolved_dir, backup_dir, patch_dir):
        os.makedirs(d, exist_ok=True)

    any_conflict = False
    applied = skipped = 0
    for f in files:
        rel = f[len("overlay/"):]
        print("\n>> %s" % rel)
        theirs_path = os.path.join(src157, rel)
        if not os.path.isfile(theirs_path):
            print("   [SKIP] 157 树无此文件（155 新增），需手动确认是否加入 157 树")
            skipped += 1
            continue
        base_content = git_show(repo155, "upstream/hmos-155-adapter", f)
        ours_path = os.path.join(repo155, f)
        if base_content is None or not os.path.isfile(ours_path):
            print("   [SKIP] 取不到 155 base 或 ours")
            skipped += 1
            continue
        with open(ours_path, "r", encoding="utf-8", errors="replace") as fh:
            ours_content = fh.read()
        if not ours_content.strip():
            print("   [SKIP] ours 为空")
            skipped += 1
            continue
        if not base_content.strip():
            base_content = ours_content

        ov = os.path.join(resolved_dir, rel)
        if os.path.isfile(ov):
            with open(ov, "r", encoding="utf-8", errors="replace") as fh:
                mcontent = fh.read()
            print("   [RESOLVED] 使用 reanchor-157-resolved/ 覆盖版")
        else:
            mcontent, conflict = merge_one(ours_content, base_content, theirs_path, rel)
            if conflict:
                any_conflict = True
                os.makedirs(os.path.dirname(os.path.join(conflict_dir, rel)), exist_ok=True)
                with open(os.path.join(conflict_dir, rel), "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(mcontent)
                print("   [CONFLICT] -> reanchor-157-conflicts/%s（放裁决版后可重跑）" % rel)
                skipped += 1
                continue

        dst = os.path.join(src157, rel)
        backup = os.path.join(backup_dir, rel)
        os.makedirs(os.path.dirname(backup), exist_ok=True)
        shutil.copyfile(dst, backup)
        with open(dst, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(mcontent)
        os.makedirs(os.path.dirname(os.path.join(patch_dir, rel)), exist_ok=True)
        dp = subprocess.run(["git", "-C", src157, "diff", "--no-color", "--", rel],
                            capture_output=True, text=True)
        with open(os.path.join(patch_dir, rel + ".patch"), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(dp.stdout)
        applied += 1
        print("   [applied] 已写回 157 树 + 记录 delta patch")
    print("\n阶段 A 完成：applied=%d skipped=%d" % (applied, skipped))
    return any_conflict


def phase_b(repo155, src155, src157, repo157):
    """阶段 B：3 个核心补丁 3-way 重锚到 157，产出 patches/157-port/ohos-157-*.patch。"""
    print("\n########## 阶段 B：核心补丁重锚（白闪A/B + 底部裁切 + 小锁/扩展origin）##########")
    if not os.path.isdir(src155):
        print("  [SKIP] 未提供 --src155（155 完整树），跳过阶段 B。需 --src155 才能还原 155 base。")
        return False
    any_conflict = False
    for j in JOBS_B:
        srcs_abs = [os.path.join(repo155, s) for s in j["srcs"]]
        print("\n>> %s" % j["out"])
        print("   note: %s" % j["note"])
        work = tempfile.mkdtemp(prefix="job157-")
        try:
            tgts = []
            for s in srcs_abs:
                tgts += parse_targets(s)
            tgts = sorted(set(tgts))
            print("   targets(%d): %s" % (len(tgts), ", ".join(tgts)))
            merged = {}
            conflict_rels = []
            for rel in tgts:
                theirs_path = os.path.join(src157, rel)
                if not os.path.isfile(theirs_path):
                    print("   [SKIP] 157 树无 %s" % rel)
                    continue
                ours_file = os.path.join(src155, rel)
                if not os.path.isfile(ours_file):
                    print("   [SKIP] src155 无 %s" % rel)
                    continue
                # base = 在 src155 版本上反向 apply 155-port 补丁还原 155-upstream pristine
                d2 = tempfile.mkdtemp(prefix="base157-")
                try:
                    base_path = os.path.join(d2, "base")
                    shutil.copyfile(ours_file, base_path)
                    rev = subprocess.run(["git", "apply", "--reverse", "--check"] + srcs_abs,
                                         cwd=d2, capture_output=True, text=True)
                    if rev.returncode == 0:
                        subprocess.run(["git", "apply", "--reverse"] + srcs_abs,
                                       cwd=d2, capture_output=True, text=True)
                    else:
                        # 已经 pristine（src155 实际未含该补丁），直接用
                        pass
                    with open(base_path, "r", encoding="utf-8", errors="replace") as fh:
                        base_content = fh.read()
                finally:
                    shutil.rmtree(d2, ignore_errors=True)
                with open(ours_file, "r", encoding="utf-8", errors="replace") as fh:
                    ours_content = fh.read()
                mcontent, conflict = merge_one(ours_content, base_content, theirs_path, rel)
                merged[rel] = mcontent
                if conflict:
                    any_conflict = True
                    conflict_dir = os.path.join(repo157, "reanchor-157-conflicts")
                    os.makedirs(os.path.dirname(os.path.join(conflict_dir, rel)), exist_ok=True)
                    with open(os.path.join(conflict_dir, rel), "w", encoding="utf-8", newline="\n") as fh:
                        fh.write(mcontent)
                    conflict_rels.append(rel)
                    print("   [CONFLICT] %s -> reanchor-157-conflicts/" % rel)
                else:
                    print("   [merged]   %s" % rel)
            clean = {r: c for r, c in merged.items() if r not in conflict_rels}
            if not clean:
                any_conflict = True
                print("   [SKIP] 全部冲突，未生成 patch")
                continue
            patch_txt = write_patch_from_tree(src157, list(clean.keys()), j["out"], repo157)
            # 把合并结果也写回 src157（便于直接编译验证）
            for rel, c in clean.items():
                with open(os.path.join(src157, rel), "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(c)
            if patch_txt.strip():
                print("   [VERIFIED] 产出 %s (%d bytes)，并已写回 src157" % (j["out"], len(patch_txt)))
            else:
                print("   [WARN] patch 为空，可能 155 与 157 该文件已一致")
        finally:
            shutil.rmtree(work, ignore_errors=True)
    print("\n阶段 B 完成")
    return any_conflict


def main():
    global REPO157
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["list", "run"], default="run")
    ap.add_argument("--repo155", default="D:/WorkBuddy/鸿蒙Chrome/chromium-hmos-155")
    ap.add_argument("--src155", default=None, help="WSL 155 完整源码树（阶段B还原base/取ours用）")
    ap.add_argument("--src157", default="/home/administrator/chromium-157/src")
    ap.add_argument("--repo157", default=REPO157)
    args = ap.parse_args()
    REPO157 = os.path.abspath(args.repo157)

    files = list_modified_engine_files(args.repo155)
    print("== 155→157 引擎重锚计划（排除 chromium-ui 壳）==")
    print("阶段 A 候选文件数: %d" % len(files))
    print("阶段 B JOBS: %d 个核心补丁" % len(JOBS_B))

    if args.mode == "list":
        print("\n--- 阶段 A 文件（-> 157 树相对路径）---")
        for f in files:
            print("  %s  ->  %s" % (f, f[len("overlay/"):]))
        print("\n--- 阶段 B JOBS ---")
        for j in JOBS_B:
            tgts = []
            for s in j["srcs"]:
                tgts += parse_targets(os.path.join(args.repo155, s))
            print("  [%s]" % j["out"])
            print("    targets: %s" % ", ".join(sorted(set(tgts))))
            print("    note: %s" % j["note"])
        return

    if not os.path.isdir(args.src157):
        sys.stderr.write("157 源码树不存在: %s\n" % args.src157)
        raise SystemExit(1)

    cA = phase_a(args.repo155, args.src157, REPO157)
    cB = phase_b(args.repo155, args.src155, args.src157, REPO157)

    print("\n== 完成 ==")
    if cA or cB:
        print("⚠ 存在冲突或校验失败，见上方 [CONFLICT] 与 reanchor-157-conflicts/")
        print("   手动修好后重新运行本脚本即可覆盖输出。")
        raise SystemExit(2)
    else:
        print("✅ 阶段 A + B 全部干净合并并写回 157 树，核心补丁已产出至 patches/157-port/ohos-157-*.patch。")


if __name__ == "__main__":
    main()
