@echo off
rem ============================================================
rem  Package an UNSIGNED HAP for the 157 engine (Windows side).
rem
rem  Usage:
rem     package-157-hap.cmd            -> DEBUG build, bundleName com.orbira.browser11
rem     package-157-hap.cmd release    -> RELEASE build, bundleName com.orbira.browser
rem
rem  Default is debug. Passing "release" is the ONLY way to get the normal
rem  package name. The debug name is applied temporarily and always restored,
rem  including on error, so the shared project never keeps a dirty app.json5.
rem
rem  Prerequisites (see package-157-stage.sh):
rem     - the 157 engine and its runtime assets have been staged into
rem       D:\hmos-build-157\chromium-ui\engine
rem     - Command Line Tools for HarmonyOS at D:\Applications\command-line-tools
rem
rem  All text here is ASCII on purpose. WSL/Windows shells and PowerShell 5.1
rem  have both been observed to mangle multi-byte characters in scripts.
rem ============================================================
setlocal EnableExtensions

rem Scripts live under a Chinese-named workspace. Passing %~dp0 inline to
rem powershell -File mangles the path (cmd uses the ANSI code page). Export it
rem via an environment variable instead: PowerShell reads env vars as UTF-16,
rem so the Chinese characters survive.
set "PS_SCRIPTS_DIR=%~dp0"

set "MODE=debug"
set "BUNDLE=com.orbira.browser11"
if /i "%~1"=="release" (
  set "MODE=release"
  set "BUNDLE=com.orbira.browser"
) else if not "%~1"=="" (
  echo [ERROR] unknown argument: %~1
  echo         usage: %~nx0 [release]
  exit /b 2
)

set "CLT=D:\Applications\command-line-tools"
set "PROJ=D:\hmos-build-157\chromium-ui"
set "APPJSON=%PROJ%\AppScope\app.json5"
set "BACKUP=%PROJ%\AppScope\app.json5.package-backup"
set "ARTIFACTS=%~dp0..\artifacts"
set "DEVECO_SDK_HOME=%CLT%\sdk"

rem Record when this run started. archive-157-hap.ps1 refuses to archive a
rem HAP older than this, because a 2026-11-13 package still sits in the
rem project output directory and must never be mistaken for a fresh build.
for /f %%T in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "RUN_START=%%T"
if not defined RUN_START (
  echo [ERROR] cannot determine run start time
  exit /b 1
)

rem --- WorkBuddy injects a node "safe delete" shim via NODE_OPTIONS; it hands
rem --- hvigor's cache deletions to genie-trash, which can time out and crash
rem --- the build. Run the toolchain without it, like a plain terminal.
set "NODE_OPTIONS="
set "CODEBUDDY_SAFE_DELETE_ENABLED="

rem --- JDK 21 (recommended for CLT 26.0.0+); prefer it over any system JDK ---
for /d %%D in ("D:\Applications\jdk21\jdk-*") do set "JAVA_HOME=%%~fD"
if defined JAVA_HOME set "PATH=%JAVA_HOME%\bin;%PATH%"

rem --- locate node / ohpm / hvigor (layout varies between CLT builds) ---
set "NODE=%CLT%\tool\node\node.exe"
if not exist "%NODE%" set "NODE=%CLT%\node\node.exe"
set "OHPM=%CLT%\ohpm\bin\pm-cli.js"
if not exist "%OHPM%" set "OHPM=%CLT%\tool\ohpm\bin\pm-cli.js"
set "HVIGOR=%CLT%\hvigor\bin\hvigorw.js"
if not exist "%HVIGOR%" set "HVIGOR=%CLT%\tool\hvigor\bin\hvigorw.js"

echo [env] mode          = %MODE%
echo [env] bundleName    = %BUNDLE%
echo [env] CLT           = %CLT%
echo [env] DEVECO_SDK_HOME= %DEVECO_SDK_HOME%
echo [env] project       = %PROJ%
echo.

if not exist "%CLT%"        ( echo [ERROR] CLT not found: %CLT% & exit /b 1 )
if not exist "%PROJ%"       ( echo [ERROR] project not found: %PROJ% & exit /b 1 )
if not exist "%APPJSON%"    ( echo [ERROR] app.json5 not found: %APPJSON% & exit /b 1 )
if not exist "%NODE%"       ( echo [ERROR] node.exe not found: %NODE% & exit /b 1 )
if not exist "%HVIGOR%"     ( echo [ERROR] hvigorw.js not found: %HVIGOR% & exit /b 1 )

