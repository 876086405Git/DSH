# ============================================================
#  编码自检：确保 DSH-AutoUpgrade-v4.ps1 保持 UTF-8 BOM
#  背景：该 ps1 含中文，PowerShell 5.1 只在有 BOM 时才能正确
#        解码；若编辑器或 AI 工具改写时丢掉 BOM，中文会变乱码，
#        实测会产生 59 个语法错误，脚本完全跑不起来。
#  由「一键升级-v4.bat」在每次启动前调用。
# ============================================================
$ErrorActionPreference = 'Continue'

$target = $env:DSH_TARGET_PS1
if (-not $target) {
    $target = Join-Path $PSScriptRoot 'DSH-AutoUpgrade-v4.ps1'
}

if (-not (Test-Path -LiteralPath $target)) {
    Write-Host '[编码自检] 找不到主脚本，跳过检查' -ForegroundColor Yellow
    exit 0
}

# ---- 附加保护：解除「来自网络」的封锁标记 ----
# 从网上下载或从压缩包解压后，Windows 可能给文件打上 ZoneId=3。
# 本机实测即使带标记也能正常执行，这里顺手解除作兜底。
try {
    $unblocked = 0
    foreach ($f in @($target, (Join-Path $PSScriptRoot '一键升级-v4.bat'), (Join-Path $PSScriptRoot 'README-v4.md'))) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $hasZone = $false
        try { Get-Content -LiteralPath $f -Stream Zone.Identifier -ErrorAction Stop | Out-Null; $hasZone = $true } catch { }
        if ($hasZone) {
            try { Unblock-File -LiteralPath $f -ErrorAction Stop; $unblocked++ } catch { }
        }
    }
    if ($unblocked -gt 0) {
        Write-Host ("[编码自检] 已解除 $unblocked 个文件的网络封锁标记（不影响使用）") -ForegroundColor DarkGray
    }
} catch { }

try {
    $bytes = [System.IO.File]::ReadAllBytes($target)
    if ($bytes.Length -lt 3) {
        Write-Host '[编码自检] 文件过小，跳过' -ForegroundColor Yellow
        exit 0
    }

    $hasBom = ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)

    if ($hasBom) {
        Write-Host '[编码自检] 编码正常' -ForegroundColor DarkGray
        exit 0
    }

    # 缺 BOM -> 按 UTF-8 读全文，去掉残留 BOM 字符，再以带 BOM 的 UTF-8 写回
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $text = $text.TrimStart([char]0xFEFF)
    $utf8WithBom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($target, $text, $utf8WithBom)

    # 复检
    $after = [System.IO.File]::ReadAllBytes($target)
    $fixed = ($after[0] -eq 0xEF) -and ($after[1] -eq 0xBB) -and ($after[2] -eq 0xBF)
    if ($fixed) {
        Write-Host '[编码自检] 检测到编码丢失，已自动修复 —— 现在可以正常使用了' -ForegroundColor Yellow
        exit 0
    }
    Write-Host '[编码自检] 尝试修复但未成功，请联系维护者' -ForegroundColor Red
    exit 1
}
catch {
    Write-Host ('[编码自检] 检查过程出错，已跳过：' + $_.Exception.Message) -ForegroundColor Yellow
    exit 0
}
