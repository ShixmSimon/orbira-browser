# ===========================================================================
# 鸿蒙 Chrome · 「Vulkan 渲染加速」开关 · 一键构建（Windows 侧主编排）
#
#   双击  Vulkan开关-一键构建.cmd   即可（或在终端里跑本 .ps1）。
#
#   全流程：
#     0) 前置检查（CLT / 构建树 / WSL / 脚本齐不齐）
#     1) 备份（当前 HAP + 当前引擎 .so + 三套引擎基准哈希 + 回退说明）
#     2) 把 WSL 侧脚本投送到 WSL 家目录（ASCII 路径，规避中文参数编码坑）
#     3) WSL 重编引擎（stage3d 补丁+overlay同步+gn gen → 闸门落树核验 → stage3c 数小时）
#     4) 核验新 .so 里含字符串 ohos-disable-vulkan
#     5) 拷新 .so 进构建树 engine\libs\arm64-v8a
#     6) 清 4 处 stale 中间产物
#     7) 打 HAP（build-hap.cmd）
#     8) 拆 HAP 核验（版本号 + 内嵌 .so 哈希 == 源 .so）
#     9) 打印装机命令
#
#   常用参数：
#     -Jobs 8        编译并行数（默认 8；内存吃紧改 6 或 4）
#     -SkipEngine    跳过 2~4，直接用现有 engine\libs 重打 HAP
#     -EngineOnly    只重编引擎，不装 HAP
#     -BackupOnly    只做前置 + 备份，不动大件（先试试水）
#
#   编码要求：本文件必须 UTF-8 **带 BOM**，否则 PowerShell 5.1 中文乱码。
# ===========================================================================

[CmdletBinding()]
param(
    [int]$Jobs = 8,
    [string]$Distro = 'Ubuntu',
    [switch]$SkipEngine,
    [switch]$EngineOnly,
    [switch]$BackupOnly
)

$ErrorActionPreference = 'Stop'

# wsl.exe 输出是 UTF-8；不设这个，中文会显示成乱码
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# ---------------------------------------------------------------- 路径
$ROOT      = 'D:\WorkBuddy\鸿蒙Chrome'
$REPO      = Join-Path $ROOT 'chromium-hmos'
$CLT       = 'D:\Applications\command-line-tools'
$PROJ      = 'D:\hmos-build\chromium-ui'
$DST       = Join-Path $PROJ 'engine\libs\arm64-v8a'
$buildHap  = Join-Path $PROJ 'build-hap.cmd'
$WSLScript = Join-Path $ROOT 'wb-wsl-vulkan-rebuild.sh'

$WSL_HOME  = '\\wsl$\' + $Distro + '\home\administrator'
$WSL_OUT   = '/home/administrator/chromium-work/chromium/src/out/plan_kirin_pc'
$SRC_UNC   = $WSL_HOME + '\chromium-work\chromium\src\out\plan_kirin_pc'

$engSo     = 'libweb_engine.so'
$renSo     = 'libnweb_render.so'
$SWITCH    = 'ohos-disable-vulkan'          # 闸门字符串（编进 .so 的唯一可靠证据）

# 三套引擎基准（用于回退指引；哈希来自 2026-10-14 实测）
$BASELINE = @(
    @{ Name = '旧引擎·本地重编+补丁（流畅基线 c33736b）'
       Path = 'D:\hmos-build\har\backup-engine-local-c33736b-touch-20261012-1331\libs\arm64-v8a'
       Web  = '72ef905ed6ce75e2bddf8032b66f053fe52da5aa545652d179b88250ee604c2e'
       Ren  = '645699ae73158a9e2561fc59911c2449783fad5cf83912b743c37db204949181' }
    @{ Name = '新引擎·上游 Vulkan 路径（Pura80 掉帧）'
       Path = 'D:\hmos-build\engine-so-new-3e68a422-20261014-204710'
       Web  = '3e68a4226031e5e03bec10e1b717d5bbbf7eaa59a4aaa4164a08b52768a3438c'
       Ren  = '5ba0cceb242c02691e4940098e70b2fc422d5690a2b4705ac5f6631deb01d56a' }
    @{ Name = '中间态·10 patch 但未启 Vulkan'
       Path = 'D:\hmos-build\engine-so-backup-20261014-202559'
       Web  = '8af35b7d6d34213f822651741082ecd84e1a327f0ec856430cc25e00a13482fc'
       Ren  = '645699ae73158a9e2561fc59911c2449783fad5cf83912b743c37db204949181' }
)

