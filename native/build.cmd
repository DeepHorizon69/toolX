@echo off
setlocal
cd /d "%~dp0.."
set "DOTNET_CLI_HOME=%CD%\.tools\dotnet-home"
set "DOTNET_CLI_TELEMETRY_OPTOUT=1"
set "DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1"
set "DOTNET_GENERATE_ASPNET_CERTIFICATE=false"
set "TOOLX_DOTNET=dotnet"
if exist "%CD%\.tools\dotnet\dotnet.exe" set "TOOLX_DOTNET=%CD%\.tools\dotnet\dotnet.exe"
"%TOOLX_DOTNET%" build native\ToolX.sln -c Release || exit /b 1
"%TOOLX_DOTNET%" run --project native\ToolX.Tests -c Release --no-build -- --live || exit /b 1
"%TOOLX_DOTNET%" run --project native\ToolX.Gui.Tests -c Release --no-build -- ".build\native-ui-layout" || exit /b 1
endlocal
