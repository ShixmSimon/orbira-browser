#!/usr/bin/env bash
# ============================================================================
#  解 merge-3-special-files.sh 留下的 2 个 diff3 冲突（aura_shell_runtime_bridge.h/.cc）。
#
#  冲突标记的真实角色（脚本里 -L 标签是反的，这里纠正）：
#    <<<<<<< 155-upstream  = 上游 155 版（$tmp/theirs）
#    ||||||| 154-upstream  = base = 上游 154 版
#    >>>>>>> our-154       = 我们的 154 版（$tmp/ours = $SRC154）
#
#  冲突本质：上游 155 把 InheritAuraShellUserAgent 删了（重构），而我们的 154 版
#  仍保留该函数（含 SetAuraShellUserAgentPinned 的 UA-pin 调用）。我们要的是
#  「155 结构 + 保留我们的 InheritAuraShellUserAgent」= 取 our-154 侧（文件中 == base，
#  即同时含 IsAuraShellRequestingDesktopSite 与 InheritAuraShellUserAgent 那版）。
#
#  解法：diff3 冲突块里，优先取 our-154（第三栏）；若为空则回退 base（第二栏）。
#  两种取法在本场景等价（都是「含 InheritAuraShellUserAgent 的版本」），且不会丢失
#  155 对 IsAuraShellRequestingDesktopSite 的改动（155 与 base 该函数体完全一致）。
# ============================================================================
set -euo pipefail

SRC155="${SRC155:-/home/administrator/chromium-155/src}"
REL="chrome/browser/ui/ohos"
H="$SRC155/$REL/aura_shell_runtime_bridge.h"
CC="$SRC155/$REL/aura_shell_runtime_bridge.cc"

python3 - "$H" "$CC" <<'PY'
import re, sys

def resolve(path):
    with open(path, encoding='utf-8') as f:
        s = f.read()
    pat = re.compile(
        r'<<<<<<< [^\n]*\n(.*?)\n'
        r'\|\|\|\|\|\|\| [^\n]*\n(.*?)\n'
        r'=======\n(.*?)\n'
        r'>>>>>>> [^\n]*\n',
        re.DOTALL)
    def repl(m):
        a, base, b = m.group(1), m.group(2), m.group(3)
        # 优先 our-154（b）；为空则回退 base
        chosen = b if b.strip() else base
        return chosen + '\n'
    new, n = pat.subn(repl, s)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(new)
    print(f"  {path.split('/')[-1]}: 解 {n} 处冲突")

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
echo "=== 防重复定义：155 树里 InheritAuraShellUserAgent 是否只在 bridge.cc 定义 ==="
grep -rn "void InheritAuraShellUserAgent\|InheritAuraShellUserAgent(" "$SRC155/chrome" 2>/dev/null \
  | grep -v "aura_shell_runtime_bridge.cc" \
  && echo "  ⚠ 155 树里另有引用/定义，需人工确认是否重复" \
  || echo "  ✅ 仅在 bridge.cc 出现，无重复定义风险"

echo
echo "下一步：git -C \"$SRC155\" status 看改动；再全量编 155 引擎。"