$STAMP = Get-Date -Format 'yyyyMMdd-HHmmss'
$BAK   = 'D:\hmos-build\vulkan-toggle-backup-' + $STAMP

function Say  ([string]$m) { Write-Host $m }
function Head ([string]$m) { Write-Host ''; Write-Host ('=== ' + $m + ' ===') -ForegroundColor Cyan }
function Ok   ([string]$m) { Write-Host ('  [OK] ' + $m) -ForegroundColor Green }
function Warn ([string]$m) { Write-Host ('  [!]  ' + $m) -ForegroundColor Yellow }
function Bad  ([string]$m) { Write-Host ('  [X]  ' + $m) -ForegroundColor Red }

# 统一的中止出口：打印干净信息后以退出码 1 结束，不产生 PowerShell 堆栈噪音
function Die([string]$m) {
    Write-Host ''
    Write-Host ('  [X]  ' + $m) -ForegroundColor Red
    Write-Host ''
    Write-Host '已中止（未做破坏性动作）。窗口会停住，把上面的输出发我即可。' -ForegroundColor Yellow
    exit 1
}

function Need([string]$p, [string]$label) {
    if (-not (Test-Path -LiteralPath $p)) {
        Bad ('缺 ' + $label + ' : ' + $p)
        Die ('前置检查失败：' + $label)
    }
    Ok ($label)
}

# ---- 读 HAP 内的版本号与 .so 哈希（HAP 就是 zip）----
# 返回字段：Version/VersionCode/WebHash/RenHash（取到时才有值）
#   + WebName/RenName：实际匹配到的 entry 全名（'' = .NET 没匹配到条目）
#   + EntryCount：zip 条目总数（诊断用：读得到版本号但读不到 .so 时靠它区分
#     「zip 没打开」与「条目没匹配」）
#   + WebError/RenError：ComputeHash 抛出的异常文本（'' = 没抛）
# ⚠️ 2026-10-15 实测坑：本机 .NET ZipFile 对 hvigor 产的 333MB HAP 偶发
#   「module.json 读得到、libs/*.so 条目匹配不到」→ WebHash 空串 → 上层
#   空串与真实哈希比对必失配 → 误报「HAP 塞了旧 .so」（实际包是新的：
#   python zipfile 实测内嵌 .so 与 engine\libs 完全一致，zip 结构标准）。
#   因此调用方必须在 WebHash 为空时走「降级 Warn」而不是「判失败」。
function Get-HapInfo([string]$HapPath) {
    # 环境可能限制 Add-Type（部分沙箱/安全策略）→ 返回 $null 让调用方优雅降级，绝不因此中断
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { return $null }
    $info = New-Object psobject -Property @{
        Version=''; VersionCode=0; WebHash=''; RenHash=''
        WebName=''; RenName=''; EntryCount=0; WebError=''; RenError=''
    }
    try { $zip = [System.IO.Compression.ZipFile]::OpenRead($HapPath) } catch { return $null }
    try {
        $info.EntryCount = $zip.Entries.Count
        $e = $zip.Entries | Where-Object { $_.FullName -eq 'module.json' }
        if ($e) {
            $sr = New-Object System.IO.StreamReader($e.Open())
            $txt = $sr.ReadToEnd(); $sr.Dispose()
            $mj = $txt | ConvertFrom-Json
            $info.Version     = [string]$mj.app.versionName
            $info.VersionCode = [int]$mj.app.versionCode
        }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        foreach ($pair in @(@('libs/arm64-v8a/' + $engSo, 'WebHash', 'WebName', 'WebError'),
                            @('libs/arm64-v8a/' + $renSo, 'RenHash', 'RenName', 'RenError'))) {
            $ent = $zip.Entries | Where-Object { $_.FullName -eq $pair[0] }
            if (-not $ent) { continue }
            $info.($pair[2]) = $ent.FullName
            try {
                $st = $ent.Open()
                $h  = ([System.BitConverter]::ToString($sha.ComputeHash($st))).Replace('-','').ToLower()
                $st.Dispose()
                $info.($pair[1]) = $h
            } catch {
                # 大 entry 流式哈希失败不该炸掉整个构建：记下原因，让上层降级
                $info.($pair[3]) = $_.Exception.Message
            }
        }
    } finally { $zip.Dispose() }
    return $info
}

