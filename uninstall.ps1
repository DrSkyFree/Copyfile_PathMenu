# uninstall.ps1
# 卸载"复制文件路径"右键菜单
# 用法：右键此文件 -> 使用 PowerShell 运行
$ErrorActionPreference = 'Stop'

Write-Host "[1/2] 删除注册表菜单项" -ForegroundColor Cyan
$keys = @(
    'HKCU:\Software\Classes\*\shell\CopyFilePath',
    'HKCU:\Software\Classes\Directory\shell\CopyFilePath',
    'HKCU:\Software\Classes\Directory\Background\shell\CopyFilePath'
)
foreach ($k in $keys) {
    if (Test-Path -LiteralPath $k) {
        Remove-Item -LiteralPath $k -Recurse -Force
        Write-Host "  已删除 $k"
    } else {
        Write-Host "  不存在 $k"
    }
}

Write-Host "[2/2] 删除 exe 文件" -ForegroundColor Cyan
$destDir = Join-Path $env:LOCALAPPDATA 'Programs\CopyFilePath'
if (Test-Path -LiteralPath $destDir) {
    Remove-Item -LiteralPath $destDir -Recurse -Force
    Write-Host "  已删除 $destDir"
}

$sig = @'
[DllImport("shell32.dll")]
public static extern void SHChangeNotify(int wEventId, int uFlags, IntPtr dwItem1, IntPtr dwItem2);
'@
$t = Add-Type -MemberDefinition $sig -Name 'ShellNotify2' -Namespace 'WinAPI' -PassThru
$t::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)

Write-Host ""
Write-Host "已卸载完成。" -ForegroundColor Green
Read-Host "按回车退出"
