<#
.SYNOPSIS
  DeepSeek Harness 桌面端全自动升级修复工具（v4 本机适配版）
.DESCRIPTION
  全自动：查最新版 -> 下载 -> SHA512/签名校验 -> 清理占用 -> 验证目录 -> 安装 -> 核验 -> 启动
  内置自修复：断点续传重试、校验失败重下、目录占用重试、安装失败重试、失败回滚启动旧版
.NOTES
  v4 相对 v3 的 6 处本机适配修复（均基于本机实测）：
   1) 【致命】自动脱离 DSH 进程树：AI 代跑时脚本是 DSH 子进程，强行杀 DSH 会连带
      杀死脚本本身导致升级中断。现在检测到自己在 DSH 树内就用计划任务脱离执行。
   2) 备份清单补齐 pnpm-workspace.yaml / pnpm-lock.yaml（原版只备份 3 个文件，
      回滚后插件版本可能与新程序不匹配）。
   3) TEMP 预检清理：本机 TEMP 曾堆 5000+ 条目，安装器解压 7892 个文件时
      extract-failure（7-Zip 退出码 2）。现在 >1500 条就清 7 天前旧残留。
   4) 残留清理覆盖 .old- / .new- / .broken- / .upgrade-probe（原版只清 .old-）。
   5) 日志改为无 BOM UTF-8 追加（PS5.1 的 Add-Content -Encoding UTF8 会写 BOM）。
   6) 健康检查不再仅凭"3 分钟内有 crash 日志"就回滚：只统计升级完成之后的
      致命崩溃，且窗口仍稳定时判定可接受（避免白升）。
.PARAMETER Force
  目标版本 <= 当前版本时也强制重装
.PARAMETER ProbeLatest
  主动探测 bin 目录中更高的版本号（应对官方 feed 滞后）
.PARAMETER Silent
  静默安装（NSIS /S）
.PARAMETER NoStart
  安装后不启动 DSH
.PARAMETER DryRun
  只检查版本/空间/占用，不下载不安装
.PARAMETER InstallerPath
  跳过下载，直接使用指定安装包
#>
param(
    [switch]$Force,
    [switch]$ProbeLatest,
    [switch]$Silent,
    [switch]$NoStart,
    [switch]$DryRun,
    [switch]$RollbackOnly,
    [switch]$DetachedChild,
    [string]$InstallerPath = ''
)

# 【v4.3 新增】未知参数校验。
# 背景：用 -File 方式调用时，拼错的参数（如 -Force2）会被 PowerShell 静默忽略，
# 脚本照常跑，用户以为加了某个选项其实没生效 —— 这是危险的静默失败。
# 这里显式检查未绑定的位置参数，发现就打中文提示并退出（退出码 22）。
if ($args.Count -gt 0) {
    Write-Host ''
    Write-Host '[错误] 检测到无法识别的参数：' -ForegroundColor Red
    foreach ($a in $args) { Write-Host ('        ' + $a) -ForegroundColor Red }
    Write-Host ''
    Write-Host '可用的参数有：' -ForegroundColor Yellow
    Write-Host '  -Force          强制重装（即使已是最新版本）'
    Write-Host '  -ProbeLatest    主动探测 bin 目录里的更新版本'
    Write-Host '  -Silent         静默安装（不弹安装向导）'
    Write-Host '  -NoStart        装完不自动启动 DSH'
    Write-Host '  -DryRun         仅预检，不下载不安装'
    Write-Host '  -RollbackOnly   仅从最近备份回滚，不升级'
    Write-Host '  -InstallerPath  指定安装包路径'
    Write-Host ''
    Write-Host '提示：通常直接双击【一键升级-v4.bat】选菜单即可，不需要手敲参数。' -ForegroundColor Gray
    Write-Host ''
    exit 22
}

# 【v4 新增】标记本进程已脱离 DSH 进程树（由计划任务拉起），不再二次脱离。
if ($DetachedChild) { $env:DSH_UPGRADE_DETACHED = '1' }

# 【v4.1 新增·并发保护】单实例互斥锁。
# 风险：用户双击两次 .bat，两个实例会同时杀 DSH、同时抢装，导致安装器互相打架、
# 甚至把刚装好的目录再改坏。用系统级命名 Mutex 保证同一时刻只跑一个实例。
# 注意：子进程（-DetachedChild）需要拿到锁，父进程在脱离前会主动释放。
$script:UpgradeMutex = $null
if (-not $env:DSH_UPGRADE_MUTEX_HELD) {
    try {
        $createdNew = $false
        $script:UpgradeMutex = New-Object System.Threading.Mutex($true, 'Global\DSH-AutoUpgrade-SingleInstance', [ref]$createdNew)
        if (-not $createdNew) {
            Write-Host ''
            Write-Host '[ERROR] 已有一个 DSH 升级实例正在运行，本次退出以免两个安装器互相破坏。' -ForegroundColor Red
            Write-Host '        请等待上一个窗口跑完；若确认没有在跑，请重启电脑后再试。' -ForegroundColor Yellow
            exit 21
        }
        $env:DSH_UPGRADE_MUTEX_HELD = '1'
    } catch {
        # 拿不到互斥体（极少数权限场景）也继续，但不阻断升级
        $script:UpgradeMutex = $null
    }
}

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# ===================== 配置 =====================
$Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Root) { $Root = (Get-Location).Path }
$LogFile    = Join-Path $Root 'DSH-AutoUpgrade.log'
$DlDir      = Join-Path $Root 'downloads'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'
$ExePath    = Join-Path $InstallDir 'DeepSeek Harness.exe'
$ProfileDir = Join-Path $env:USERPROFILE '.dsh\profiles\desktop'
$FeedUrl    = 'https://download.deepseek.com/dsh-desk/feeds/win-x64/nightly.yml'
$BinBase    = 'https://download.deepseek.com/dsh-desk/bin/win-x64/'
# 回滚备份目录：自动跟随安装目录所在分区（同分区复制最快）
$RollbackDir = (Split-Path $InstallDir -Qualifier) + '\dsh-rollback'
$MaxKillRounds = 10
$MaxRenameTries = 4
$MaxDownloadTries = 4
$InstallerTimeoutMin = 15
$MinFreeGB = 3          # 兜底最小值；实际按 2x程序目录 + 1.5GB 动态计算
$RollbackWaitSec = 90   # 回滚后等窗口出现的上限

# 数据保护清单：以下路径【绝不】备份、删除或恢复（升级只动程序目录）
$ProtectedData = @(
    (Join-Path $env:USERPROFILE '.dsh\sessions'),
    (Join-Path $env:USERPROFILE '.dsh\attachments'),
    (Join-Path $env:USERPROFILE '.dsh\.credentials.yaml'),
    (Join-Path $env:USERPROFILE '.dsh\storages'),
    (Join-Path $env:USERPROFILE '.dsh\skills'),
    (Join-Path $env:USERPROFILE '.dsh\integrations'),
    (Join-Path $env:USERPROFILE '.dsh\rewind-snapshots'),
    (Join-Path $ProfileDir 'node_modules')
)
# 【v4 修复】只备份这 3 个文件会漏掉 pnpm 配置：
# 本机 profile 里有 pnpm-workspace.yaml（插件版本豁免，被 pnpm 频繁改写、曾写坏过）
# 和 pnpm-lock.yaml（锁定所有插件版本）。回滚时不恢复它们，插件状态会与新程序不匹配。
$ConfigFilesToBackup = @('package.json','cordis.yml','cordis.patch.yml','pnpm-workspace.yaml','pnpm-lock.yaml')