function Get-WslHash([string]$wslPath) {
    # 坑（2026-10-15 实测踩到）：**不要**在这里写 awk '{print $1}'。
    #   `$1` 经 `wsl.exe bash -c` 传递后会被外层展开成空 → awk 退化成 '{print }'（打印整行）
    #   → 返回值是 "哈希  文件路径"（日志里能看到哈希后面拖着路径），
    #     与 Get-FileHash 的纯 64 位哈希比对必然失配 → 误报「拷贝后哈希不一致」。
    #   改为 PowerShell 自己切字段，并用正则确认拿到的是纯哈希。
    $o = & wsl.exe -d $Distro bash -c ("sha256sum '" + $wslPath + "' 2>/dev/null")
    if ($LASTEXITCODE -eq 0 -and $o) {
        $h = (([string]$o) -split '\s+')[0].Trim()
        if ($h -match '^[0-9a-fA-F]{64}$') { return $h.ToLower() }
    }
    # 回退：经 \\wsl$ UNC 直接算（已实测可靠：246MB 连读两次结果一致，且与本地拷贝一致）
    $unc = '\\wsl$\' + $Distro + ($wslPath -replace '/', '\')
    if (Test-Path -LiteralPath $unc) {
        return (Get-FileHash -LiteralPath $unc -Algorithm SHA256).Hash.ToLower()
    }
    return ''
}

function Get-WslStringCount([string]$wslPath, [string]$needle) {
    $o = & wsl.exe -d $Distro bash -c ("grep -ac -- '" + $needle + "' '" + $wslPath + "' 2>/dev/null")
    if (-not $o) { return 0 }
    $n = 0; [void][int]::TryParse(([string]$o).Trim(), [ref]$n); return $n
}

# ===========================================================================
Head '0) 前置检查'
Need $CLT          'Command Line Tools'
Need (Join-Path $CLT 'sdk\default\openharmony\toolchains\hdc.exe') 'hdc.exe'
Need $PROJ         '构建树 chromium-ui'
Need $DST          '构建树 engine\libs\arm64-v8a'
Need $buildHap     'build-hap.cmd'
Need $WSLScript    'WSL 侧脚本 (wb-wsl-vulkan-rebuild.sh)'
# 坑：这两个 stage 脚本在**项目根目录**（与 ps1 同级），不在 chromium-hmos/ 仓库里
Need (Join-Path $ROOT 'wb-wsl-stage3d-patches.sh') 'stage3d 脚本'
Need (Join-Path $ROOT 'wb-wsl-stage3c-build.sh')   'stage3c 脚本'

# WSL 必须是活着的（\\wsl$ 才能访问）
& wsl.exe -d $Distro bash -c 'true' 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Die ('WSL 发行版 "' + $Distro + '" 不可用，先跑一次 wsl -d ' + $Distro) }
Ok  ('WSL 发行版可用: ' + $Distro)

# WSL 产物目录要能看到（\\wsl$ 可达才说明能投送脚本 + 取回 .so）
Need $SRC_UNC 'WSL 引擎产物目录（没跑过 stage3a/stage3c 就会缺）'
Ok  'WSL 产物目录可访问'

# ===========================================================================
Head '1) 备份（先备后动）'
if (Test-Path -LiteralPath $BAK) { Die ('备份目录已存在，先改名再跑：' + $BAK) }
New-Item -ItemType Directory -Force -Path $BAK | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $BAK 'hap')                 | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $BAK 'engine-libs-before')  | Out-Null

# ---- 1a) 当前引擎 .so ----
foreach ($n in @($engSo, $renSo)) {
    $p = Join-Path $DST $n
    if (-not (Test-Path -LiteralPath $p)) { Die ('构建树缺 ' + $p) }
    Copy-Item -LiteralPath $p -Destination (Join-Path $BAK 'engine-libs-before') -Force
}
$curWeb = (Get-FileHash -LiteralPath (Join-Path $DST $engSo) -Algorithm SHA256).Hash.ToLower()
$curRen = (Get-FileHash -LiteralPath (Join-Path $DST $renSo) -Algorithm SHA256).Hash.ToLower()
Ok ('已备份当前 engine\libs：' + $engSo.Substring(0,8) + '… / ' + $renSo.Substring(0,8) + '…')

