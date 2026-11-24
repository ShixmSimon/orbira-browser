# Set the bundleName in a HarmonyOS app.json5 for one HAP build.
# Called by package-157-hap.cmd. All text is ASCII on purpose.
#
# Args: -AppJson <path> -BundleName <name>
# Writes UTF-8 without BOM and preserves the original line endings.
# Exits 1 if bundleName was not found or the file could not be written.

param(
  [Parameter(Mandatory=$true)][string]$AppJson,
  [Parameter(Mandatory=$true)][string]$BundleName
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $AppJson)) {
  Write-Error "app.json5 not found: $AppJson"
  exit 1
}
if ($BundleName -notmatch '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$') {
  Write-Error "invalid bundleName: $BundleName"
  exit 1
}

$utf8 = New-Object Text.UTF8Encoding($false)
$text = [IO.File]::ReadAllText($AppJson)
$current = [regex]::Match($text, '"bundleName"\s*:\s*"([^"]+)"').Groups[1].Value
if ($current -eq $BundleName) {
  # Already the requested name (e.g. a release build on a project that
  # already carries the release name). Nothing to change; succeed so the
  # caller can continue instead of aborting as if the field were missing.
  Write-Host "[ok] bundleName already $BundleName"
  exit 0
}
if ([string]::IsNullOrEmpty($current)) {
  Write-Error 'bundleName not found in app.json5'
  exit 1
}
$new  = [regex]::Replace(
  $text,
  '("bundleName"\s*:\s*")[^"]+(")',
  ('${1}' + $BundleName + '${2}')
)

[IO.File]::WriteAllText($AppJson, $new, $utf8)
$got = [regex]::Match($new, '"bundleName"\s*:\s*"([^"]+)"').Groups[1].Value
Write-Host "[ok] bundleName -> $got"
exit 0
