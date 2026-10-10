# CopyFilePath-Setup.ps1 - 「复制文件路径」右键菜单管理
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File .\CopyFilePath-Setup.ps1 [-Choice 0-5] [-RestartExplorer]
# 注册表始终写入 Explorer 所有者(登录用户)的 HKEY_USERS\<SID>\Software\Classes，任何运行身份均生效。
param(
    [ValidateSet('', '0', '1', '2', '3', '4', '5')]
    [string]$Choice = '',
    [switch]$RestartExplorer,
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { Start-Transcript -Path (Join-Path $env:LOCALAPPDATA 'CopyFilePath-Setup.log') -Append -ErrorAction Stop | Out-Null } catch {}

$interactive = [string]::IsNullOrEmpty($Choice)
$myIdentity  = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$isAdmin     = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$srcCpp      = Join-Path $PSScriptRoot 'copy_path.cpp'
$srcExe      = Join-Path $PSScriptRoot 'copy_path.exe'
$labelQuoted = '复制文件路径(带引号)'
$labelPlain  = '复制文件路径'
$builtinKey  = 'HKLM:\SOFTWARE\Classes\AllFilesystemObjects\shellex\ContextMenuHandlers\CopyAsPathMenu'
$builtinClsid = '{f3d06e7c-1e45-4a26-847e-f9fcdee59be0}'

# 目标用户 = Explorer 进程所有者（真正的交互登录用户）
function Get-TargetUser {
    $exp = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue |
        Sort-Object SessionId | Select-Object -First 1
    if ($exp) {
        $owner = Invoke-CimMethod -InputObject $exp -MethodName GetOwner -ErrorAction SilentlyContinue
        if ($owner -and $owner.User) {
            try {
                $sid = (New-Object System.Security.Principal.NTAccount($owner.Domain, $owner.User)).Translate([System.Security.Principal.SecurityIdentifier]).Value
                return @{ User = "$($owner.Domain)\$($owner.User)"; Sid = $sid }
            } catch {}
        }
    }
    $cur = [Security.Principal.WindowsIdentity]::GetCurrent()
    return @{ User = $cur.Name; Sid = $cur.User.Value }
}

$target        = Get-TargetUser
$targetSid     = $target.Sid
$targetUser    = $target.User
$targetRoot    = "Registry::HKEY_USERS\$targetSid"
$targetClasses = "$targetRoot\Software\Classes"
$targetIsMe    = ($myIdentity -eq $targetUser)

$ve = Get-ItemProperty -LiteralPath "$targetRoot\Volatile Environment" -ErrorAction SilentlyContinue
$targetLocalAppData = $ve.LOCALAPPDATA
if (-not $targetLocalAppData) { $targetLocalAppData = "C:\Users\$($targetUser.Split('\')[-1])\AppData\Local" }
$destDir = Join-Path $targetLocalAppData 'Programs\CopyFilePath'
$destExe = Join-Path $destDir 'copy_path.exe'

function Abort([string]$msg) {
    Write-Host "[失败] $msg" -ForegroundColor Red
    if ($interactive -or $Elevated) { Read-Host '按回车退出' | Out-Null }
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

# 缺少 exe 且无编译器：提示下载或自行编译，确认后退出
function Abort-MissingExe {
    Write-Host "[失败] 脚本目录缺少 copy_path.exe，且未找到 g++ 编译器，无法完成安装。" -ForegroundColor Red
    Write-Host "请任选其一，完成后重新运行本脚本:"
    Write-Host "  1) 下载 copy_path.exe 放到本脚本同目录: $PSScriptRoot"
    Write-Host "  2) 安装 MinGW-w64 (g++) 后在本目录编译:"
    Write-Host "     g++ -O2 -mwindows -municode -static -o copy_path.exe copy_path.cpp"
    if ($interactive) { Read-Host '按回车退出' | Out-Null }
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

function Open-TargetKey([string]$classesSub) {
    return [Microsoft.Win32.Registry]::Users.OpenSubKey("$targetSid\Software\Classes\$classesSub", $false)
}

function Remove-TargetClassesKey([string]$classesSub) {
    try {
        if ($null -ne (Open-TargetKey $classesSub)) {
            [Microsoft.Win32.Registry]::Users.DeleteSubKeyTree("$targetSid\Software\Classes\$classesSub")
        }
    } catch {}
    return ($null -eq (Open-TargetKey $classesSub))
}

function Remove-CurrentHiveKey([string]$classesSub) {
    try {
        if ($null -ne [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\Classes\$classesSub")) {
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree("Software\Classes\$classesSub")
        }
    } catch {}
}

function Remove-HKCRKey([string]$subPath) {
    $prov = "Registry::HKEY_CLASSES_ROOT\$subPath"
    if (-not (Test-Path -LiteralPath $prov)) { return }
    try { Remove-Item -LiteralPath $prov -Recurse -Force -ErrorAction Stop } catch {}
}

function Notify-Explorer {
    $t = Add-Type -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int wEventId, int uFlags, IntPtr dwItem1, IntPtr dwItem2);' -Name 'ShellNotify' -Namespace 'WinAPI' -PassThru
    $t::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
}

$cleanKeys = @(
    '*\shell\CopyFilePath', 'Directory\shell\CopyFilePath', 'Directory\Background\shell\CopyFilePath',
    '*\shell\CopyFilePathPlain', 'Directory\shell\CopyFilePathPlain', 'Directory\Background\shell\CopyFilePathPlain',
    '*\shell\CopyFullPath', 'Directory\shell\CopyFullPath', 'Directory\Background\shell\CopyFullPath',
    'AllFilesystemObjects\shell\CopyPathQuoted', 'AllFilesystemObjects\shell\CopyPathPlain', 'AllFilesystemObjects\shell\CopyAsPath'
)

function Clean-AllMenus([bool]$removeExe) {
    Write-Host "── 清理旧的「复制文件路径」菜单 ..." -ForegroundColor Cyan
    $removed = 0
    foreach ($k in $cleanKeys) {
        if ($null -ne (Open-TargetKey $k) -and (Remove-TargetClassesKey $k)) { $removed++ }
    }
    if (-not $targetIsMe) {
        foreach ($k in $cleanKeys) { Remove-CurrentHiveKey $k }
    }
    foreach ($k in 'AllFilesystemObjects\shell\CopyPathQuoted', 'AllFilesystemObjects\shell\CopyPathPlain', 'AllFilesystemObjects\shell\CopyAsPath') {
        Remove-HKCRKey $k
    }
    foreach ($d in @((Join-Path $env:LOCALAPPDATA 'CopyPathMenu'), (Join-Path $targetLocalAppData 'CopyPathMenu'))) {
        if ($d -and (Test-Path -LiteralPath $d)) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if ($removeExe -and (Test-Path -LiteralPath $destDir)) { Remove-Item -LiteralPath $destDir -Recurse -Force -ErrorAction SilentlyContinue }

    $leftover = @()
    foreach ($v in 'CopyFilePath', 'CopyFilePathPlain') {
        foreach ($r in '*', 'Directory', 'Directory\Background') {
            if ($null -ne (Open-TargetKey "$r\shell\$v")) { $leftover += "$r\shell\$v" }
        }
    }
    Notify-Explorer
    if ($leftover.Count) {
        Write-Host "  [警告] 仍有残留: $($leftover -join ', ')" -ForegroundColor Yellow
    } else {
        Write-Host "  [√] 清理完成，注册表中已无「复制文件路径」相关菜单" -ForegroundColor Green
    }
}

function Restart-ExplorerMenu {
    if (-not $targetIsMe) { return }
    if ($RestartExplorer) { $ans = 'y' }
    elseif ($interactive) { $ans = (Read-Host '是否立即重启资源管理器以刷新菜单？(y/N)').ToLower() }
    else { return }
    if ($ans -in 'y', 'yes') {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
        Write-Host "  资源管理器已重启" -ForegroundColor Green
    }
}

function Build-AndDeploy {
    $gpp = (Get-Command g++ -ErrorAction SilentlyContinue).Source
    if (-not $gpp) {
        $candidates = @(
            (Join-Path $targetLocalAppData 'Programs\mingw64\bin\g++.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\mingw64\bin\g++.exe'),
            'C:\mingw64\bin\g++.exe', 'C:\msys64\mingw64\bin\g++.exe', 'C:\msys64\ucrt64\bin\g++.exe',
            'C:\w64devkit\bin\g++.exe', 'C:\TDM-GCC-64\bin\g++.exe', 'C:\MinGW\bin\g++.exe',
            'C:\Strawberry\c\bin\g++.exe', 'D:\mingw64\bin\g++.exe', 'D:\msys64\mingw64\bin\g++.exe'
        )
        foreach ($t in 'C:\Qt\Tools', 'D:\Qt\Tools') {
            if (Test-Path $t) {
                $candidates += Get-ChildItem $t -Directory -Filter 'mingw*' -ErrorAction SilentlyContinue |
                    ForEach-Object { Join-Path $_.FullName 'bin\g++.exe' }
            }
        }
        foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { $gpp = $c; break } }
    }

    if ($gpp) {
        if (-not (Test-Path -LiteralPath $srcCpp)) { Abort "找不到源码 $srcCpp（本脚本须与 copy_path.cpp 放在同一目录）" }
        Write-Host "── 编译 copy_path.exe ..." -ForegroundColor Cyan
        $tmpOut = Join-Path ([System.IO.Path]::GetTempPath()) ("copy_path_" + [Guid]::NewGuid().ToString('N') + '.exe')
        & $gpp -O2 -mwindows -municode -static -o "$tmpOut" "$srcCpp"
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmpOut)) {
            if (Test-Path -LiteralPath $tmpOut) { Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue }
            Abort "g++ 编译失败（退出码 $LASTEXITCODE）"
        }
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        Copy-Item -LiteralPath $tmpOut -Destination $destExe -Force
        Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
    } elseif (Test-Path -LiteralPath $srcExe) {
        Write-Host "── 未找到 g++，使用脚本目录的 copy_path.exe ..." -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        Copy-Item -LiteralPath $srcExe -Destination $destExe -Force
    } elseif (Test-Path -LiteralPath $destExe) {
        Write-Host "── 未找到 g++，复用已部署的 copy_path.exe ..." -ForegroundColor Yellow
    } else {
        Abort-MissingExe
    }
    Write-Host "  已部署 $destExe"
}

function New-Menu([string]$root, [string]$verb, [string]$label, [string]$cmd) {
    $rel = "Software\Classes\$root\shell\$verb"
    $k = [Microsoft.Win32.Registry]::Users.CreateSubKey("$targetSid\$rel")
    $k.SetValue('', $label)
    $kc = [Microsoft.Win32.Registry]::Users.CreateSubKey("$targetSid\$rel\command")
    $kc.SetValue('', $cmd)
    $k.Close(); $kc.Close()
}

function Add-Menus([bool]$quoted, [bool]$plain) {
    $roots = @('*', 'Directory', 'Directory\Background')
    if ($quoted) {
        foreach ($r in $roots) {
            $c = if ($r -eq 'Directory\Background') { "`"$destExe`" -q `"%V`"" } else { "`"$destExe`" -q `"%1`"" }
            New-Menu $r 'CopyFilePath' $labelQuoted $c
        }
    }
    if ($plain) {
        foreach ($r in $roots) {
            $c = if ($r -eq 'Directory\Background') { "`"$destExe`" `"%V`"" } else { "`"$destExe`" `"%1`"" }
            New-Menu $r 'CopyFilePathPlain' $labelPlain $c
        }
    }
    $verbs = @(); if ($quoted) { $verbs += 'CopyFilePath' }; if ($plain) { $verbs += 'CopyFilePathPlain' }
    $allOk = $true
    foreach ($v in $verbs) {
        foreach ($r in $roots) {
            if (Test-Path -LiteralPath "$targetClasses\$r\shell\$v\command") { Write-Host "  [√] $r\shell\$v" -ForegroundColor Green }
            else { $allOk = $false; Write-Host "  [×] $r\shell\$v 注册失败！" -ForegroundColor Red }
        }
    }
    if (-not $allOk) { Write-Host "  [警告] 部分菜单注册失败，详见日志" -ForegroundColor Yellow }
}

function Remove-BuiltinCopyAsPath {
    Write-Host "── 移除 Windows 11 自带「复制文件地址(A)」..." -ForegroundColor Cyan
    if (-not $isAdmin) {
        $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Choice 5 -Elevated"
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
        return
    }
    if (Test-Path -LiteralPath $builtinKey) {
        Remove-Item -LiteralPath $builtinKey -Recurse -Force -ErrorAction Stop
        Notify-Explorer
        Write-Host "  [√] 已删除（恢复: reg add `"$builtinKey`" /ve /d `"$builtinClsid`" /f）" -ForegroundColor Green
    } else {
        Write-Host "  该项不存在（可能已移除）" -ForegroundColor Green
    }
}

function Invoke-Choice([string]$c) {
    switch ($c) {
        '1' {
            Clean-AllMenus -removeExe $true
            Restart-ExplorerMenu
        }
        { $_ -in '2', '3', '4' } {
            Clean-AllMenus -removeExe $false
            Build-AndDeploy
            Write-Host "── 注册右键菜单（目标用户: $targetUser）..." -ForegroundColor Cyan
            Add-Menus -quoted ($c -in '2', '4') -plain ($c -in '3', '4')
            Notify-Explorer
            Restart-ExplorerMenu
            Write-Host "完成！右键任意文件 / 文件夹 / 空白处即可使用。" -ForegroundColor Green
        }
        '5' {
            Remove-BuiltinCopyAsPath
            if ($Elevated) { Read-Host '按回车退出' | Out-Null }
        }
    }
}

if ($interactive -and -not $Elevated) {
    do {
        Write-Host "---- 右键菜单「复制文件路径」管理 ----"
        Write-Host "  1. 彻底清理「$labelQuoted」和「$labelPlain」及旧版残留"
        Write-Host "  2. 添加「$labelQuoted」  例: `"D:\folder\file.txt`""
        Write-Host "  3. 添加「$labelPlain」    例: D:\folder\file.txt"
        Write-Host "  4. 两个都添加"
        Write-Host "  5. 移除 Win11 自带「复制文件地址(A)」（需管理员）"
        Write-Host "  0. 退出"
        do {
            $Choice = Read-Host '请选择 [1/2/3/4/5/0]'
        } while ($Choice -notin @('0', '1', '2', '3', '4', '5'))
        Write-Host ""
        Invoke-Choice $Choice
        Write-Host ""
    } until ($Choice -eq '0')
} else {
    if (-not $Choice) { $Choice = '0' }
    Invoke-Choice $Choice
}

try { Stop-Transcript | Out-Null } catch {}
