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
$new  = [regex]::Replace(
  $text,
  '("bundleName"\s*:\s*")[^"]+(")',
  ('${1}' + $BundleName + '${2}')
)
if ($new -eq $text) {
  Write-Error 'bundleName not found in app.json5'
  exit 1
}

[IO.File]::WriteAllText($AppJson, $new, $utf8)
$got = [regex]::Match($new, '"bundleName"\s*:\s*"([^"]+)"').Groups[1].Value
Write-Host "[ok] bundleName -> $got"
exit 0
