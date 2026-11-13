@echo off
rem ============================================================
rem  DSH AutoUpgrade v4 - launcher (PURE ASCII ONLY)
rem ------------------------------------------------------------
rem  IMPORTANT: This file must contain ONLY ASCII characters.
rem  Reason: cmd.exe reading a UTF-8 .bat containing multibyte
rem  characters can desync its file pointer, truncating lines
rem  mid-way and executing fragments as commands.
rem  All Chinese text lives in menu.ps1 instead.
rem
rem  This launcher only forwards to menu.ps1.
rem ============================================================

setlocal EnableExtensions
set "SCRIPTDIR=%~dp0"
set "MENU=%SCRIPTDIR%menu.ps1"

if not exist "%MENU%" goto NOMENU

set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=powershell.exe"

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%MENU%"
set "RC=%ERRORLEVEL%"

if "%RC%"=="0" goto END
echo.
echo Launcher finished with exit code %RC%.
pause
goto END

:NOMENU
echo.
echo [ERROR] menu.ps1 not found.
echo         It should be in the same folder as this file.
echo         Expected: %MENU%
echo.
pause
exit /b 1

:END
endlocal