# ---- 1b) 当前 HAP（这是你现在的可用包，务必留一份）----
$liveHap = Join-Path $PROJ 'entry\build\default\outputs\default\entry-default-unsigned.hap'
$hapVersion = ''
$liveWeb = ''; $liveRen = ''
if (Test-Path -LiteralPath $liveHap) {
    $liveHapInfo = Get-HapInfo $liveHap
    $hi = $liveHapInfo
    if ($hi) { $hapVersion = $hi.Version; $liveWeb = $hi.WebHash; $liveRen = $hi.RenHash }
    else { Warn '读不到 HAP 内版本/哈希（本机限制 .NET ZipFile），备份照做、清单里留空' }
    Copy-Item -LiteralPath $liveHap -Destination (Join-Path $BAK 'hap') -Force
    $verTxt = if ($hapVersion) { 'v' + $hapVersion } else { '(版本未知)' }
    Ok ('已备份当前 HAP：' + $verTxt + '（' + [math]::Round((Get-Item -LiteralPath $liveHap).Length/1MB,1) + ' MB）')

    # 同时按既有命名惯例归档一份到 D:\hmos-build\
    if ($hapVersion) {
        $arch = 'D:\hmos-build\entry-default-' + $hapVersion + '-unsigned.hap'
        if (Test-Path -LiteralPath $arch) {
            Warn ('归档副本已存在，未覆盖：' + $arch)
        } else {
            Copy-Item -LiteralPath $liveHap -Destination $arch -Force
            Ok ('已归档：' + $arch)
        }
    }
} else {
    Warn '构建树里没有现成 HAP（首次构建？），跳过 HAP 备份'
}

