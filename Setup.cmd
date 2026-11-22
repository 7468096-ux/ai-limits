@echo off
rem First run: builds "AI Limits.exe", adds Start menu and desktop shortcuts, starts the widget.
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0AILimits.ps1"