# ===================== 日志 =====================
# 【v4.9 修复·致命】Test-DshWebAlive 必须在 Restore-FromBackup 之前定义，
# 因为后者内部（回滚后的健康检查）会调用它。PowerShell 顺序执行，
# 定义在使用之后 = 函数不存在 = 调用抛错被吞 = 回滚后 Web 探测永远失败。
function Test-DshWebAlive {
    param([int]$TimeoutSec = 30)
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec) {
        try {
            $pids = @(Get-DshProcesses | ForEach-Object { $_.Id })
            if ($pids.Count -eq 0) { return $null }
            # 找这些进程正在监听的本地 TCP 端口
            $listen = @()
            try {
                $listen = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                    Where-Object { $pids -contains $_.OwningProcess -and $_.LocalAddress -match '^(127\.0\.0\.1|0\.0\.0\.0|::1|::)$' })
            } catch {}
            foreach ($l in $listen) {
                $port = $l.LocalPort
                # 只探测高位端口，避免误判系统端口
                if ($port -lt 1024) { continue }
                # 【v4.7 修复·致命】原来用 foreach ($host in @('127.0.0.1'))，
                # 但 $host 是 PowerShell 的只读内置变量（ConsoleHost），赋值直接抛
                # "无法覆盖变量 Host，因为该变量为只读变量或常量"，而该异常又被外层
                # catch {} 静默吞掉 —— 导致 Web 探测【从未生效过】，虚拟机里永远判定启动失败。
                # 修复：变量改名为 $probeHost。
                foreach ($probeHost in @('127.0.0.1')) {
                    try {
                        $r = Invoke-WebRequest -Uri ('http://' + $probeHost + ':' + $port + '/') -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
                        if ($r.StatusCode -eq 200 -and $r.Content -match '<html|<!doctype') {
                            return [pscustomobject]@{ Port = $port; Status = $r.StatusCode; Length = $r.Content.Length }
                        }
                    } catch {
                        # 401 也算「服务活着」（只是缺 token）
                        $code = 0
                        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
                        if ($code -eq 401 -or $code -eq 403) {
                            return [pscustomobject]@{ Port = $port; Status = $code; Length = 0 }
                        }
                    }
                }
            }
        } catch {}
        Start-Sleep -Milliseconds 800
    }
    return $null
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    # 【v4 修复】PowerShell 5.1 的 Add-Content -Encoding UTF8 会写 BOM，
    # 且多次追加时中文可能被 ANI 码页误读导致乱码。改为显式无 BOM 追加。
    # 【v4.2 汉化】日志级别标签原本是 [OK]/[WARN]/[ERROR]/[STEP]/[INFO]，
    # 用户反馈看不懂英文，统一改成中文标签。
    $label = switch ($Level) {
        'OK'    { '成功' }
        'WARN'  { '注意' }
        'ERROR' { '失败' }
        'STEP'  { '步骤' }
        default { '信息' }
    }
    $line = "[$ts][$label] $Message"
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine, $utf8NoBom)
    } catch {}
    switch ($Level) {
        'OK'    { Write-Host $line -ForegroundColor Green }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'STEP'  { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line -ForegroundColor Gray }
    }
}
function New-Section { param([string]$T) Write-Log ''; Write-Log ('========== ' + $T + ' ==========') 'STEP' }

try {
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 512KB)) {
        Move-Item $LogFile ($LogFile + '.old') -Force -ErrorAction SilentlyContinue
    }
} catch {}
Write-Log '############################################################'
$cnBool = { param($v) if ($v) { '是' } else { '否' } }
Write-Log ('DSH 全自动升级工具 v4（本机适配）启动' + '  强制重装=' + (& $cnBool $Force) + '  探测最新=' + (& $cnBool $ProbeLatest) + '  静默安装=' + (& $cnBool $Silent) + '  仅预检=' + (& $cnBool $DryRun) + '  仅回滚=' + (& $cnBool $RollbackOnly))

# ===================== 工具函数 =====================

# 【v4 新增·致命修复】判断某进程是否在本脚本祖先链（=DSH 进程树）内。
# 背景：本工具常被用户在 DSH 会话里让 AI 代跑，此时 powershell 是 DSH 的子进程。
# 阶段3 强杀 DSH 会连带杀死本脚本，导致"升到一半就断"，DSH 停在半装状态。
function Test-InDshTree {
    param([int]$ProcessId)
    $cur = $ProcessId
    $depth = 0
    while ($cur -and $depth -lt 15) {
        $q = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue
        if (-not $q) { return $false }
        if ($q.Name -eq 'DeepSeek Harness.exe') { return $true }
        $cur = $q.ParentProcessId
        $depth++
    }
    return $false
}

function Get-DshProcesses { @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue) }

function Get-InstalledVersion {
    if (Test-Path $ExePath) {
        try { return (Get-Item $ExePath).VersionInfo.FileVersion } catch { return '' }
    }
    return ''
}

function Split-SemVer {
    param([string]$v)
    $v = $v.Trim().TrimStart('v')
    $core = $v; $pre = ''
    $d = $v.IndexOf('-')
    if ($d -ge 0) { $core = $v.Substring(0, $d); $pre = $v.Substring($d + 1) }
    $nums = @()
    foreach ($seg in $core.Split('.')) {
        $n = 0
        if ([int]::TryParse(($seg -replace '[^0-9]', ''), [ref]$n)) { $nums += $n } else { $nums += 0 }
    }
    while ($nums.Count -lt 3) { $nums += 0 }
    return @{ Core = $nums; Pre = $pre }
}

function Compare-SemVer {
    param([string]$A, [string]$B)
    if (-not $A) { return -1 }
    if (-not $B) { return 1 }
    $x = Split-SemVer $A
    $y = Split-SemVer $B
    for ($i = 0; $i -lt 3; $i++) {
        if ($x.Core[$i] -lt $y.Core[$i]) { return -1 }
        if ($x.Core[$i] -gt $y.Core[$i]) { return 1 }
    }
    if ($x.Pre -eq '' -and $y.Pre -ne '') { return 1 }
    if ($x.Pre -ne '' -and $y.Pre -eq '') { return -1 }
    # 【v4.1 修复】原来用 -eq，但 PowerShell 的 -eq 对字符串【大小写不敏感】，
    # 会把 'RC.2' 与 'rc.2' 误判为相等而提前 return 0，跳过后续有序比较。
    # SemVer 规范要求预发布标识区分大小写（按 ASCII 序），故改用 -ceq。
    if ($x.Pre -ceq $y.Pre) { return 0 }
    $px = @($x.Pre -split '\.')
    $py = @($y.Pre -split '\.')
    $n = [Math]::Min($px.Count, $py.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $nx = 0; $ny = 0
        $ix = [int]::TryParse($px[$i], [ref]$nx)
        $iy = [int]::TryParse($py[$i], [ref]$ny)
        if ($ix -and $iy) {
            if ($nx -lt $ny) { return -1 }
            if ($nx -gt $ny) { return 1 }
        } else {
            $c = [string]::CompareOrdinal($px[$i], $py[$i])
            if ($c -lt 0) { return -1 }
            if ($c -gt 0) { return 1 }
        }
    }
    if ($px.Count -lt $py.Count) { return -1 }
    if ($px.Count -gt $py.Count) { return 1 }
    return 0
}

function Start-Dsh {
    if ($NoStart) { Write-Log '按参数跳过启动'; return }
    if (Test-Path $ExePath) {
        Write-Log '启动 DSH...'
        try { Start-Process -FilePath $ExePath -WorkingDirectory $InstallDir | Out-Null } catch { Write-Log ('启动失败: ' + $_.Exception.Message) 'WARN' }
    }
}

function Wait-DshWindow {
    param([int]$TimeoutSec = 60)
    $t0 = Get-Date
    # 【v4.1 修复】原来用 $i -gt 20（约 10 秒）才开始判断"进程已死"，
    # 若 DSH 启动瞬间崩溃要白等 10 秒；且原逻辑只看"进程数=0"，
    # 漏掉"进程还在但反复重启、窗口永远出不来"的崩溃循环。
    # 现在：记录首轮进程数，若连续多轮进程数始终为 0 则立即返回失败。
    $deadRounds = 0
    for ($i = 0; $i -lt ($TimeoutSec * 2); $i++) {
        Start-Sleep -Milliseconds 500
        $pr = Get-DshProcesses
        if (@($pr | Where-Object { $_.MainWindowHandle -ne 0 }).Count -gt 0) {
            return [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
        }
        if ($pr.Count -eq 0) {
            $deadRounds++
            # 连续 6 次（约 3 秒）没有任何进程 => 启动失败，立刻返回
            if ($deadRounds -ge 6) { return -1 }
        } else {
            $deadRounds = 0
        }
    }
    return -1
}

# 备份程序目录 + profile 配置；失败返回 $null（调用方必须中止升级）
function Backup-Installation {
    param([string]$VersionTag)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeVer = ($VersionTag -replace '[^0-9A-Za-z.-]', '_')
    $bkRoot = Join-Path $RollbackDir ('app-' + $safeVer + '-' + $stamp)
    New-Item -ItemType Directory -Force -Path $bkRoot | Out-Null

    Write-Log ('备份程序目录 -> ' + $bkRoot)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & robocopy $InstallDir $bkRoot /E /NFL /NDL /NJH /NJS /R:1 /W:1 /MT:8 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $sw.Stop()
    if ($code -ge 8) {
        Write-Log ('备份失败（robocopy 退出码 ' + $code + '）') 'ERROR'
        return $null
    }
    $srcCount = @(Get-ChildItem $InstallDir -Recurse -File -Force -ErrorAction SilentlyContinue).Count
    $dstCount = @(Get-ChildItem $bkRoot -Recurse -File -Force -ErrorAction SilentlyContinue).Count
    $sw2 = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    if ($srcCount -gt 0 -and $dstCount -lt [math]::Floor($srcCount * 0.99)) {
        Write-Log ('备份不完整: ' + $dstCount + '/' + $srcCount + ' 文件') 'ERROR'
        return $null
    }
    Write-Log ('备份完成: ' + $dstCount + '/' + $srcCount + ' 文件, ' + $sw2 + 's') 'OK'

    $cfgDir = Join-Path $bkRoot '_profile'
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    $saved = @()
    foreach ($f in $ConfigFilesToBackup) {
        $src = Join-Path $ProfileDir $f
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $cfgDir $f) -Force -ErrorAction SilentlyContinue
            $saved += $f
        }
    }
    Write-Log ('已备份 profile 配置: ' + ($saved -join ', '))

    $totalBytes = (Get-ChildItem $bkRoot -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    $meta = [ordered]@{
        version     = $VersionTag
        backupTime  = (Get-Date).ToString('o')
        installDir  = $InstallDir
        profileDir  = $ProfileDir
        fileCount   = $dstCount
        totalBytes  = $totalBytes
        configFiles = $saved
    }
    try { ($meta | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $bkRoot '_meta.json') -Encoding UTF8 } catch {}
    return $bkRoot
}

