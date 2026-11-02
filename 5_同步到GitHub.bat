@echo off
chcp 65001 >nul
cd /d "%~dp0"
python "tools\sync_to_github.py"
echo.
pause
