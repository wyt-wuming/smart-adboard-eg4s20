@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo ============================================
echo   RESTORE to v1.0 (working version)
echo ============================================
echo.
echo   WARNING: all current changes will be LOST!
echo.
pause
git checkout v1.0 -- .
echo.
echo [OK] Restored to v1.0 working version.
echo      If you want to go back to the latest, run:
echo      git checkout HEAD -- .
pause