# 自动回滚：恢复程序目录与配置，并验证可用
function Restore-FromBackup {
    param([string]$BackupPath)

    New-Section '自动回滚 / 恢复升级前版本'
    if (-not $BackupPath -or -not (Test-Path $BackupPath)) {
        Write-Log '备份不存在，无法回滚' 'ERROR'
        return $false
    }
    Write-Log ('备份来源: ' + $BackupPath)

    # 1) 结束所有进程
    # 【v4.9 修复·致命】原来只做 $p.Kill() + catch{}，两个问题：
    #  a) Kill() 是异步的，立即检查「进程数=0」常常还没退干净就往下走；
    #  b) 杀失败的错误被 catch{} 静默吞掉，日志里完全看不出为什么回滚失败。
    # 实测（虚拟机 2026-11-13）：回滚 3 秒就 return false，日志零线索，
    # 真实原因是进程占着安装目录导致改名报「另一个进程正在使用此文件」。
    # 修复：Kill 后等待退出、失败重试、记录每步结果、失败时打印占用进程。
    $round = 0
    do {
        $round++
        $ps = @(Get-DshProcesses)
        if ($ps.Count -eq 0) { break }
        Write-Log ('结束进程 ' + $ps.Count + ' 个（第 ' + $round + ' 轮）')
        foreach ($p in $ps) {
            try { $p.Kill(); $null = $p.WaitForExit(5000) }
            catch { Write-Log ('  结束进程失败 PID=' + $p.Id + ': ' + $_.Exception.Message) 'WARN' }
        }
        Start-Sleep -Seconds 2
    } while ($round -lt 10)
    $left = @(Get-DshProcesses)
    if ($left.Count -gt 0) {
        Write-Log ('进程无法结束（剩余 ' + $left.Count + ' 个），回滚中止') 'ERROR'
        foreach ($p in $left) { Write-Log ('  仍在运行: PID=' + $p.Id + ' ' + $p.ProcessName) 'ERROR' }
        return $false
    }
    Write-Log '所有 DSH 进程已结束' 'OK'

    # 2) 现有（损坏的）目录改名留证据
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $brokenLeaf = (Split-Path $InstallDir -Leaf) + '.broken-' + $stamp
    $renamed = $false
    for ($t = 1; $t -le 4; $t++) {
        try {
            Rename-Item -LiteralPath $InstallDir -NewName $brokenLeaf -ErrorAction Stop
            $renamed = $true
            Write-Log ('损坏目录已改名: ' + $brokenLeaf) 'OK'
            break
        } catch {
            Write-Log ('改名失败(' + $t + '/4): ' + $_.Exception.Message) 'WARN'
            if ($t -eq 2) {
                # 【v4.9 新增】改名被占用时，用 taskkill /F /T 强杀整棵进程树兜底。
                # 实测 .Kill() 有时杀不掉子进程（GPU/utility 进程），taskkill /T 更彻底。
                Write-Log '  改用 taskkill /F /T 强制结束整棵进程树...' 'WARN'
                foreach ($pn in @('DeepSeek Harness')) {
                    & taskkill /F /T /IM ($pn + '.exe') 2>&1 | Out-Null
                }
                Start-Sleep -Seconds 3
            } else {
                Start-Sleep -Seconds 2
                Get-DshProcesses | ForEach-Object { try { $_.Kill() } catch {} }
            }
        }
    }
    if (-not $renamed) {
        Write-Log '无法改名，尝试就地覆盖恢复（风险较高）' 'WARN'
    }

    # 3) 复制备份回去
    Write-Log '从备份恢复程序目录（约 1 分钟，请稍候）...'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $excludeDir = Join-Path $BackupPath '_profile'
    & robocopy $BackupPath $InstallDir /E /NFL /NDL /NJH /NJS /R:1 /W:1 /MT:8 /XD $excludeDir 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $sw.Stop()
    if ($code -ge 8) {
        Write-Log ('恢复复制失败（robocopy 退出码 ' + $code + '）') 'ERROR'
        Write-Log ('备份仍在: ' + $BackupPath) 'WARN'
        return $false
    }
    Write-Log ('恢复复制完成，耗时 ' + [math]::Round($sw.Elapsed.TotalSeconds, 1) + 's') 'OK'

    # 4) 恢复 profile 配置
    $cfgDir = Join-Path $BackupPath '_profile'
    if (Test-Path $cfgDir) {
        foreach ($f in $ConfigFilesToBackup) {
            $src = Join-Path $cfgDir $f
            if (Test-Path $src) {
                try { Copy-Item $src (Join-Path $ProfileDir $f) -Force -ErrorAction Stop; Write-Log ('已恢复配置: ' + $f) 'OK' } catch { Write-Log ('配置恢复失败: ' + $f) 'WARN' }
            }
        }
    }

    # 5) 启动并验证可用
    if (-not (Test-Path $ExePath)) {
        Write-Log '恢复后 exe 不存在' 'ERROR'
        return $false
    }
    Write-Log '启动恢复后的 DSH...'
    try { Start-Process -FilePath $ExePath -WorkingDirectory $InstallDir | Out-Null } catch { Write-Log ('启动失败: ' + $_.Exception.Message) 'ERROR'; return $false }
    $el = Wait-DshWindow -TimeoutSec $RollbackWaitSec
    if ($el -ge 0) {
        Write-Log ('回滚成功，主窗口已出现（' + $el + 's），版本 ' + (Get-InstalledVersion)) 'OK'
        return $true
    }
    # 【v4.7 修复·严重】回滚后的健康检查原来只看窗口，虚拟机/无GPU环境
    # （Electron 降级为 Web 模式、不建窗口）会被误判为「回滚失败」，
    # 进而触发「需要人工介入」，实际上服务跑得好好的。
    # 修复：窗口没出现时，同样走 Web 服务探测。
    Write-Log ('回滚后窗口未在 ' + $RollbackWaitSec + 's 内出现，改查 Web 服务模式...') 'WARN'
    $webOk = Test-DshWebAlive -TimeoutSec 40
    if ($webOk) {
        Write-Log ('回滚成功（Web 模式运行，端口 ' + $webOk.Port + '，HTTP ' + $webOk.Status + '），版本 ' + (Get-InstalledVersion)) 'OK'
        return $true
    }
    Write-Log ('回滚后窗口和 Web 服务均未就绪') 'ERROR'
    return $false
}

function Exit-WithRestore {
    param([int]$Code, [string]$Reason)
    Write-Log ('中止: ' + $Reason) 'ERROR'
    if ((Get-DshProcesses).Count -eq 0) { Start-Dsh }
    Write-Log ('退出码 ' + $Code)
    Write-Log '############################################################'
    exit $Code
}

