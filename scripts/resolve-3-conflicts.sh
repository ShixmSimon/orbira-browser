#!/usr/bin/env bash
# ============================================================================
#  解 merge-3-special-files.sh 留下的 diff3 冲突（aura_shell_runtime_bridge.h/.cc）。
#
#  冲突标记的真实角色（git merge-file 的实参顺序：$tmp/theirs $tmp/base $tmp/ours）：
#    <<<<<<< 155-upstream  = 上游 155 版（$tmp/theirs）
#    ||||||| 154-upstream  = base = 上游 154 版
#    >>>>>>> our-154       = 我们的 154 版（$tmp/ours = $SRC154）
#
#  冲突本质：上游 155 把 InheritAuraShellUserAgent（含 SetAuraShellUserAgentPinned
#  的 UA-pin 调用）删了；我们的 154 版保留它。而 155 与 base 的
#  IsAuraShellRequestingDesktopSite 函数体逐字节一致。
#
#  解法：diff3 块里，优先取 our-154（第三栏，即 $SRC154）；若为空则回退 base（第二栏）。
#  两栏在本场景等价（都"含 InheritAuraShellUserAgent"），且不会丢失 155 对
#  IsAuraShellRequestingDesktopSite 的改动。采用行级解析，正确处理 ours 为空的情况。
# ============================================================================
set -euo pipefail

SRC155="${SRC155:-$HOME/chromium-155/src}"
REL="chrome/browser/ui/ohos"
H="$SRC155/$REL/aura_shell_runtime_bridge.h"
CC="$SRC155/$REL/aura_shell_runtime_bridge.cc"

python3 - "$H" "$CC" <<'PY'
import sys

def resolve(path):
    with open(path, encoding='utf-8') as f:
        lines = f.readlines()
    out = []
    i = 0
    n = len(lines)
    conflicts = 0
    while i < n:
        line = lines[i]
        if line.startswith('<<<<<<< '):
            sect_a, sect_b, sect_c = [], [], []
            cur = 'a'
            j = i + 1
            end = i
            while j < n:
                lj = lines[j]
                if lj.startswith('||||||| '):
                    cur = 'b'; j += 1; continue
                if lj.rstrip('\n') == '=======':
                    cur = 'c'; j += 1; continue
                if lj.startswith('>>>>>>> '):
                    end = j; break
                if cur == 'a': sect_a.append(lj)
                elif cur == 'b': sect_b.append(lj)
                else: sect_c.append(lj)
                j += 1
            conflicts += 1
            # 优先 our-154（c）；为空则回退 base（b，含 InheritAuraShellUserAgent）
            chosen = sect_c if ''.join(sect_c).strip() else sect_b
            out.extend(chosen)
            i = end + 1
        else:
            out.append(line)
            i += 1
    with open(path, 'w', encoding='utf-8') as f:
        f.writelines(out)
    print(f"  {path.split('/')[-1]}: 解 {conflicts} 处冲突")

for p in sys.argv[1:]:
    resolve(p)
PY

echo
echo "=== 校验 ==="
for f in "$H" "$CC"; do
  n=$(grep -c '^<<<<<<< ' "$f" 2>/dev/null || true)
  echo "  残留冲突标记 $f : ${n:-0}"
done
echo
echo "=== 关键符号是否还在 aura_shell_runtime_bridge.cc ==="
grep -nE 'PinnedUserAgent|SetAuraShellUserAgentPinned|IsAuraShellUserAgentPinned|ApplyUserAgentToAllTabs|UpdateBrowserStateOnUiThread|InheritAuraShellUserAgent' "$CC" \
  && echo "  ✅ 关键符号齐全" || echo "  ⚠ 缺少关键符号，需检查"

echo
echo "=== 防重复定义：155 树里 InheritAuraShellUserAgent 是否只在 bridge.cc 有 *定义* ==="
# .h:282 只是声明（void ...;），不算重复定义；只在其它 .cc 里出现定义才算冲突。
grep -rn "InheritAuraShellUserAgent" "$SRC155/chrome" --include=*.cc 2>/dev/null \
  | grep -v "aura_shell_runtime_bridge.cc" \
  && echo "  ⚠ 155 树里另有 .cc 定义，需人工确认是否重复" \
  || echo "  ✅ 仅在 bridge.cc 有定义，无重复定义风险（.h 的声明属正常）"

echo
echo "下一步：git -C \"$SRC155\" status 看改动；再全量编 155 引擎。"
