@echo off
setlocal
title Sync chromium-hmos hmos-154-adapter
rem  Usage:  sync-154.cmd          fetch + update local + push to your fork
rem          sync-154.cmd local    fetch + update local only (nothing pushed)

cd /d "%~dp0chromium-hmos"
if not exist ".git" (
  echo [!] Repo folder not found: %~dp0chromium-hmos
  echo     Clone it first, then run this script again.
  pause
  exit /b 1
)

set "PUSH=1"
if /i "%~1"=="local" set "PUSH=0"

set "GIT=git"
where git >nul 2>nul
if errorlevel 1 set "GIT=C:\Users\Administrator\.workbuddy\binaries\PortableGit\versions\1.2.0\mingw64\bin\git.exe"

set "PROXY=http://127.0.0.1:7890"
set "WINCRED=C:/Users/Administrator/.workbuddy/binaries/PortableGit/versions/1.2.0/mingw64/bin/git-credential-wincred.exe"
set "NETCFG=-c http.proxy=%PROXY% -c https.proxy=%PROXY% -c http.version=HTTP/1.1"

rem === 受保护的本地原创引擎文件（同步上游时绝不能被覆盖） ===
set "PROTECTED=patches/ohos-extension-origin.patch overlay/chrome/browser/ui/ohos/shell_store_user_agent_ohos.cc overlay/chrome/browser/ui/ohos/aura_shell_runtime_bridge.cc overlay/chrome/browser/ui/ohos/aura_shell_runtime_bridge.h overlay/arkweb/ohos_nweb/src/aura_shell/ohos_aura_input_router.cc overlay/ui/ozone/platform/ohos/ohos_phone_gpu_channel.cc overlay/ui/ozone/platform/ohos/ohos_phone_gpu_channel.h patches/ohos-bottom-crop.patch patches/ohos-paint-hold-a.patch patches/ohos-paint-hold-b.patch"

echo ============================================================
echo  Sync hmos-154-adapter
echo   pull from : miramira8295/chromium-hmos
if "%PUSH%"=="1" echo   push to   : ShixmSimon/chromium-hmos
if "%PUSH%"=="0" echo   push to   : skipped - local-only mode
echo ============================================================
echo.

echo [1/3] Fetching from miramira8295 ...
"%GIT%" %NETCFG% fetch origin hmos-154-adapter
if errorlevel 1 goto fail

echo.
echo [GUARD] 检查本地 4 块原创引擎文件是否被改 / 上游是否触及 ...
"%GIT%" diff --quiet HEAD -- %PROTECTED%
if errorlevel 1 (
  echo [GUARD-FAIL] 本地受保护原创文件有未提交改动，先 commit 再同步，否则会丢失。中止。
  goto fail
)
"%GIT%" diff --quiet HEAD..FETCH_HEAD -- %PROTECTED%
if errorlevel 1 (
  echo [GUARD-FAIL] 上游改动了我们受保护的原创文件！禁止自动 ff 覆盖，需人工核对后手动跟进。中止。
  "%GIT%" diff --stat HEAD..FETCH_HEAD -- %PROTECTED%
  goto fail
)
echo [GUARD] OK: 本地原创干净、上游未触及受保护文件。

echo.
echo [2/3] Updating local branch ...
"%GIT%" checkout hmos-154-adapter
if errorlevel 1 goto fail
"%GIT%" merge --ff-only FETCH_HEAD
if errorlevel 1 goto fail

echo.
if "%PUSH%"=="0" (
  echo [3/3] Skipped - local-only mode, nothing was pushed.
  goto done
)
echo [3/3] Pushing to ShixmSimon/chromium-hmos ...
"%GIT%" -c credential.helper= -c credential.helper="%WINCRED%" %NETCFG% push mine hmos-154-adapter
if errorlevel 1 goto fail

:done
echo.
echo ------------------------------------------------------------
echo  Done. HEAD is now:
"%GIT%" log -1 --format="  %%h  %%ad  %%s" --date=short
echo.
if "%PUSH%"=="1" echo  Local repo and your fork are both up to date.
if "%PUSH%"=="0" echo  Local repo is up to date. Your fork was NOT touched.
echo ------------------------------------------------------------
pause
exit /b 0

:fail
echo.
echo ------------------------------------------------------------
echo  FAILED. Check:
echo    - Is the local proxy running on 127.0.0.1:7890 ?
echo    - Is github.com reachable ?
echo    - Any conflict above ^ (merge is fast-forward only)
echo    - [GUARD-FAIL] 本地原创有未提交改动，或上游改了受保护文件 —— 见上方提示
echo  Nothing was pushed if the failure happened at step 1 or 2.
echo ------------------------------------------------------------
pause
exit /b 1