function Remove-DirRobust {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $Path)) { return $true }
    } catch {}
    # 兜底：robocopy 空目录镜像清空，再删空壳
    try {
        $empty = Join-Path $env:TEMP ('_empty_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $empty | Out-Null
        & robocopy $empty $Path /MIR /NFL /NDL /NJH /NJS /R:1 /W:1 2>&1 | Out-Null
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
        return (-not (Test-Path -LiteralPath $Path))
    } catch { return $false }
}


# ---------- 手动回滚模式：直接从最近备份恢复，不升级 ----------
# 【v4.9 修复·致命】这个块原来放在行 169，但 Restore-FromBackup 函数定义在行 367。
# PowerShell 是顺序执行的，此时函数还不存在，调用直接抛「无法将 Restore-FromBackup 项识别为...」，
# 而该异常又被静默吞掉 —— 导致 -RollbackOnly 永远失败（实测 4 秒返回 exit 6，日志零线索）。
# 修复：整块移到所有函数定义之后。
# ---------- 手动回滚模式：直接从最近备份恢复，不升级 ----------
if ($RollbackOnly) {
    New-Section '手动回滚模式 / 从最近备份恢复'
    $latest = $null
    if (Test-Path $RollbackDir) {
        $latest = Get-ChildItem $RollbackDir -Directory -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if (-not $latest) {
        Write-Log ('没有找到任何备份（目录: ' + $RollbackDir + '）') 'ERROR'
        Write-Log '无法回滚。如果你的 DSH 还能用，说明不需要回滚。' 'WARN'
        Write-Log '############################################################'
        exit 16
    }
    Write-Log ('使用最近备份: ' + $latest.FullName)
    Write-Log ('备份时间: ' + $latest.LastWriteTime)
    $metaFile = Join-Path $latest.FullName '_meta.json'
    if (Test-Path $metaFile) {
        try { $m = Get-Content $metaFile -Raw | ConvertFrom-Json; Write-Log ('备份版本: ' + $m.version + '  文件数: ' + $m.fileCount) } catch {}
    }
    $okRollback = Restore-FromBackup -BackupPath $latest.FullName
    if ($okRollback) {
        Write-Log ('回滚成功，当前版本 ' + (Get-InstalledVersion)) 'OK'
        Write-Log '############################################################'
        Write-Host ''
        Write-Host '已恢复到升级前版本，可以正常使用。' -ForegroundColor Green
        exit 0
    }
    Write-Log '回滚失败，请按上面打印的手动步骤操作' 'ERROR'
    Write-Log '############################################################'
    exit 6
}


# 【v4.9 修复·致命】Test-DshWebAlive 原来定义在文件末尾（行 1081），但 Restore-FromBackup
# 函数内（行 443）就会调用它。PowerShell 顺序执行，此时函数不存在，回滚后的 Web 探测
# 必然失败。修复：整个函数移到所有函数定义区。

# ===================== 阶段1：确定目标版本 =====================
New-Section '阶段1 / 确定目标版本'

$current = Get-InstalledVersion
Write-Log ('当前已安装版本: ' + $(if ($current) { $current } else { '(未知)' }))

$target = $null

# 1.1 查官方 feed
try {
    Write-Log ('查询 feed: ' + $FeedUrl)
    $resp = Invoke-WebRequest -Uri $FeedUrl -UseBasicParsing -TimeoutSec 30 -Headers @{ 'User-Agent' = 'electron-updater'; 'Cache-Control' = 'no-cache' }
    $yml = $resp.Content
    if ($yml -match '(?m)^version:\s*([0-9][^\s]*)') {
        $fv = $Matches[1].Trim("'").Trim('"')
        $furl = $null; $fsha = $null; $fsize = $null
        if ($yml -match "(?m)^\s*path:\s*>?-?\s*[\r\n]*\s*(\S+)") { $furl = $Matches[1] }
        if ($yml -match "(?m)^sha512:\s*>?-?\s*[\r\n]*\s*(\S+)") { $fsha = $Matches[1] }
        if ($yml -match "(?m)^\s*size:\s*(\d+)") { $fsize = [long]$Matches[1] }
        Write-Log ('feed 版本: ' + $fv)
        if ($furl) {
            $target = @{ Version = $fv; Url = $furl; Sha512 = $fsha; Size = $fsize; Source = 'feed' }
        } else {
            Write-Log 'feed 中未解析到下载地址' 'WARN'
        }
    } else {
        Write-Log 'feed 解析失败（无 version）' 'WARN'
    }
} catch {
    Write-Log ('feed 查询失败: ' + $_.Exception.Message) 'WARN'
}

# 1.2 主动探测更高版本（feed 滞后时）
$needProbe = $ProbeLatest
if (-not $target) { $needProbe = $true }
if ($target -and $current -and ((Compare-SemVer $target.Version $current) -le 0)) { $needProbe = $true }

if ($needProbe) {
    Write-Log '启用版本探测（应对 feed 滞后）...'
    $base = if ($current) { $current } else { '0.2.2-rc.1' }
    $core = $base
    if ($base -match '^(\d+\.\d+\.\d+)') { $core = $Matches[1] }
    $cands = @($core)
    for ($i = 1; $i -le 8; $i++) { $cands += ($core + '-rc.' + $i) }
    for ($i = 1; $i -le 4; $i++) { $cands += ($core + '-alpha.' + $i) }

    $best = $null
    foreach ($v in $cands) {
        if ($current -and ((Compare-SemVer $v $current) -le 0)) { continue }
        $u = $BinBase + 'deepseek-harness-' + $v + '-win-x64.exe'
        try {
            $hr = Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing -TimeoutSec 12 -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
            if ($hr.StatusCode -eq 200) {
                if (-not $best -or ((Compare-SemVer $v $best.Version) -gt 0)) {
                    $best = @{ Version = $v; Url = $u; Sha512 = $null; Size = $null; Source = 'probe' }
                    Write-Log ('  探测到可用版本: ' + $v) 'OK'
                }
            }
        } catch {}
    }
    if ($best) {
        if (-not $target -or ((Compare-SemVer $best.Version $target.Version) -gt 0)) {
            Write-Log ('探测版本 ' + $best.Version + ' 高于 feed，采用探测结果') 'OK'
            $target = $best
        }
    }
}

if (-not $target) { Exit-WithRestore 12 '无法确定目标版本' }

Write-Log ('目标版本: ' + $target.Version + '  来源: ' + $target.Source) 'OK'
Write-Log ('下载地址: ' + $target.Url)
if ($target.Sha512) { Write-Log ('期望 SHA512: ' + $target.Sha512.Substring(0, [Math]::Min(24, $target.Sha512.Length)) + '...') }

$cmp = if ($current) { Compare-SemVer $target.Version $current } else { 1 }
Write-Log ('版本比较: 目标 ' + $target.Version + ' vs 当前 ' + $current + ' => ' + $cmp)

if (-not $Force -and $cmp -le 0) {
    Write-Log ''
    Write-Log ('已是最新版本（当前 ' + $current + '），无需升级。要强制重装请加 -Force') 'OK'
    Write-Log '############################################################'
    exit 0
}
if ($cmp -lt 0 -and $Force) { Write-Log '强制模式：允许降级' 'WARN' }

# 1.3 预检
Write-Log ''
if (-not (Test-Path $InstallDir)) { Exit-WithRestore 10 '安装目录不存在' }
$dirSizeMB = [math]::Round(((Get-ChildItem $InstallDir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB), 1)
Write-Log ('安装目录体积: ' + $dirSizeMB + ' MB')
# 需要：回滚备份(1x) + 安装器自带备份(1x) + 安装包(~300MB) + 余量
$needMB = [math]::Ceiling($dirSizeMB * 2) + 800
$needGB = [math]::Round($needMB / 1024, 1)
if ($needGB -lt $MinFreeGB) { $needGB = $MinFreeGB }
try {
    $freeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
    Write-Log ('C: 剩余空间: ' + $freeGB + ' GB（本次升级预计需要 ' + $needGB + ' GB）')
    if ($freeGB -lt $needGB) { Exit-WithRestore 11 ('磁盘空间不足：需要约 ' + $needGB + ' GB（含回滚备份），当前仅 ' + $freeGB + ' GB') }
} catch {}
$procs = Get-DshProcesses
Write-Log ('当前 DSH 进程数: ' + $procs.Count)

# 【v4 新增】TEMP 预检清理。
# 背景：本机实测安装器报 extract-failure（7-Zip 退出码 2 Cannot open output file），
# 根因之一是 TEMP 里堆了 5000+ 条目，解压 7892 个文件到临时目录时资源吃紧。
# 这里只清 7 天前、且明确属于旧解压残留的条目，不动近期文件。
try {
    $tempRoot = $env:TEMP
    $tempCount = @(Get-ChildItem $tempRoot -ErrorAction SilentlyContinue).Count
    Write-Log ('TEMP 条目数: ' + $tempCount)
    if ($tempCount -gt 1500) {
        Write-Log ('TEMP 条目偏多（' + $tempCount + '），清理 7 天前的旧残留以降低解压失败风险') 'WARN'
        $cutoff = (Get-Date).AddDays(-7)
        $stale = @(Get-ChildItem $tempRoot -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoff })
        $rm = 0
        foreach ($s in $stale) {
            try { Remove-Item $s.FullName -Recurse -Force -ErrorAction Stop; $rm++ } catch {}
        }
        Write-Log ('已清理 TEMP 旧条目: ' + $rm + ' 个，现有 ' + @(Get-ChildItem $tempRoot -ErrorAction SilentlyContinue).Count) 'OK'
    }
    # 顺手清掉安装器上次失败留下的 nsu*.tmp 解压残留
    $nsu = @(Get-ChildItem $tempRoot -Directory -Filter 'nsu*.tmp' -ErrorAction SilentlyContinue)
    foreach ($n in $nsu) {
        try { Remove-Item $n.FullName -Recurse -Force -ErrorAction Stop; Write-Log ('已清解压残留: ' + $n.Name) 'OK' } catch {}
    }
} catch { Write-Log ('TEMP 清理异常（忽略）: ' + $_.Exception.Message) 'WARN' }

if ($DryRun) {
    New-Section 'DryRun 结束（未下载、未安装）'
    Write-Log ('将升级: ' + $current + ' -> ' + $target.Version) 'OK'
    Write-Log '############################################################'
    exit 0
}

# ===================== 阶段2：下载 =====================
New-Section '阶段2 / 下载安装包'

$fileName = 'deepseek-harness-' + $target.Version + '-win-x64.exe'
$localPath = $null

if ($InstallerPath -and (Test-Path $InstallerPath)) {
    $localPath = (Resolve-Path $InstallerPath).Path
    Write-Log ('使用指定安装包: ' + $localPath) 'OK'
} else {
    New-Item -ItemType Directory -Force -Path $DlDir | Out-Null
    $localPath = Join-Path $DlDir $fileName
    $needDownload = $true

    if (Test-Path $localPath) {
        $existSize = (Get-Item $localPath).Length
        if ($target.Size -and ($existSize -eq $target.Size)) {
            Write-Log '已存在完整文件（大小一致），跳过下载' 'OK'
            $needDownload = $false
        } elseif ($target.Size -and ($existSize -gt $target.Size)) {
            Write-Log '本地文件偏大，删除重下'
            Remove-Item $localPath -Force -ErrorAction SilentlyContinue
        } else {
            Write-Log ('存在部分文件 ' + [math]::Round($existSize / 1MB, 1) + ' MB，将断点续传')
        }
    }

    if ($needDownload) {
        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        $ok = $false
        for ($try = 1; $try -le $MaxDownloadTries; $try++) {
            Write-Log ('--- 下载尝试 ' + $try + '/' + $MaxDownloadTries + ' ---')
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                if (Test-Path $curl) {
                    $curlArgs = @('-L', '--fail', '--retry', '3', '--retry-delay', '2',
                                  '--connect-timeout', '30', '-C', '-', '-o', $localPath, $target.Url)
                    $p = Start-Process -FilePath $curl -ArgumentList $curlArgs -PassThru -WindowStyle Hidden -ErrorAction Stop
                    $lastReport = 0
                    while (-not $p.HasExited) {
                        Start-Sleep -Seconds 3
                        if (Test-Path $localPath) {
                            $mb = [math]::Round((Get-Item $localPath).Length / 1MB, 1)
                            if (($mb - $lastReport) -ge 20) {
                                Write-Log ('    已下载 ' + $mb + ' MB ...')
                                $lastReport = $mb
                            }
                        }
                        if ($sw.Elapsed.TotalMinutes -gt 30) { try { $p.Kill() } catch {}; Write-Log '下载超 30 分钟，强制结束' 'WARN'; break }
                    }
                    $code = $p.ExitCode
                    Write-Log ('curl 退出码 ' + $code + '，耗时 ' + [math]::Round($sw.Elapsed.TotalSeconds) + 's')
                    if ($code -eq 0) { $ok = $true }
                } else {
                    Invoke-WebRequest -Uri $target.Url -OutFile $localPath -UseBasicParsing -TimeoutSec 1800
                    $ok = $true
                }
            } catch {
                Write-Log ('下载异常: ' + $_.Exception.Message) 'WARN'
            }
            $sw.Stop()
            if ($ok) {
                $sz = (Get-Item $localPath).Length
                if ($target.Size -and ($sz -ne $target.Size)) {
                    Write-Log ('大小不符（实际 ' + $sz + ' / 期望 ' + $target.Size + '），继续续传') 'WARN'
                    $ok = $false
                    Start-Sleep -Seconds 3
                    continue
                }
                break
            }
            Start-Sleep -Seconds 3
        }
        if (-not $ok) { Exit-WithRestore 13 ('下载失败（已重试 ' + $MaxDownloadTries + ' 次）') }
        Write-Log ('下载完成: ' + [math]::Round((Get-Item $localPath).Length / 1MB, 1) + ' MB') 'OK'
    }
}

