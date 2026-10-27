@echo off
chcp 65001 >nul
setlocal
echo ============================================================
echo  Apply engine patches (Chromium source inside WSL)
echo   * Origin fix (already applied earlier)
echo   * Desktop-site persistence (3 patches)
echo  Runs as root: the source tree is owned by root inside WSL.
echo ============================================================
echo.

echo ---- wsl distros ----
wsl -l -v
echo.

echo ---- running patcher ----
wsl -d Ubuntu -u root -- python3 /mnt/d/hmos-build/apply-engine-patches.py
set PATCHER_RC=%errorlevel%
echo patcher exit code = %PATCHER_RC%

echo.
echo ---- verification: all 4 original engine blocks must survive ----
wsl -d Ubuntu -u root -- bash /mnt/d/WorkBuddy/鸿蒙Chrome/chromium-hmos/scripts/verify-originals.sh /home/administrator/chromium-work/chromium/src
set VERIFY_RC=%errorlevel%
echo verify exit code = %VERIFY_RC%

echo.
if not "%PATCHER_RC%"=="0" goto bad
if not "%VERIFY_RC%"=="0" (
  echo [FAIL] verify-originals reported missing originals. Do NOT build.
  echo        Run: bash /mnt/d/WorkBuddy/鸿蒙Chrome/chromium-hmos/local-patches/restore.sh
  echo        then re-run this script.
  goto bad
)
echo [INFO] If you see ORIGINALS_VERIFY_OK above, all 4 originals are in the source.
echo        Only then build the engine.
goto end
:bad
echo [FAIL] patcher exit code %PATCHER_RC% or verify exit code %VERIFY_RC%. Do NOT build.
echo        Copy this whole window and send it to the assistant.
:end
echo.
pause
endlocal
