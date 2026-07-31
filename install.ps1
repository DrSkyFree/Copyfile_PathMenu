# install.ps1
# 安装"复制文件路径"右键菜单（无窗口 C++ 版）
# 用法：右键此文件 -> 使用 PowerShell 运行
$ErrorActionPreference = 'Stop'

$src = Join-Path $PSScriptRoot 'copy_path.exe'
if (-not (Test-Path -LiteralPath $src)) {
    Write-Host "找不到 copy_path.exe，请先编译或把 exe 放到同目录。" -ForegroundColor Red
    Read-Host "按回车退出"; exit 1
}

$destDir  = Join-Path $env:LOCALAPPDATA 'Programs\CopyFilePath'
$destExe  = Join-Path $destDir 'copy_path.exe'
$label    = '复制文件路径'
$cmdFile  = "`"$destExe`" `"%1`""
$cmdBg    = "`"$destExe`" `"%V`""

Write-Host "[1/4] 复制 exe 到 $destExe" -ForegroundColor Cyan
New-Item -ItemType Directory -Path $destDir -Force | Out-Null
Copy-Item -LiteralPath $src -Destination $destExe -Force

Write-Host "[2/4] 清理旧的 CopyFullPath（坏掉的 PowerShell 版）" -ForegroundColor Cyan
$oldKeys = @(
    'HKCU:\Software\Classes\*\shell\CopyFullPath',
    'HKCU:\Software\Classes\Directory\shell\CopyFullPath',
    'HKCU:\Software\Classes\Directory\Background\shell\CopyFullPath'
)
foreach ($k in $oldKeys) {
    if (Test-Path -LiteralPath $k) {
        Remove-Item -LiteralPath $k -Recurse -Force
        Write-Host "  已删除 $k"
    }
}

Write-Host "[3/4] 注册新的 CopyFilePath 菜单（HKCU，免管理员）" -ForegroundColor Cyan
function New-Menu($root, $cmd) {
    $base = "HKCU:\Software\Classes\$root\shell\CopyFilePath"
    New-Item -Path $base -Force | Out-Null
    Set-ItemProperty -LiteralPath $base -Name '(default)' -Value $label
    New-Item -Path "$base\command" -Force | Out-Null
    Set-ItemProperty -LiteralPath "$base\command" -Name '(default)' -Value $cmd
}
New-Menu '*'                    $cmdFile
New-Menu 'Directory'            $cmdFile
New-Menu 'Directory\Background' $cmdBg
Write-Host "  文件 / 文件夹 / 文件夹背景 均已注册"

Write-Host "[4/4] 通知资源管理器刷新" -ForegroundColor Cyan
$sig = @'
[DllImport("shell32.dll")]
public static extern void SHChangeNotify(int wEventId, int uFlags, IntPtr dwItem1, IntPtr dwItem2);
'@
$t = Add-Type -MemberDefinition $sig -Name 'ShellNotify' -Namespace 'WinAPI' -PassThru
$t::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)

Write-Host ""
Write-Host "完成！右键任意文件或文件夹 -> 「$label」即可复制路径。" -ForegroundColor Green
Write-Host "无 CMD 窗口、无延迟。卸载请运行 uninstall.ps1" -ForegroundColor DarkGray
Read-Host "按回车退出"