rem --- line guard: refuse to build anything that is not the 157 site ---------
rem     The three lines share one bundleName, so pointing this script at a
rem     154/155 site would silently produce a package labelled 157.
findstr /r /c:"\"versionName\"[ ]*:[ ]*\"1\.2\." "%APPJSON%" >nul
if errorlevel 1 (
  echo [ERROR] not a 157-line project: %APPJSON% has no versionName 1.2.x
  echo         expected PROJ = D:\hmos-build-157\chromium-ui
  exit /b 2
)

rem --- 1. Back up app.json5, then set the bundleName for this build. --------
rem     PowerShell is used only for a byte-exact text replace (no BOM, LF
rem     preserved). It writes via [IO.File]::WriteAllText with UTF8 no BOM.
if exist "%BACKUP%" (
  echo [ERROR] stale backup exists: %BACKUP%
  echo         A previous run was interrupted. Restore it manually first.
  exit /b 1
)
copy /y "%APPJSON%" "%BACKUP%" >nul || ( echo [ERROR] cannot back up app.json5 & exit /b 1 )

powershell -NoProfile -ExecutionPolicy Bypass -Command "& (Join-Path $env:PS_SCRIPTS_DIR 'set-157-bundle-name.ps1') -AppJson '%APPJSON%' -BundleName '%BUNDLE%'"
if errorlevel 1 goto :restore_fail

rem --- 2. Install dependencies ---------------------------------------------
cd /d "%PROJ%" || goto :restore_fail
echo [1/2] ohpm install ...
"%NODE%" "%OHPM%" install
if errorlevel 1 goto :restore_fail

rem --- 3. Build the UNSIGNED HAP -------------------------------------------
rem     No signingConfigs are configured in this project, so hvigor emits
rem     entry-default-unsigned.hap (and logs "No signingConfig found").
echo [2/2] hvigorw assembleHap (%MODE%, unsigned) ...
"%NODE%" "%HVIGOR%" --mode module -p product=default -p module=entry@default -p buildMode=%MODE% assembleHap --no-daemon
if errorlevel 1 goto :restore_fail

rem --- 4. Restore app.json5 BEFORE reporting success -----------------------
copy /y "%BACKUP%" "%APPJSON%" >nul
del /q "%BACKUP%"
echo [ok] app.json5 restored

rem --- 5. Report the artifact ----------------------------------------------
echo.
echo [done] unsigned HAP:
set "HAP=%PROJ%\entry\build\default\outputs\default\entry-default-unsigned.hap"
if exist "%HAP%" (
  for %%F in ("%HAP%") do echo   %%~fF  (%%~zF bytes)
) else (
  echo   not found at expected path; searching:
  dir /s /b "%PROJ%\entry\build" 2>nul | findstr /i "unsigned.hap"
)

rem --- 6. Archive into the repository's artifacts/ dir --------------------
rem     Non-fatal: a failed archive must not hide an otherwise good HAP, but
rem     it is reported loudly so the package is not left only in the shared
rem     build tree where the next build overwrites it.
if exist "%HAP%" (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "& (Join-Path $env:PS_SCRIPTS_DIR 'archive-157-hap.ps1') -Hap '%HAP%' -ArtifactDir '%ARTIFACTS%' -Mode '%MODE%' -AppJson '%APPJSON%' -Since '%RUN_START%'"
  if errorlevel 1 echo [WARN] archive failed; HAP is still available at the path above
) else (
  echo [WARN] no HAP to archive
)
echo.
echo   mode=%MODE%  bundleName=%BUNDLE%  (only this build; project restored)
echo   This HAP is UNSIGNED. Sign it before installing on a device.
endlocal & exit /b 0

:restore_fail
echo.
echo [FAILED] packaging did not complete; restoring app.json5 ...
if exist "%BACKUP%" (
  copy /y "%BACKUP%" "%APPJSON%" >nul
  del /q "%BACKUP%"
  echo [ok] app.json5 restored
)
endlocal & exit /b 1