# 2.2 SHA512 校验
if ($target.Sha512) {
    try {
        Write-Log '校验 SHA512...'
        $actual = (Get-FileHash -LiteralPath $localPath -Algorithm SHA512).Hash.ToUpper()
        $expectedBytes = [Convert]::FromBase64String($target.Sha512)
        $expected = (($expectedBytes | ForEach-Object { $_.ToString('X2') }) -join '')
        if ($actual -eq $expected) {
            Write-Log 'SHA512 校验通过' 'OK'
        } else {
            Write-Log ('SHA512 不匹配！期望 ' + $expected.Substring(0, 24) + '... 实际 ' + $actual.Substring(0, 24) + '...') 'ERROR'
            Remove-Item $localPath -Force -ErrorAction SilentlyContinue
            Exit-WithRestore 14 'SHA512 校验失败（安装包损坏，已删除，请重跑）'
        }
    } catch {
        Write-Log ('SHA512 校验异常: ' + $_.Exception.Message) 'WARN'
    }
} else {
    Write-Log '探测模式无 SHA512，改用签名校验'
}

# 2.3 签名
try {
    $sig = Get-AuthenticodeSignature $localPath
    Write-Log ('数字签名: ' + $sig.Status)
    if ($sig.SignerCertificate) { Write-Log ('签发者: ' + $sig.SignerCertificate.Subject.Split(',')[0]) }
    if ($sig.Status -ne 'Valid') {
        Write-Log '签名无效！请确认来源，5 秒后继续' 'WARN'
        Start-Sleep -Seconds 5
    }
} catch { Write-Log '签名检查失败（忽略）' 'WARN' }

# ===================== 阶段3：清理 =====================
New-Section '阶段3 / 清理进程与干扰项'

