# ============================================================
#  DSH 全自动升级工具 v4 - 中文菜单（PowerShell 实现）
#  为什么菜单不放在 .bat 里：
#  cmd.exe 在 chcp 65001 下解析含多字节 UTF-8 的 .bat 时，
#  文件读取指针会错位，实测会把某几行从中间截断，例如
#  "echo    [5] 强制重装当前版本（修复程序损坏）" 变成
#  "● 本（修复程序损坏）" 并被当成命令执行报错。
#  因此 .bat 保持 100% 纯 ASCII，只做转发；所有中文由本脚本输出。
# ============================================================
$ErrorActionPreference = 'Continue'

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$MainPs1 = Join-Path $ScriptDir 'DSH-AutoUpgrade-v4.ps1'

# ---- 先做编码自检 / BOM 自愈 / 解除网络封锁标记 ----
$Guard = Join-Path $ScriptDir 'bom-guard.ps1'
if (Test-Path -LiteralPath $Guard) {
    $env:DSH_TARGET_PS1 = $MainPs1
    try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Guard } catch {}
}

if (-not (Test-Path -LiteralPath $MainPs1)) {
    Write-Host ''
    Write-Host '  [错误] 找不到主脚本 DSH-AutoUpgrade-v4.ps1' -ForegroundColor Red
    Write-Host '         它应该和本文件放在同一个目录下。' -ForegroundColor Red
    Write-Host ('         当前查找位置：' + $MainPs1) -ForegroundColor DarkGray
    Write-Host ''
    Read-Host '按回车键关闭'
    exit 1
}

function Show-Menu {
    Clear-Host
    Write-Host '============================================================'
    Write-Host '   DeepSeek Harness 全自动升级工具 v4'
    Write-Host '------------------------------------------------------------'
    Write-Host '   流程：查版本 -> 下载 -> 校验 -> 备份 -> 清理占用'
    Write-Host '         -> 安装 -> 健康检查 -> 失败自动回滚'
    Write-Host '   本机适配：自动脱离 DSH 进程树，不会把自己杀掉'
    Write-Host '============================================================'
    Write-Host ''
    Write-Host '   [1] 全自动升级（推荐，什么都不用管）'
    Write-Host '   [2] 全自动升级 + 主动探测最新版本（官方没更新时用）'
    Write-Host '   [3] 静默升级（不弹安装向导）'
    Write-Host '   [4] 仅预检（不下载、不安装，先看环境行不行）'
    Write-Host '   [5] 强制重装当前版本（修复程序损坏）'
    Write-Host '   [6] 【急救】从最近备份回滚到旧版本'
    Write-Host '   [0] 退出'
    Write-Host '============================================================'
}

function Invoke-Main {
    param([string[]]$Arguments, [string]$Title)
    Write-Host ('[正在执行] ' + $Title + '，请稍候...') -ForegroundColor Cyan
    Write-Host ''
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $exe)) { $exe = 'powershell.exe' }
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MainPs1) + $Arguments
    & $exe @all
    $code = $LASTEXITCODE
    Write-Host ''
    Write-Host '------------------------------------------------------------'
    Write-Host ('   退出码：' + $code)
    Write-Host ('   运行日志：' + (Join-Path $ScriptDir 'DSH-AutoUpgrade.log'))
    Write-Host ('   备份目录：' + (Join-Path (Split-Path -Qualifier $ScriptDir) 'dsh-rollback'))
    Write-Host '------------------------------------------------------------'
}

while ($true) {
    Show-Menu
    # 用 ReadLine 而不是 Read-Host：从管道/重定向读取时不会把输入回显到屏幕
    Write-Host '请输入序号后按回车: ' -NoNewline
    $choice = ''
    try { $choice = [Console]::ReadLine() } catch { $choice = Read-Host }
    if ($null -eq $choice) { $choice = '' }
    Write-Host ''

    switch ($choice.Trim()) {
        '1' { Invoke-Main @() '全自动升级' }
        '2' { Invoke-Main @('-ProbeLatest') '全自动升级 + 探测最新版本' }
        '3' { Invoke-Main @('-Silent') '静默升级' }
        '4' { Invoke-Main @('-DryRun') '环境预检（不会下载也不会安装）' }
        '5' { Invoke-Main @('-Force') '强制重装当前版本' }
        '6' {
            Write-Host ''
            Write-Host ' 此操作会把 DSH 恢复到【最近一次升级前】的版本。'
            Write-Host ' 恢复内容包括：程序目录 + 5 个配置文件。'
            Write-Host ' 你的会话记录 / 附件 / 登录凭据 都【不会】被动到。'
            Write-Host ''
            $confirm = ''
            Write-Host '确认要回滚吗？输入 Y 后按回车: ' -NoNewline
            try { $confirm = [Console]::ReadLine() } catch { $confirm = Read-Host }
            if ($null -eq $confirm) { $confirm = '' }
            Write-Host ''
            if ($confirm -match '^[Yy]$') {
                Invoke-Main @('-RollbackOnly') '从备份回滚'
            } else {
                Write-Host ' 已取消。' -ForegroundColor Yellow
            }
        }
        '0' { break }
        default {
            Write-Host ''
            Write-Host (' 无效输入：' + $choice + '，请输入 0-6 之间的数字。') -ForegroundColor Yellow
            Start-Sleep -Seconds 2
            continue
        }
    }

    if ($choice.Trim() -eq '0') { break }

    Write-Host ''
    Write-Host '按回车键返回菜单（输入 0 再回车退出）: ' -NoNewline
    try { [void][Console]::ReadLine() } catch { Read-Host | Out-Null }
    Write-Host ''
}

Write-Host ''
Write-Host ' 已退出。' -ForegroundColor DarkGray
