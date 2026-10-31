@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul
if errorlevel 1 (
  echo Python was not found. Install Python 3.11 or newer from python.org.
  pause
  exit /b 1
)
py -3 -m pip install --user -r requirements-desktop-mis.txt
if errorlevel 1 (
  echo Could not install Selenium. Check your internet connection and Python installation.
  pause
  exit /b 1
)
py -3 scripts\mis_desktop_service.py
pause