# 【v4 新增·致命修复】先判断自己是不是 DSH 的子进程；是则改用独立计划任务继续。
# 只有真正要杀进程时才需要，DryRun / 已是最新 都已经在更早处 exit 了。
if (-not $env:DSH_UPGRADE_DETACHED) {
    if (Test-InDshTree -ProcessId $PID) {
        $argsForChild = ''
        if ($Force) { $argsForChild += ' -Force' }
        if ($Silent) { $argsForChild += ' -Silent' }
        if ($NoStart) { $argsForChild += ' -NoStart' }
        if ($ProbeLatest) { $argsForChild += ' -ProbeLatest' }
        $childScript = $PSCommandPath
        if (-not $childScript) { $childScript = $MyInvocation.MyCommand.Path }
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $taskName = 'DSH-AutoUpgrade-Elevated'
        $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $childScript + '" -DetachedChild' + $argsForChild
        $act = '"' + $psExe + '" ' + $argLine

        Write-Log '【关键保护】检测到本脚本运行在 DSH 进程树内。' 'WARN'
        Write-Log '  若此处置强杀 DSH，本脚本会被连带杀死，升级中断在半途、DSH 停在半装状态。' 'WARN'
        Write-Log '  → 自动改用「独立计划任务」执行安装，彻底脱离 DSH 进程树。' 'OK'

        & schtasks /Delete /TN $taskName /F 2>&1 | Out-Null
        & schtasks /Create /TN $taskName /TR $act /SC ONCE /ST 23:59 /RU "$env:USERNAME" /RL HIGHEST /F 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            # 【v4.1】脱离前先释放本进程持有的互斥锁，否则子进程拿不到锁会直接退出(21)。
            if ($script:UpgradeMutex) {
                try { $script:UpgradeMutex.ReleaseMutex() } catch {}
                try { $script:UpgradeMutex.Dispose() } catch {}
                $script:UpgradeMutex = $null
                Remove-Item Env:\DSH_UPGRADE_MUTEX_HELD -ErrorAction SilentlyContinue
                Write-Log '已释放单实例锁，交给独立子进程'
            }
            Write-Log ('已创建独立任务: ' + $taskName)
            & schtasks /Run /TN $taskName 2>&1 | Out-Null
            Write-Log '已在独立会话中开始升级，本窗口保持观察（不会自己动手杀 DSH）...'
            Write-Log ('升级进度日志: ' + $LogFile)

            $t0 = Get-Date
            $seenRunning = $false
            while (((Get-Date) - $t0).TotalMinutes -lt 25) {
                Start-Sleep -Seconds 4
                $q = & schtasks /Query /TN $taskName /FO LIST /V 2>&1 | Out-String
                if ($q -match 'Status:\s*Running') { $seenRunning = $true; continue }
                if ($seenRunning -and $q -notmatch 'Status:\s*Running') { break }
            }
            $res = & schtasks /Query /TN $taskName /FO LIST /V 2>&1 | Out-String
            $lastResult = 'unknown'
            if ($res -match 'Last Result:\s*(-?\d+)') { $lastResult = $Matches[1] }
            & schtasks /Delete /TN $taskName /F 2>&1 | Out-Null

            Write-Log ('独立升级任务已结束，LastResult=' + $lastResult)
            New-Section '汇总（由独立任务执行）'
            foreach ($pd in $ProtectedData) {
                if (Test-Path $pd) { Write-Log ('  数据完好: ' + $pd) 'OK' }
                else { Write-Log ('  不存在(可能原本就没有): ' + $pd) 'WARN' }
            }
            Write-Log '############################################################'
            Write-Host ''
            Write-Host '升级已由独立任务执行完毕。请查看上方日志与 DSH 是否正常。' -ForegroundColor Green
            exit $(if ($lastResult -eq '0') { 0 } else { 5 })
        }
        Write-Log '创建独立任务失败，退化为原地执行（有中断风险）' 'ERROR'
    }
}

foreach ($taskName in @('DSH-RESTART')) {
    try {
        $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($t) { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue; Write-Log ('已停计划任务: ' + $taskName) 'OK' }
    } catch {}
}

try {
    $helpers = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'dsh-launch|restart-body|restart-dsh|restart-and-measure' })
    foreach ($hp in $helpers) {
        try { Stop-Process -Id $hp.ProcessId -Force -ErrorAction Stop; Write-Log ('已结束启动器 PID=' + $hp.ProcessId) 'OK' } catch {}
    }
} catch {}

$round = 0
do {
    $round++
    $procList = Get-DshProcesses
    if ($procList.Count -eq 0) { break }
    Write-Log ('第 ' + $round + ' 轮结束进程: ' + $procList.Count + ' 个')
    foreach ($p in $procList) { try { $p.Kill() } catch {} }
    Start-Sleep -Seconds 2
} while ($round -lt $MaxKillRounds)

$left = Get-DshProcesses
Write-Log ('清理后剩余: ' + $left.Count)
if ($left.Count -gt 0) {
    foreach ($p in $left) { Write-Log ('  残留 PID=' + $p.Id) 'ERROR' }
    Exit-WithRestore 20 '进程无法结束，请手动结束后重试'
}
Write-Log '所有 DSH 进程已结束' 'OK'
Start-Sleep -Seconds 2

# ===================== 阶段3.5：备份（回滚基础） =====================
New-Section '阶段3.5 / 升级前备份（回滚用）'

Write-Log '数据保护：本次升级【不会】触碰以下路径（只备份程序目录 + 3 个配置文件）'
foreach ($pd in $ProtectedData) { Write-Log ('  受保护: ' + $pd) }

$backupPath = Backup-Installation -VersionTag $current
if (-not $backupPath) {
    Exit-WithRestore 15 '升级前备份失败，为避免不可回滚已中止（这是保护措施）'
}
Write-Log ('备份就绪，可用于回滚: ' + $backupPath) 'OK'
Write-Log '--- 备份阶段完成，继续升级 ---'
Start-Sleep -Seconds 1

# ===================== 阶段4：门禁 =====================
New-Section '阶段4 / 验证安装目录可改名'

$parent = Split-Path $InstallDir -Parent
$leaf = Split-Path $InstallDir -Leaf
$probeName = $leaf + '.upgrade-probe'
$probePath = Join-Path $parent $probeName

$renameOk = $false
for ($try = 1; $try -le $MaxRenameTries; $try++) {
    try {
        if (Test-Path $probePath) { Remove-Item $probePath -Recurse -Force -ErrorAction SilentlyContinue }
        Rename-Item -LiteralPath $InstallDir -NewName $probeName -ErrorAction Stop
        Rename-Item -LiteralPath $probePath -NewName $leaf -ErrorAction Stop
        $renameOk = $true
        Write-Log ('第 ' + $try + ' 次验证: 可改名 ✅') 'OK'
        break
    } catch {
        Write-Log ('第 ' + $try + ' 次验证失败: ' + $_.Exception.Message) 'WARN'
        if ($try -lt $MaxRenameTries) {
            Start-Sleep -Seconds 3
            Get-DshProcesses | ForEach-Object { try { $_.Kill() } catch {} }
            Start-Sleep -Seconds 1
        }
    }
}

if (-not $renameOk) {
    Write-Log '目录仍被占用，列出可能占用者：' 'ERROR'
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
            $hit = ($_.ExecutablePath -and ($_.ExecutablePath -like ($InstallDir + '*'))) -or
                   ($_.CommandLine -and ($_.CommandLine -like ('*' + $InstallDir + '*')))
            if ($hit) { Write-Log ('  PID=' + $_.ProcessId + ' ' + $_.Name) 'ERROR' }
        }
    } catch {}
    Exit-WithRestore 30 '安装目录被占用（关闭资源管理器/杀软，或重启后立刻运行）'
}

# 【v4 修复】原来只清 .old-*，但本机实测安装器还会留下 .new-*（解压失败时）
# 和 .broken-*（回滚时留的证据目录），这些每个都占 1GB+，堆几个就吃满空间。
# 【v4.1 修正】.broken-* 是回滚失败时的故障现场，全删会丢掉排错依据：
# 改为「保留最近 1 个 .broken-，其余清理」，兼顾空间与可诊断性。
# 【v4.10 修复】残留目录里可能有文件名损坏（实测 4669 个文件里有一个路径
# 含非法名 "pagepanenoselmaster.xml"，Remove-Item 报「未能找到路径的一部分」
# 直接失败），导致 498 MB 垃圾永远删不掉。
# 兜底方案：用 robocopy 拿一个空目录 /MIR 镜像过去（会把目标清空），
# 再删空壳。这是 Windows 上删「删不掉的目录」的标准做法。

$stalePatterns = @('.old-', '.new-', '.upgrade-probe')
$cleanedAny = 0
foreach ($pat in $stalePatterns) {
    $staleDirs = @(Get-ChildItem $parent -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match ('^' + [regex]::Escape($leaf) + [regex]::Escape($pat)) })
    foreach ($od in $staleDirs) {
        $szMB = [math]::Round(((Get-ChildItem $od.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB), 1)
        if (Remove-DirRobust -Path $od.FullName) {
            Write-Log ('已删残留: ' + $od.Name + ' (' + $szMB + ' MB)') 'OK'
            $cleanedAny++
        } else {
            Write-Log ('残留删除失败（已尝试 robocopy 兜底）: ' + $od.Name + ' (' + $szMB + ' MB)') 'WARN'
        }
    }
}
# .broken-* 单独处理：留最近 1 个作故障现场
$brokenDirs = @(Get-ChildItem $parent -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match ('^' + [regex]::Escape($leaf) + [regex]::Escape('.broken-')) } |
    Sort-Object LastWriteTime -Descending)
