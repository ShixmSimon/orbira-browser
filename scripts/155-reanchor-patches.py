#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
155-reanchor-patches.py — 把 154 版「改谷歌原版文件」的 4 个 patch 重锚到 155 源码树。

原理（3-way merge，不依赖 154 .patch 的行号）：
  对每个被改的谷歌文件 F：
    base   = 154 源码树里的 F  (revision b510e9d7cd)
    ours   = base + 154 patch 应用后的 F
    theirs = 155 源码树里的 F  (revision f043649a0e)
  用 `git merge-file` 合并 (base->ours) 与 (base->theirs) → 155 版 F + 我们的改动
  再 `git diff` 生成 a/F b/F 形式的 155 patch（可直接 `git apply -p1`）。

为什么用 3-way 而不是 patch --fuzz：
  154→155 上游把谷歌文件改了不少，原 patch 的上下文/行号几乎必然错位。
  patch --fuzz 在 155 上常常整块失败；3-way merge 按内容相似度合并，
  只要 (154->155) 与 (154->我们) 改的不是同一行，就能自动合出结果。

依赖：git（含 merge-file）、patch。在 Git Bash / WSL 下运行。

用法：
  # 预览（无需源码树）：只打印每笔 job 会处理哪些文件、输出落点
  python3 155-reanchor-patches.py --mode list

  # 真正重锚（需已 gclient sync 两个源码树）
  python3 155-reanchor-patches.py \
      --src154 /root/chromium-154/src \
      --src155 /root/chromium-155/src

  # 指定本仓根（默认取脚本所在仓根）
  python3 155-reanchor-patches.py --src154 ... --src155 ... --repo /path/to/chromium-hmos-155

输出：
  patches/155-port/ohos-155-bottom-crop-painthold-a.patch   (render_widget_host_view_aura.cc 单 patch 含两处)
  patches/155-port/ohos-155-paint-hold-b.patch             (delegated_frame_host.cc)
  patches/155-port/ohos-155-extension-origin.patch         (cors_url_loader.cc + resource_request.cc)
  合并出现冲突的文件会写入 reanchor-conflicts/ 并标红，需人工修。
