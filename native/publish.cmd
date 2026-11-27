@echo off
setlocal
cd /d "%~dp0.."
set "DOTNET_CLI_HOME=%CD%\.tools\dotnet-home"
set "DOTNET_CLI_TELEMETRY_OPTOUT=1"
set "DOTNET_GENERATE_ASPNET_CERTIFICATE=false"
set "TOOLX_DOTNET=dotnet"
if exist "%CD%\.tools\dotnet\dotnet.exe" set "TOOLX_DOTNET=%CD%\.tools\dotnet\dotnet.exe"
call native\build.cmd || exit /b 1
"%TOOLX_DOTNET%" run --project native\ToolX.Pack -c Release -- "%CD%" win-x64 win-x86
endlocal
