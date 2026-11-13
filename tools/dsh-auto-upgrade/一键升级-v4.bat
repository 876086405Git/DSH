@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions

rem ============================================================
rem  DSH 全自动升级工具 v4 启动器
rem  编码要求：UTF-8 无 BOM + CRLF 行尾（三条缺一不可）
rem  中文显示依赖 chcp 65001 在本文件首行生效
rem ============================================================
set "SCRIPTDIR=%~dp0"
set "PS1=%SCRIPTDIR%DSH-AutoUpgrade-v4.ps1"

if not exist "%PS1%" goto NOPS1

if defined DSH_BOMGUARD_DONE goto MENU
set "DSH_BOMGUARD_DONE=1"
set "DSH_TARGET_PS1=%PS1%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPTDIR%bom-guard.ps1"

:MENU
cls
echo ============================================================
echo    DeepSeek Harness 全自动升级工具 v4
echo ------------------------------------------------------------
echo    流程：查版本 -^> 下载 -^> 校验 -^> 备份 -^> 清理占用
echo          -^> 安装 -^> 健康检查 -^> 失败自动回滚
echo    本机适配：自动脱离 DSH 进程树，不会把自己杀掉
echo ============================================================
echo.
echo    [1] 全自动升级（推荐，什么都不用管）
echo    [2] 全自动升级 + 主动探测最新版本（官方没更新时用）
echo    [3] 静默升级（不弹安装向导）
echo    [4] 仅预检（不下载、不安装，先看环境行不行）
echo    [5] 强制重装当前版本（修复程序损坏）
echo    [6] 【急救】从最近备份回滚到旧版本
echo    [0] 退出
echo ============================================================
set "CHOICE="
set /p "CHOICE=请输入序号后按回车: "
echo.

if "%CHOICE%"=="1" goto M1
if "%CHOICE%"=="2" goto M2
if "%CHOICE%"=="3" goto M3
if "%CHOICE%"=="4" goto M4
if "%CHOICE%"=="5" goto M5
if "%CHOICE%"=="6" goto M6
goto END

:M1
echo [正在执行] 全自动升级，请稍候...
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
goto DONE

:M2
echo [正在执行] 全自动升级 + 探测最新版本...
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -ProbeLatest
goto DONE

:M3
echo [正在执行] 静默升级...
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Silent
goto DONE

:M4
echo [正在执行] 环境预检（不会下载也不会安装）...
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -DryRun
goto DONE

:M5
echo [正在执行] 强制重装当前版本...
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Force
goto DONE

:M6
echo.
echo 此操作会把 DSH 恢复到【最近一次升级前】的版本。
echo 恢复内容包括：程序目录 + 5 个配置文件。
echo 你的会话记录 / 附件 / 登录凭据 都【不会】被动到。
echo.
set "CONFIRM="
set /p "CONFIRM=确认要回滚吗？输入 Y 后按回车: "
if /i not "%CONFIRM%"=="Y" goto END
echo [正在执行] 从备份回滚...
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -RollbackOnly
goto DONE

:NOPS1
echo.
echo [错误] 找不到主脚本 DSH-AutoUpgrade-v4.ps1
echo        它应该和本文件放在同一个目录下。
echo        当前查找位置：%PS1%
echo.
echo   按任意键关闭本窗口...
pause >nul
exit /b 1

:DONE
echo.
echo ------------------------------------------------------------
echo    运行日志：%SCRIPTDIR%DSH-AutoUpgrade.log
echo    备份目录：%~d0\dsh-rollback\
echo ------------------------------------------------------------
:END
echo   按任意键关闭本窗口...
pause >nul