"""

import os
import sys
import shutil
import subprocess
import tempfile
import argparse

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 154 patch -> 155 patch 的映射。render_widget_host_view_aura.cc 被底部裁切
# 与 paint-hold A 两处改，按迁移清单 §2 第 6 条陷阱合并成一个 155 patch。
JOBS = [
    {
        "out": "patches/155-port/ohos-155-bottom-crop-painthold-a.patch",
        "srcs": ["patches/ohos-bottom-crop.patch", "patches/ohos-paint-hold-a.patch"],
        "note": "render_widget_host_view_aura.cc：底部裁切 + paint-hold A 合并为单 patch",
    },
    {
        "out": "patches/155-port/ohos-155-paint-hold-b.patch",
        "srcs": ["patches/ohos-paint-hold-b.patch"],
        "note": "delegated_frame_host.cc：逻辑照搬，只重锚点",
    },
    {
        "out": "patches/155-port/ohos-155-extension-origin.patch",
        "srcs": ["patches/ohos-extension-origin.patch"],
        "note": "cors_url_loader.cc + resource_request.cc 两文件（cors 那处才真正生效）",
    },
]


def run(cmd, cwd=None, check=True, capture=True):
    p = subprocess.run(cmd, cwd=cwd, capture_output=capture, text=True)
    if check and p.returncode != 0:
        sys.stderr.write("CMD FAILED: %s\n%s\n%s\n" % (" ".join(cmd), p.stdout, p.stderr))
        raise SystemExit(1)
    return p


def parse_targets(patch_path):
    """从 patch 里取出每个 diff --git 块的目标相对路径（a/X b/X 里的 X）。"""
    targets = []
    with open(patch_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith("diff --git "):
                # diff --git a/content/... b/content/...
                parts = line[len("diff --git "):].split()
                if len(parts) == 2:
                    a, b = parts[0][2:], parts[1][2:]  # strip a/ b/
                    targets.append(b if b else a)
    return targets


def build_ours(src154, patch_paths, work):
    """把若干 154 patch 应用到 154 base 的拷贝上，返回 {relpath: 内容}。"""
    targets = set()
    for pp in patch_paths:
        for t in parse_targets(pp):
            targets.add(t)

    for rel in targets:
        dst = os.path.join(work, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(os.path.join(src154, rel), dst)

    for pp in patch_paths:
        abspp = os.path.abspath(pp)
        # patch -p1 -d work：strip a/ 后落到 work/<rel>
        r = subprocess.run(
            ["patch", "-p1", "-d", work, "-i", abspp,
             "--no-backup-if-mismatch", "--fuzz=5"],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            sys.stderr.write("!! patch 应用失败（154 base 上）: %s\n%s\n%s\n"
                             % (pp, r.stdout, r.stderr))
            raise SystemExit(1)

    out = {}
    for rel in targets:
        with open(os.path.join(work, rel), "r", encoding="utf-8", errors="replace") as f:
            out[rel] = f.read()
    return out


def merge_one(ours_path, base_path, theirs_path, rel):
    """3-way merge。ours=154+改动, base=154, theirs=155。返回 (content, conflict)。"""
    r = subprocess.run(
        ["git", "merge-file", "-L", "154+ours", "-L", "154-base", "-L", "155-theirs",
         ours_path, base_path, theirs_path],
        capture_output=True, text=True,
    )
    with open(ours_path, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()
    conflict = (r.returncode != 0) or ("<<<<<<<" in content)
    return content, conflict


def write_patch(merged_map, src155, out_rel):
    """用临时 git 仓生成 a/rel b/rel 形式的 git patch。"""
    tmp = tempfile.mkdtemp(prefix="reanchor-")
    try:
        run(["git", "init", "-q", tmp])
        # 放 155 base 版本作为基线并提交
        for rel in merged_map:
            dst = os.path.join(tmp, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(os.path.join(src155, rel), dst)
        run(["git", "-C", tmp, "-c", "user.email=wb@local", "-c", "user.name=wb",
             "add", "-A"])
        run(["git", "-C", tmp, "-c", "user.email=wb@local", "-c", "user.name=wb",
             "commit", "-q", "-m", "155 base"])
        # 用合并结果覆盖
        for rel, content in merged_map.items():
            dst = os.path.join(tmp, rel)
            with open(dst, "w", encoding="utf-8", newline="\n") as f:
                f.write(content)
        run(["git", "-C", tmp, "-c", "user.email=wb@local", "-c", "user.name=wb",
             "add", "-A"])
        r = run(["git", "-C", tmp, "diff", "--cached", "--no-color"], capture=True)
        os.makedirs(os.path.dirname(os.path.join(REPO, out_rel)), exist_ok=True)
        with open(os.path.join(REPO, out_rel), "w", encoding="utf-8", newline="\n") as f:
            f.write(r.stdout)
        return r.stdout
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def validate(out_rel, src155):
    """双向校验：正向能 apply、反向能 reverse-check（树现状与 patch 逐字节一致）。"""
    p = os.path.join(REPO, out_rel)
    fwd = subprocess.run(["git", "-C", src155, "apply", "--check", p],
                         capture_output=True, text=True)
    rev = subprocess.run(["git", "-C", src155, "apply", "--reverse", "--check", p],
                         capture_output=True, text=True)
    return (fwd.returncode == 0, rev.returncode == 0, fwd.stderr, rev.stderr)


def main():
    global REPO
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["list", "run"], default="run")
    ap.add_argument("--src154", default="/root/chromium-154/src")
    ap.add_argument("--src155", default="/root/chromium-155/src")
    ap.add_argument("--repo", default=REPO)
    args = ap.parse_args()

    REPO = os.path.abspath(args.repo)

    if args.mode == "list":
        print("== 重锚计划（不接触源码树）==")
        for j in JOBS:
            tgts = []
            for s in j["srcs"]:
                tgts += parse_targets(os.path.join(REPO, s))
            print("\n[%s]" % j["out"])
            print("  srcs: %s" % ", ".join(j["srcs"]))
            uniq = sorted(set(tgts))
            print("  targets(%d unique): %s" % (len(uniq), ", ".join(uniq)))
            print("  note: %s" % j["note"])
        return

    for d in (args.src154, args.src155):
        if not os.path.isdir(d):
            sys.stderr.write("源码树不存在: %s\n" % d)
            raise SystemExit(1)

    conflict_dir = os.path.join(REPO, "reanchor-conflicts")
    os.makedirs(conflict_dir, exist_ok=True)

    print("== 重锚 4 个 patch (154=%s -> 155=%s) ==" % (args.src154, args.src155))
    any_conflict = False
    for j in JOBS:
        srcs_abs = [os.path.join(REPO, s) for s in j["srcs"]]
        print("\n>> %s" % j["out"])
        work = tempfile.mkdtemp(prefix="ours-")
        try:
            ours = build_ours(args.src154, srcs_abs, work)
            merged = {}
            for rel, content in ours.items():
                ours_path = os.path.join(work, rel)
                base_path = os.path.join(args.src154, rel)
                theirs_path = os.path.join(args.src155, rel)
                mcontent, conflict = merge_one(ours_path, base_path, theirs_path, rel)
                merged[rel] = mcontent
                if conflict:
                    any_conflict = True
                    with open(os.path.join(conflict_dir, rel.replace("/", "__")),
                              "w", encoding="utf-8", newline="\n") as f:
                        f.write(mcontent)
                    print("   [CONFLICT] %s -> 见 reanchor-conflicts/" % rel)
                else:
                    print("   [merged]   %s" % rel)
            patch_txt = write_patch(merged, args.src155, j["out"])
            fwd, rev, ferr, rerr = validate(j["out"], args.src155)
            if fwd and rev:
                print("   [VERIFIED] 正向+反向校验均通过 (%d bytes)" % len(patch_txt))
            else:
                any_conflict = True
                print("   [CHECK FAIL] fwd=%s rev=%s" % (fwd, rev))
                if not fwd:
                    print("     fwd-err: %s" % ferr.strip()[:300])
                if not rev:
                    print("     rev-err: %s" % rerr.strip()[:300])
        finally:
            shutil.rmtree(work, ignore_errors=True)

    print("\n== 完成 ==")
    if any_conflict:
        print("⚠ 存在冲突或校验失败，见上方 [CONFLICT]/[CHECK FAIL] 与 reanchor-conflicts/")
        print("   手动修好后重新运行本脚本即可覆盖输出。")
        raise SystemExit(2)
    else:
        print("✅ 全部干净合并并校验通过。输出在 patches/155-port/ohos-155-*.patch")


if __name__ == "__main__":
    main()
