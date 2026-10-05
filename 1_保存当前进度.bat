@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo ============================================
echo   Save current progress to git
echo ============================================
git add -A
git commit -m "manual save"
echo.
echo --- recent versions ---
git log --oneline -5
echo.
echo [OK] Saved. You can close this window.
pause
