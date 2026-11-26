@echo off
setlocal DisableDelayedExpansion
if not exist "%~dp0Toolkit.ps1" goto missingScript
set "ToolkitPowerShell=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "ToolkitPowerShell=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%ToolkitPowerShell%" goto missingPowerShell
"%ToolkitPowerShell%" -NoLogo -NoProfile -File "%~dp0Toolkit.ps1"
set "ToolkitExitCode=%errorlevel%"
if "%ToolkitExitCode%"=="0" exit /b 0
echo Check the PowerShell error above. Windows policy may prevent script execution.
goto failed

:missingScript
echo Toolkit.ps1 is missing. Keep Toolkit.cmd and Toolkit.ps1 in the same folder.
set "ToolkitExitCode=2"
goto failed

:missingPowerShell
echo Windows PowerShell could not be found on this computer.
set "ToolkitExitCode=3"

:failed
echo.
echo Toolkit stopped with error code %ToolkitExitCode%.
pause
exit /b %ToolkitExitCode%