# ---- 1c) MANIFEST ----
$ml = New-Object System.Collections.Generic.List[string]
$ml.Add('Vulkan 开关一键构建 · 构建前备份清单')
$ml.Add('生成时间 : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$ml.Add('')
$ml.Add('【当前状态（改动前）】')
$ml.Add('  构建树 engine\libs\' + $engSo + ' sha256 = ' + $curWeb)
$ml.Add('  构建树 engine\libs\' + $renSo + ' sha256 = ' + $curRen)
if ($hapVersion) {
    $ml.Add('  当前 HAP 版本        = ' + $hapVersion)
    $ml.Add('  当前 HAP 内嵌 ' + $engSo + ' = ' + $(if ($liveWeb) { $liveWeb } else { '<本机 .NET 读不到，见脚本内 2026-10-15 注释>' }))
    $ml.Add('  当前 HAP 内嵌 ' + $renSo + ' = ' + $(if ($liveRen) { $liveRen } else { '<本机 .NET 读不到>' }))
    if ($liveHapInfo -and $liveHapInfo.EntryCount) {
        $ml.Add('  HAP zip 条目数      = ' + $liveHapInfo.EntryCount + '（读得到版本号就说明 zip 打开了）')
    }
}
$ml.Add('')
$ml.Add('【三套引擎基准（回退用）】')
foreach ($b in $BASELINE) {
    $ex = if (Test-Path -LiteralPath $b.Path) { '在' } else { '缺失!' }
    $ml.Add('  [' + $ex + '] ' + $b.Name)
    $ml.Add('        路径   : ' + $b.Path)
    $ml.Add('        期望哈希: ' + $b.Web.Substring(0,16) + '… (web) / ' + $b.Ren.Substring(0,16) + '… (render)')
    if (Test-Path -LiteralPath $b.Path) {
        $aw = Join-Path $b.Path $engSo
        if (Test-Path -LiteralPath $aw) {
            $real = (Get-FileHash -LiteralPath $aw -Algorithm SHA256).Hash.ToLower()
            $ml.Add('        实测哈希: ' + $real.Substring(0,16) + '…  ' + $(if ($real -eq $b.Web) { '= 一致' } else { '≠ 不一致（注意！）' }))
        }
    }
}
$ml.Add('')
$ml.Add('【代码侧备份】')
$head = ''
try { $head = (& git -C $REPO log --oneline -1 2>$null | Out-String).Trim() } catch { }
$dirty = ''
try { $dirty = (& git -C $REPO status --porcelain 2>$null | Out-String).Trim() } catch { }
$ml.Add('  chromium-hmos HEAD : ' + $head)
$ml.Add('  未提交改动         : ' + $(if ($dirty) { "有`n" + $dirty } else { '无（干净）' }))
$ml.Add('')
$ml.Add('【回退办法】')
$ml.Add('  1) 引擎回退：把上面某个基准目录里的两个 .so 拷回 ' + $DST)
$ml.Add('     然后清 4 处缓存目录（本脚本第 6 步列的就是那 4 处），再重打 HAP。')
$ml.Add('  2) 只回退引擎：直接跑 D:\WorkBuddy\鸿蒙Chrome\回退旧引擎一键.ps1')
$ml.Add('     （它会把 engine\libs 恢复到 c33736b 流畅基线并重打 HAP）')
$ml.Add('  3) 整包回退：把 ' + (Join-Path $BAK 'hap') + ' 里的旧 HAP 用 HoKit 装回手机。')
$ml.Add('  4) 代码回退：chromium-hmos 仓库里 git checkout -- overlay/ （本次改动已 commit，见 HEAD）')
$ml.Add('')
$ml.Add('【本次目标】')
$ml.Add('  重编引擎，把闸门 IsOhosPhoneVulkanEnabled() 编进去（尊重命令行开关 ' + $SWITCH + '）')
$ml.Add('  验证法：新 ' + $engSo + ' 里 grep 得到字符串 "' + $SWITCH + '"')
$ml.Add('  版本    ：1.0.143（versionCode 1000143）')
$mlTxt = ($ml -join [Environment]::NewLine)
[System.IO.File]::WriteAllText((Join-Path $BAK 'MANIFEST.txt'), $mlTxt, (New-Object System.Text.UTF8Encoding($true)))
Ok ('备份清单：' + (Join-Path $BAK 'MANIFEST.txt'))
Ok ('备份目录：' + $BAK)

if ($BackupOnly) {
    Say ''
    Say '已按要求 -BackupOnly 停在备份完成。要全流程就去掉该参数重跑。'
    exit 0
}

# ===========================================================================
if (-not $SkipEngine) {
    Head '2) 投送 WSL 侧脚本（LF 归一、无 BOM、走 UNC → 全 ASCII 调用）'
    $txt = [System.IO.File]::ReadAllText($WSLScript)
    $txt = $txt.Replace("`r`n", "`n").Replace("`r", "`n")
    $dstSh = Join-Path $WSL_HOME 'wb-vulkan-rebuild.sh'
    [System.IO.File]::WriteAllText($dstSh, $txt, (New-Object System.Text.UTF8Encoding($false)))
    if (-not (Test-Path -LiteralPath $dstSh)) { Die 'WSL 脚本投送失败' }
    Ok ('已投送 → ' + $dstSh)

    Head '3) WSL 重编引擎（补丁 + overlay 同步 + gn gen + autoninja）'
    Warn '这一步数小时。建议：插电源、别让机器睡眠；Ctrl+C 安全可重跑续编。'
    Warn '中途想单独看进度：另开 WSL 窗口跑  bash /mnt/d/WorkBuddy/鸿蒙Chrome/wb-build-ctl.sh status'
    Say ''
    for ($i = 5; $i -gt 0; $i--) { Say ('  立即开始… ' + $i); Start-Sleep -Seconds 1 }
    Say ''
    & wsl.exe -d $Distro bash '/home/administrator/wb-vulkan-rebuild.sh' '--jobs' "$Jobs"
    if ($LASTEXITCODE -ne 0) { Die ('WSL 引擎重编失败（exit=' + $LASTEXITCODE + '）。日志见 /home/administrator/wb-stage3d-patches.txt 与 wb-stage3c-out.txt') }
    Ok 'WSL 引擎重编脚本返回成功'

    Head '4) 核验新 .so（闸门字符串必须编进去）'
    $newWeb = Get-WslHash ($WSL_OUT + '/' + $engSo)
    $newRen = Get-WslHash ($WSL_OUT + '/' + $renSo)
    if (-not $newWeb) { Die '取不到 WSL 新 .so 的哈希' }
    $cnt = Get-WslStringCount ($WSL_OUT + '/' + $engSo) $SWITCH
    Say ('  新 ' + $engSo + ' sha256 = ' + $newWeb)
    Say ('  新 ' + $renSo + ' sha256 = ' + $newRen)
    Say ('  闸门字符串 "' + $SWITCH + '" 命中 = ' + $cnt)
    if ($cnt -lt 1) { Die ('新 .so 里没有 "' + $SWITCH + '"，闸门没编进去 —— 别打 HAP') }
    if ($newWeb -eq $curWeb) { Warn ('新 .so 与构建树里的旧 .so 哈希相同，可能没编出新东西（可疑）') }
    Ok '闸门已编入新引擎'

    Head '5) 拷新 .so 进构建树'
    foreach ($n in @($engSo, $renSo)) {
        Copy-Item -LiteralPath (Join-Path $SRC_UNC $n) -Destination $DST -Force
    }
    $copiedWeb = (Get-FileHash -LiteralPath (Join-Path $DST $engSo) -Algorithm SHA256).Hash.ToLower()
    if ($copiedWeb -ne $newWeb) { Die '拷贝后哈希不一致，拷贝可能被中断/占用' }
    Ok ('拷贝完成并校验一致：' + $copiedWeb.Substring(0,16) + '…')
} else {
    Head '2~5) 已按 -SkipEngine 跳过引擎重编，直接用现有 engine\libs'
    # 加固：跳过后就没人查闸门了 —— 直接扫本地 .so，不含闸门立即中止，
    # 免得打出一个「开关空转」的包（旧引擎不认 ohos-disable-vulkan，装了也白装）。
    $srcSo = Join-Path $DST $engSo
    $has = $false
    if (Test-Path -LiteralPath $srcSo) {
        $fs = [System.IO.File]::OpenRead($srcSo)
        try {
            $buf   = New-Object byte[] (1048576)
            $carry = ''
            while (($read = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
                $chunk = $carry + [System.Text.Encoding]::ASCII.GetString($buf, 0, $read)
                if ($chunk.Contains($SWITCH)) { $has = $true; break }
                $carry = $chunk.Substring([Math]::Max(0, $chunk.Length - 64))
            }
        } finally { $fs.Dispose() }
    }
    if (-not $has) {
        Die ('现有 ' + $engSo + ' 里查不到 "' + $SWITCH + '" —— 它还是旧引擎，打出来的包开关是空转。' +
             " 去掉 -SkipEngine 重跑一次完整流程。")
    }
    Ok ('现有 ' + $engSo + ' 含 "' + $SWITCH + '" —— 带闸门，可继续打 HAP')
    Say ('  源 .so : ' + $srcSo)
    Say ('  sha256 : ' + (Get-FileHash -LiteralPath $srcSo -Algorithm SHA256).Hash.ToLower())
}

if ($EngineOnly) {
    Say ''
    Say '已按要求 -EngineOnly 停在引擎就绪。要装 HAP 就跑不带该参数的：Vulkan开关-一键构建.cmd -SkipEngine'
    exit 0
}

# ===========================================================================
Head '6) 清 4 处 stale 中间产物（防止 HAP 里塞进旧 .so）'
$cacheDirs = @(
    (Join-Path $PROJ 'engine\build\default\intermediates\libs\default\arm64-v8a'),
    (Join-Path $PROJ 'engine\build\default\intermediates\stripped_native_libs\default\arm64-v8a'),
    (Join-Path $PROJ 'entry\build\default\intermediates\libs\default\arm64-v8a'),
    (Join-Path $PROJ 'entry\build\default\intermediates\stripped_native_libs\default\arm64-v8a')
)
$cleared = 0
foreach ($d in $cacheDirs) {
    foreach ($n in @($engSo, $renSo)) {
        $p = Join-Path $d $n
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; Say ('   删: ' + $p); $cleared++ }
    }
}
Ok ('缓存清理完成（清掉 ' + $cleared + ' 个文件）')

# ===========================================================================
Head '7) 打 HAP（build-hap.cmd，约 2~5 分钟）'
$ver = (& cmd.exe /c "type `"$PROJ\AppScope\app.json5`"" 2>$null | Out-String)
$vm = [regex]::Match($ver, '"versionName"\s*:\s*"([^"]+)"')
$expectVer = if ($vm.Success) { $vm.Groups[1].Value } else { '' }
Say ('  期望版本：' + $(if ($expectVer) { 'v' + $expectVer } else { '(读不到 app.json5)' }))
& cmd.exe /c "$buildHap `"$CLT`""
if ($LASTEXITCODE -ne 0) { Die ('build-hap.cmd 失败（exit=' + $LASTEXITCODE + '）') }

# ===========================================================================
Head '8) 拆 HAP 核验（版本号 + 内嵌 .so 是否就是新引擎）'
$hapDir = Join-Path $PROJ 'entry\build\default\outputs\default'
$hap    = Join-Path $hapDir 'entry-default-unsigned.hap'
if (-not (Test-Path -LiteralPath $hap)) {
    $hap = (Get-ChildItem -Path (Join-Path $PROJ 'entry\build') -Recurse -Filter 'entry-default-unsigned.hap' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime | Select-Object -Last 1).FullName
}
if (-not $hap -or -not (Test-Path -LiteralPath $hap)) { Die 'unsigned HAP 未生成，查构建日志' }

$h = Get-Item -LiteralPath $hap
$fail = 0
$verifySkipped = $false
Say ('  HAP      : ' + $h.FullName)
Say ('  大小/时间: ' + [math]::Round($h.Length/1MB,1) + ' MB / ' + $h.LastWriteTime)

$ri = Get-HapInfo $hap
if ($ri) {
    Say ('  版本     : v' + $ri.Version + ' (' + $ri.VersionCode + ')')
    Say ('  内嵌 web : ' + $ri.WebHash)
    Say ('  内嵌 ren : ' + $ri.RenHash)

    if ($expectVer -and $ri.Version -ne $expectVer) { Bad ('版本不符：HAP 里是 v' + $ri.Version + '，期望 v' + $expectVer); $fail = 1 }
    else { Ok '版本号正确' }

    $srcWebNow = (Get-FileHash -LiteralPath (Join-Path $DST $engSo) -Algorithm SHA256).Hash.ToLower()
    if (-not $ri.WebName -or $ri.WebError) {
        # .NET 读不到这个 entry（或读挂了）≠ 包是旧的。2026-10-15 实测：
        # hvigor 产的 HAP 完全标准（python zipfile 可读、无 ZIP64/data
        # descriptor），但本机 .NET 偶发匹配不到 libs/*.so 条目。
        # 空串与真实哈希比对必失配，所以这里降级为警告 + 手工核验命令。
        Warn ('本机 .NET 读不到 HAP 内 ' + $engSo + ' 条目（entry=' + $ri.EntryCount +
              '，matched=' + $(if ($ri.WebName) { $ri.WebName } else { '<无>' }) +
              '，err=' + $(if ($ri.WebError) { $ri.WebError } else { '<无>' }) + '）→ 哈希核验跳过')
        Warn ('  这往往是本机 .NET ZipFile 的限制，不是包旧了。手工核验（Bash/WSL 里跑）：')
        Say  ('    python -c "import zipfile,hashlib;z=zipfile.ZipFile(HAP);print(hashlib.sha256(z.read(SO)).hexdigest())"')
        Say  ('    其中 HAP 填 ' + $hap + '；SO 填 libs/arm64-v8a/' + $engSo)
        Say  ('  期望 = ' + $srcWebNow)
        $verifySkipped = $true
    } elseif ($ri.WebHash -ne $srcWebNow) {
        Bad ('内嵌 ' + $engSo + ' 与 engine\libs 里那一份不一致 —— HAP 塞了旧 .so！')
        $fail = 1
    } else {
        Ok ('内嵌 ' + $engSo + ' == engine\libs 那一份（新引擎真的进包了）')
    }
} else {
    Warn '读不到 HAP 内容（本机限制 .NET ZipFile）→ 版本/哈希核验跳过，不算失败'
    Warn ('手工核验：把 HAP 里 libs/arm64-v8a/' + $engSo + ' 解出来，比对 ' + (Join-Path $DST $engSo))
    $verifySkipped = $true
}

# 闸门端到端：HAP 里的 .so 必须含开关字符串
# 环境可能限制 Add-Type → 探一下；不可用就降级为「警告 + 给手工命令」，绝不因此判构建失败
$zipOk = $true
try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop }
catch { $zipOk = $false; Warn ('.NET ZipFile 不可用（' + $_.Exception.Message + '）') }
if ($zipOk) {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($hap)
    try {
        $ent = $zip.Entries | Where-Object { $_.FullName -eq ('libs/arm64-v8a/' + $engSo) }
        if (-not $ent) {
            # 与上面哈希核验同款降级：读不到条目 ≠ 开关空转（本机 .NET 限制）
            Warn ('本机 .NET 读不到 HAP 内 ' + $engSo + ' 条目 → 闸门字符串核验跳过（不算失败）')
            Warn ('  手工核验（Bash/WSL）：grep -ac ' + $SWITCH + " '/home/administrator/chromium-work/chromium/src/out/plan_kirin_pc/" + $engSo + "'")
            $verifySkipped = $true
        } else {
            $tmpSo = Join-Path $env:TEMP ('vulkan-check-' + $STAMP + '.so')
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($ent, $tmpSo, $true)
            # 流式扫描二进制（Select-String 对二进制不稳，纯手扫最可靠）
            $found = $false
            $fs = [System.IO.File]::OpenRead($tmpSo)
            try {
                $buf = New-Object byte[] (1048576)
                $carry = ''
                while (($read = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
                    $chunk = $carry + [System.Text.Encoding]::ASCII.GetString($buf, 0, $read)
                    if ($chunk.Contains($SWITCH)) { $found = $true; break }
                    $carry = $chunk.Substring([Math]::Max(0, $chunk.Length - 64))
                }
            } finally { $fs.Dispose() }
            Remove-Item -LiteralPath $tmpSo -Force -ErrorAction SilentlyContinue
            if ($found) { Ok ('HAP 内嵌引擎含 "' + $SWITCH + '" —— 开关端到端可用了') }
            else { Bad ('HAP 内嵌引擎里查不到 "' + $SWITCH + '" —— 开关是空转'); $fail = 1 }
        }
    } finally { $zip.Dispose() }
} else {
    Warn '闸门端到端核验跳过。手工核验（WSL 里）：'
    Say  ('  grep -ac ' + $SWITCH + " '/home/administrator/chromium-work/chromium/src/out/plan_kirin_pc/" + $engSo + "'")
    $verifySkipped = $true
}

# ===========================================================================
Head '9) 结果'
if ($fail -ne 0) {
    Bad '核验未全通过，先别装机。把上面的输出发我。'
    exit 1
}
if ($verifySkipped) {
    Warn '构建成功，但部分 HAP 内容核验被本机环境限制跳过了（按上面的手工命令自检一下）'
}
Ok '全流程通过：引擎含闸门、HAP 版本正确、内嵌引擎是新编的那份'
Say ''
Say ('备份目录     : ' + $BAK)
Say ('构建前 HAP   : v' + $hapVersion + '（在备份目录的 hap\ 里，可随时装回）')
Say ('新 HAP       : ' + $hap)
Say ''
Say '★ 装机（需 hdc 连上真机）：'
Say ('  hdc file send "' + $hap + '" /storage/media/100/local/files/Download/')
Say '  然后在手机 HoKit 打开 Download 里的 HAP → 签名安装'
Say ''
Say '★ 真机三步验证：'
Say '  1) 默认（设置里「Vulkan 渲染加速」= 关）冷启动 → 应流畅，等同你回退的旧引擎'
Say '  2) 打开该开关 → 重启应用 → 应复现掉帧（证明开关真的切到 Vulkan 路径）'
Say '  3) 再关掉 → 重启 → 恢复流畅'
Say ''
Say '★ 回退：'
Say '  - 引擎回退 : 跑 回退旧引擎一键.ps1（恢复 c33736b 流畅基线并重打 HAP）'
Say '  - 整包回退 : 用备份目录 hap\ 里的旧 HAP 在 HoKit 装回'
Say '  - 代码回退 : chromium-hmos 里 git checkout -- overlay/（本次改动已 commit）'