if ($brokenDirs.Count -gt 0) {
    Write-Log ('发现 ' + $brokenDirs.Count + ' 个 .broken- 故障现场，保留最近 1 个用于排错:') 'WARN'
    Write-Log ('  保留: ' + $brokenDirs[0].Name)
    foreach ($bd in ($brokenDirs | Select-Object -Skip 1)) {
        $szMB = [math]::Round(((Get-ChildItem $bd.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB), 1)
        if (Remove-DirRobust -Path $bd.FullName) {
            Write-Log ('  已删旧现场: ' + $bd.Name + ' (' + $szMB + ' MB)') 'OK'
            $cleanedAny++
        } else {
            Write-Log ('  删除失败（已尝试 robocopy 兜底）: ' + $bd.Name) 'WARN'
        }
    }
}
if ($cleanedAny -eq 0) { Write-Log '无旧残留需要清理' }

# ===================== 阶段5：安装 =====================
New-Section '阶段5 / 安装'

$swInst = [System.Diagnostics.Stopwatch]::StartNew()
$installOk = $false
for ($it = 1; $it -le 2; $it++) {
    Write-Log ('--- 安装尝试 ' + $it + '/2 ---')
    try {
        $proc = if ($Silent) { Start-Process -FilePath $localPath -ArgumentList '/S' -PassThru -ErrorAction Stop }
                else { Start-Process -FilePath $localPath -PassThru -ErrorAction Stop }
        Write-Log ('安装器 PID=' + $proc.Id + '，等待退出（上限 ' + $InstallerTimeoutMin + ' 分钟）')
        $finished = $proc.WaitForExit($InstallerTimeoutMin * 60 * 1000)
        if ($finished) {
            Write-Log ('安装器退出码: ' + $proc.ExitCode + '，耗时 ' + [math]::Round($swInst.Elapsed.TotalSeconds) + 's')
            if ($proc.ExitCode -eq 0) { $installOk = $true }
        } else {
            Write-Log '安装器超时' 'WARN'
            # 【v4.6 修复·严重】超时后必须强制清理，否则半装目录会让后续重试继续失败。
            # 实测（2026-11-13 虚拟机）：第 2 次安装 180 秒超时后未清理任何东西，
            # 安装目录停在半损坏状态，最终版本被降级到 rc.1。
            Write-Log '  强制结束安装器进程并清理半装残留...' 'WARN'
            # 1) 杀掉本次安装器进程
            try {
                if ($proc -and -not $proc.HasExited) { $proc.Kill() }
            } catch {}
            # 2) 杀掉同目录可能残留的安装器进程（NSIS 常会留下子进程）
            try {
                $instName = [IO.Path]::GetFileNameWithoutExtension($localPath)
                Get-Process -ErrorAction SilentlyContinue |
                    Where-Object { $_.ProcessName -eq $instName } |
                    ForEach-Object {
                        Write-Log ('  结束残留安装进程 PID=' + $_.Id) 'WARN'
                        try { $_.Kill() } catch {}
                    }
            } catch {}
            Start-Sleep -Seconds 3
            # 3) 清理本次产生的 .new-/.tmp- 残留（绝不碰正式安装目录）
            foreach ($pat in @('.new-', '.tmp-', '.upgrade-probe')) {
                @(Get-ChildItem $parent -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match ('^' + [regex]::Escape($leaf) + [regex]::Escape($pat)) }) |
                    ForEach-Object {
                        try { Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop; Write-Log ('  已清理残留: ' + $_.Name) 'WARN' } catch {}
                    }
            }
            # 4) 检查 exe 是否还在，判断目录是否被打坏
            if (-not (Test-Path (Join-Path $InstallDir 'DeepSeek Harness.exe'))) {
                Write-Log '  严重: 安装目录里 exe 已丢失，继续重试风险高' 'ERROR'
            }
            $swInst.Restart()
        }
    } catch {
        Write-Log ('安装器启动失败: ' + $_.Exception.Message) 'ERROR'
    }
    Start-Sleep -Seconds 3
    $vNow = Get-InstalledVersion
    # 【v4.9 修复·致命】$target 是【对象】（含 Version/Source/Url 属性），不是字符串。
    # v4.8 误写成 Compare-SemVer $vNow $target，传进去的对象被 Split-SemVer 当成
    # 空版本处理 => 永远返回 -1 => 版本明明已达目标却判「未达到」，白跑第二次安装。
    # 修复：所有比较一律用 $target.Version。
    $reachedTarget = ($installOk -and $vNow -and $target -and ((Compare-SemVer $vNow $target.Version) -eq 0))
    if ($reachedTarget) {
        if ((Compare-SemVer $target.Version $current) -gt 0) {
            Write-Log ('版本已变为 ' + $vNow) 'OK'
        } elseif ((Compare-SemVer $target.Version $current) -eq 0) {
            Write-Log ('强制重装完成，版本保持 ' + $vNow + '（这是预期结果）') 'OK'
        } else {
            Write-Log ('强制降级完成: ' + $current + ' -> ' + $vNow + '（-Force 允许降级，这是预期结果）') 'OK'
        }
        break
    }
    if ($it -lt 2) {
        Write-Log ('版本未达到目标（当前 ' + $(if($vNow){$vNow}else{'未知'}) + '，目标 ' + $target.Version + '），清理后重试一次...') 'WARN'
        Get-DshProcesses | ForEach-Object { try { $_.Kill() } catch {} }
        Start-Sleep -Seconds 4
        @(Get-ChildItem $parent -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match ('^' + [regex]::Escape($leaf) + '\.old-') }) |
            ForEach-Object { try { Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop } catch {} }
    }
}

# ===================== 阶段6：核验 =====================
New-Section '阶段6 / 核验'

# 【v4 新增】记录安装完成时刻，供阶段7 健康检查只统计"升级之后"的崩溃。
$installFinishedAt = Get-Date
$pass = $true
$verAfter = Get-InstalledVersion
Write-Log ('升级前: ' + $current)
Write-Log ('升级后: ' + $verAfter)

if (-not $verAfter) { Write-Log 'exe 不存在' 'ERROR'; $pass = $false }
elseif ($target -and ((Compare-SemVer $verAfter $target.Version) -eq 0)) {
    # 【v4.9 修复】核验标准改为「装完后版本 == $target.Version」，
    # 覆盖升级 / 同版本重装 / -Force 降级三种情况。
    if ((Compare-SemVer $target.Version $current) -gt 0) {
        Write-Log ('版本变化: ' + $current + ' -> ' + $verAfter) 'OK'
    } elseif ((Compare-SemVer $target.Version $current) -eq 0) {
        Write-Log ('强制重装完成：版本保持 ' + $verAfter + '（预期结果，非失败）') 'OK'
    } else {
        Write-Log ('强制降级完成: ' + $current + ' -> ' + $verAfter + '（-Force 允许降级，预期结果）') 'OK'
    }
}
elseif ($current -and ($verAfter -eq $current)) {
    Write-Log ('版本未达到目标：仍是 ' + $verAfter + '，目标 ' + $target.Version) 'ERROR'; $pass = $false
}
else { Write-Log ('版本变化但未达目标: ' + $current + ' -> ' + $verAfter + '，目标 ' + $target.Version) 'WARN' }

$asar = Join-Path $InstallDir 'resources\app.asar'
if (Test-Path $asar) { Write-Log ('app.asar: ' + [math]::Round((Get-Item $asar).Length / 1MB, 1) + ' MB') 'OK' }
else { Write-Log 'app.asar 缺失' 'ERROR'; $pass = $false }

try {
    $logDir = Join-Path $env:APPDATA '@deepseek-ai\dsh-desktop\logs'
    $cut = (Get-Date).AddMinutes(-15)
    $crashes = @(Get-ChildItem $logDir -Filter 'crash-*' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $cut })
    if ($crashes.Count -eq 0) { Write-Log '无新崩溃' 'OK' }
    else { foreach ($c in $crashes) { Write-Log ('崩溃日志: ' + $c.Name) 'WARN' } }
} catch {}

if (Test-Path (Join-Path $ProfileDir 'package.json')) {
    try {
        $pj = Get-Content (Join-Path $ProfileDir 'package.json') -Raw | ConvertFrom-Json
        Write-Log ('profile 保留: bundles=' + $pj.dsh.profile.bundles.Count) 'OK'
    } catch {}
}

try {
    $old = @(Get-ChildItem $DlDir -Filter '*.exe' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $localPath } | Sort-Object LastWriteTime -Descending)
    foreach ($o in $old) { Remove-Item $o.FullName -Force -ErrorAction SilentlyContinue; Write-Log ('清理旧下载: ' + $o.Name) }
} catch {}

# ===================== 阶段7：启动与健康检查 =====================
New-Section '阶段7 / 启动与健康检查'

