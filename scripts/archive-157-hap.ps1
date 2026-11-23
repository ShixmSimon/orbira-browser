# Archive a freshly built unsigned HAP into the repository's artifacts dir.
# Called by package-157-hap.cmd. All text is ASCII on purpose.
#
# Naming follows the 2026-11-13 verification packages:
#   debug   -> orbira-<version>-157-debug-unsigned.hap
#   release -> orbira-<version>-157-unsigned.hap
#
# Guards against archiving a stale HAP (the 2026-11-13 package still sits in
# this project's output directory): the HAP must be newer than -Since, which
# the caller records at startup. Also writes/updates SHA256SUMS.

param(
  [Parameter(Mandatory=$true)][string]$Hap,
  [Parameter(Mandatory=$true)][string]$ArtifactDir,
  [Parameter(Mandatory=$true)][ValidateSet('debug','release')][string]$Mode,
  [Parameter(Mandatory=$true)][string]$AppJson,
  [Parameter(Mandatory=$true)][string]$Since
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Hap)) {
  Write-Error "unsigned HAP not found: $Hap"
  exit 1
}

# Reject a stale package left over from an older build.
# Compare as sortable strings (yyyyMMdd-HHmmss) to avoid locale-dependent
# DateTime parsing on Chinese Windows installations.
$item = Get-Item -LiteralPath $Hap
$since = $Since.Trim()
$built = $item.LastWriteTime.ToString('yyyyMMdd-HHmmss')
if ([string]::CompareOrdinal($built, $since) -lt 0) {
  Write-Error ("HAP is older than this run (built {0}, run started {1}); refusing to archive a stale package" -f $built, $since)
  exit 1
}

$appText = [IO.File]::ReadAllText($AppJson)
$m = [regex]::Match($appText, '"versionName"\s*:\s*"([^"]+)"')
if (-not $m.Success) {
  Write-Error "versionName not found in $AppJson"
  exit 1
}
$version = $m.Groups[1].Value

$suffix = if ($Mode -eq 'debug') { '157-debug' } else { '157' }
$name = "orbira-$version-$suffix-unsigned.hap"

if (-not (Test-Path -LiteralPath $ArtifactDir)) {
  New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null
}
$dest = Join-Path $ArtifactDir $name
Copy-Item -LiteralPath $Hap -Destination $dest -Force

$hash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLower()
$sums = Join-Path $ArtifactDir 'SHA256SUMS'
$lines = @()
if (Test-Path -LiteralPath $sums) {
  $lines = @(Get-Content -LiteralPath $sums | Where-Object { $_ -and ($_ -notmatch [regex]::Escape($name)) })
}
$lines += "$hash  $name"
[IO.File]::WriteAllLines($sums, $lines, (New-Object Text.UTF8Encoding($false)))

Write-Host "[archive] $dest"
Write-Host "[archive] $($item.Length) bytes  sha256=$hash"
Write-Host "[archive] SHA256SUMS updated ($($lines.Count) entries)"
exit 0