Start-Dsh
$winElapsed = Wait-DshWindow -TimeoutSec 90
$healthy = $false

# 【v4.4 新增·虚拟机/无GPU环境修复】Web 服务健康探测
# 背景：2026-11-13 在 Hyper-V 虚拟机（Microsoft Hyper-V Video 虚拟显卡）实测发现：
#   Electron 在无真实 GPU 的环境下会自动降级为「Web 模式」运行 —— 服务正常、
#   能返回完整界面 HTML，但【不创建任何窗口】（EnumWindows 也查不到）。
#   此时 $winElapsed 永远是 -1，旧逻辑会误判为「启动失败」并触发自动回滚，
#   把一次成功的升级回滚掉。
# 修复：窗口没出来时，再查 DSH 是否以 Web 模式在跑（主进程监听本地端口且可访问），
#       若能访问则同样判定为健康。

if ($winElapsed -ge 0) {
    Write-Log ('主窗口已出现 ' + $winElapsed + 's') 'OK'
    # 检查致命崩溃（main / host）
    # 【v4 修复】原来只要 3 分钟内有 crash-*-main/host.log 就回滚，
    # 但本机实测存在「窗口已正常出现、却留下历史 host 崩溃记录」的情况（如插件报
    # CODEX_AUTH_REQUIRED 后 host 重启过一次）。窗口都起来了还被回滚，等于白升。
    # 改为：先看窗口，再只看「本次升级之后新产生」的崩溃，且要求是致命类型。
    $fatal = @()
    try {
        $logDir = Join-Path $env:APPDATA '@deepseek-ai\dsh-desktop\logs'
        $cut = $installFinishedAt
        if (Test-Path $logDir) {
            $fatal += @(Get-ChildItem $logDir -Filter 'crash-*-main.log' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $cut })
            $fatal += @(Get-ChildItem $logDir -Filter 'crash-*-host.log' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $cut })
        }
    } catch {}
    if ($fatal.Count -eq 0) {
        $healthy = $true
        Write-Log '健康检查通过（窗口正常 + 升级后无致命崩溃）' 'OK'
    } else {
        # 窗口已出现却仍有致命崩溃：再给 15 秒观察，确认 DSH 没有反复重启
        Write-Log ('检测到升级后致命崩溃日志 ' + $fatal.Count + ' 个，等待 15 秒确认是否反复崩溃...') 'WARN'
        Start-Sleep -Seconds 15
        $stillAlive = @(Get-DshProcesses | Where-Object { $_.MainWindowHandle -ne 0 })
        if ($stillAlive.Count -gt 0) {
            $healthy = $true
            Write-Log '窗口仍稳定存在，判定为可接受（崩溃发生在启动早期，已自恢复）' 'WARN'
            foreach ($f in $fatal) { Write-Log ('  参考: ' + $f.Name) 'WARN' }
        } else {
            Write-Log '窗口已消失，确认致命' 'ERROR'
        }
    }
} else {
    Write-Log '主窗口未在 90 秒内出现，改查 Web 服务模式（虚拟机/无GPU环境常见）...' 'WARN'
    $web = Test-DshWebAlive -TimeoutSec 40
    if ($web) {
        # Web 模式活着 => 再确认没有致命崩溃
        $fatalW = @()
        try {
            $logDirW = Join-Path $env:APPDATA '@deepseek-ai\dsh-desktop\logs'
            if (Test-Path $logDirW) {
                $fatalW += @(Get-ChildItem $logDirW -Filter 'crash-*-main.log' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $installFinishedAt })
                $fatalW += @(Get-ChildItem $logDirW -Filter 'crash-*-host.log' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $installFinishedAt })
            }
        } catch {}
        if ($fatalW.Count -eq 0) {
            $healthy = $true
            Write-Log ('健康检查通过（Web 模式运行，端口 ' + $web.Port + '，HTTP ' + $web.Status + '）') 'OK'
            Write-Log '说明：该环境无真实 GPU，Electron 自动降级为 Web 模式，服务正常运行。' 'WARN'
            Write-Log ('      用浏览器打开 http://127.0.0.1:' + $web.Port + '/ 即可使用。') 'WARN'
        } else {
            Write-Log ('Web 服务在跑，但检测到升级后致命崩溃 ' + $fatalW.Count + ' 个') 'WARN'
            foreach ($f in $fatalW) { Write-Log ('  参考: ' + $f.Name) 'WARN' }
        }
    } else {
        Write-Log '窗口和 Web 服务均未就绪，判定启动失败' 'ERROR'
    }
}

# ===================== 阶段8：失败自动回滚 =====================
$rolledBack = $false
$rollbackFailed = $false
if (-not $healthy) {
    Write-Log ''
    Write-Log '升级后健康检查未通过，启动自动回滚保护' 'ERROR'
    $rolledBack = Restore-FromBackup -BackupPath $backupPath
    if ($rolledBack) {
        $restoredVer = Get-InstalledVersion
        Write-Log ('已自动回滚到 ' + $restoredVer + '，功能恢复正常') 'OK'
        $verAfter = $restoredVer
        $pass = $false
    } else {
        Write-Log '自动回滚未成功，需要人工介入' 'ERROR'
        # 【v4.7 修复·致命】原来这里只打日志，没有把 $pass 置为 $false，
        # 导致汇总时 $pass 仍是阶段6 留下的 $true，最终输出「结果: 升级成功」+ 退出码 0
        # —— 回滚都失败了却报成功，这是最危险的假绿。
        # 修复：回滚失败必须 $pass=$false，并置 $rollbackFailed 标记，汇总时单独说明。
        $pass = $false
        $rollbackFailed = $true
        Write-Log ('备份目录: ' + $backupPath) 'WARN'
        Write-Log '手动恢复步骤：' 'WARN'
        Write-Log ('  1) 确认所有 DeepSeek Harness.exe 已结束') 'WARN'
        Write-Log ('  2) 删除/改名: ' + $InstallDir) 'WARN'
        Write-Log ('  3) 把 ' + $backupPath + ' 下所有文件（不含 _profile）复制到 ' + $InstallDir) 'WARN'
        Write-Log ('  4) 把 ' + (Join-Path $backupPath '_profile') + ' 下 3 个配置文件复制回 ' + $ProfileDir) 'WARN'
    }
} else {
    Write-Log '无需回滚' 'OK'
}

# 清理旧备份（保留最近 2 份）
try {
    $bks = @(Get-ChildItem $RollbackDir -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    foreach ($b in ($bks | Select-Object -Skip 2)) {
        Remove-Item $b.FullName -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log ('清理旧备份: ' + $b.Name)
    }
} catch {}

# ===================== 汇总 =====================
New-Section '汇总'
if ($rolledBack) {
    Write-Log ('结果   : 升级失败，已自动回滚到 ' + $verAfter) 'WARN'
} elseif ($rollbackFailed) {
    Write-Log '结果   : 升级失败，且自动回滚也失败，需要人工介入' 'ERROR'
} elseif ($pass) {
    Write-Log ('结果   : 升级成功') 'OK'
} else {
    Write-Log '结果   : 装完但有警告' 'WARN'
}
Write-Log ('版本   : ' + $current + ' -> ' + $verAfter)
Write-Log ('安装包 : ' + $localPath)
Write-Log ('来源   : ' + $target.Source + ' / ' + $target.Version)
Write-Log ('备份   : ' + $backupPath)
Write-Log ('日志   : ' + $LogFile)
Write-Log '--- 数据安全检查 ---'
foreach ($pd in $ProtectedData) {
    if (Test-Path $pd) { Write-Log ('  完好: ' + $pd) 'OK' }
    else { Write-Log ('  不存在(可能原本就没有): ' + $pd) 'WARN' }
}
Write-Log '############################################################'
Write-Host ''
if ($rolledBack) {
    Write-Host '升级失败，已自动回滚到升级前版本，数据完好可用。' -ForegroundColor Yellow
} elseif ($rollbackFailed) {
    Write-Host '升级失败，自动回滚也没成功！请按上面 4 步手动恢复，备份在:' -ForegroundColor Red
    Write-Host ('  ' + $backupPath) -ForegroundColor Red
} elseif ($pass) {
    Write-Host '升级完成，DSH 已启动。' -ForegroundColor Green
} else {
    Write-Host '升级完成但有警告，请看日志。' -ForegroundColor Yellow
}
if ($rolledBack) { exit 6 }
if ($rollbackFailed) { exit 7 }
exit $(if ($pass) { 0 } else { 5 })
