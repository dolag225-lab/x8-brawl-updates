# X8 Brawl installer without Inno Setup (11-06 fallback). Run Install.bat from the unzipped X8Brawl folder.
# Per-user, no admin: copies the game to %LOCALAPPDATA%\Programs\X8Brawl (or -Dest), keeps patches\ + .update\ +
# a changed update_source.txt on reinstall, makes Start menu shortcuts (+ desktop unless -NoDesktop), writes
# Uninstall.bat. Nothing is downloaded or run except the game itself at the end (unless -NoLaunch).
param([string]$Dest = (Join-Path $env:LOCALAPPDATA "Programs\X8Brawl"), [switch]$NoDesktop, [switch]$NoLaunch,
      [string]$StartMenu = (Join-Path ([Environment]::GetFolderPath("Programs")) "X8 Brawl"),
      [string]$Desktop = [Environment]::GetFolderPath("Desktop"), [switch]$Uninstall, [string]$SrcOverride = "")
$ErrorActionPreference = "Stop"
$Src = if ($SrcOverride) { (Resolve-Path -LiteralPath $SrcOverride).Path.TrimEnd('\') } else { $PSScriptRoot }
$sh = New-Object -ComObject WScript.Shell
function Link([string]$path, [string]$target, [string]$dir, [string]$icon, [int]$style = 1) {
    $l = $sh.CreateShortcut($path); $l.TargetPath = $target; $l.WorkingDirectory = $dir; $l.IconLocation = "$icon,0"; $l.WindowStyle = $style; $l.Save()
}
if ($Uninstall) {
    if (Get-Process X8Brawl -EA SilentlyContinue | Where-Object { try { $_.Path -like "$Src\*" } catch { $false } }) { Write-Host "Close X8 Brawl first." -F Red; Start-Sleep 5; exit 1 }
    $list = Join-Path $Src "shortcuts.txt"   # written at install: exactly the shortcuts + Start menu folder made
    if (Test-Path $list) { foreach ($l in Get-Content $list) { if ($l -and (Test-Path -LiteralPath $l)) { Remove-Item -LiteralPath $l -Recurse -Force } } }
    Write-Host "Removing $Src ..."
    Set-Location $env:USERPROFILE
    Remove-Item $Src -Recurse -Force
    Write-Host "X8 Brawl uninstalled." -F Green
    if ($PSCommandPath -like "*\x8brawl_uninstall.ps1") { Remove-Item -LiteralPath $PSCommandPath -Force -EA SilentlyContinue }
    exit 0
}
if (-not (Test-Path (Join-Path $Src "X8Brawl.exe"))) { Write-Host "Run this from the unzipped X8Brawl folder." -F Red; Start-Sleep 8; exit 1 }
if ($Src.TrimEnd('\') -ieq $Dest.TrimEnd('\')) { Write-Host "Already installed here." -F Yellow; exit 0 }
if (Get-Process X8Brawl -EA SilentlyContinue | Where-Object { try { $_.Path -like "$Dest\*" } catch { $false } }) { Write-Host "Close X8 Brawl first." -F Red; Start-Sleep 5; exit 1 }
Write-Host "Installing X8 Brawl to $Dest ..."
New-Item -ItemType Directory -Force $Dest | Out-Null
$skip = @("patches", ".update", "version.txt", "Install.bat")
$keepSource = Test-Path (Join-Path $Dest "update_source.txt")
foreach ($item in Get-ChildItem -LiteralPath $Src -Force) {
    if ($skip -contains $item.Name) { continue }
    if ($item.Name -eq "update_source.txt" -and $keepSource) { continue }
    Write-Host "  $($item.Name)"
    Copy-Item -LiteralPath $item.FullName -Destination $Dest -Recurse -Force
}
# Uninstall.bat in the install folder runs this script from a copy outside it (the folder is deleted)
$un = "@echo off`r`ncd /d `"%LOCALAPPDATA%`" & copy /y `"%~dp0install.ps1`" `"%LOCALAPPDATA%\x8brawl_uninstall.ps1`" >nul & powershell -NoProfile -ExecutionPolicy Bypass -File `"%LOCALAPPDATA%\x8brawl_uninstall.ps1`" -Uninstall -SrcOverride `"%~dp0.`" & pause & exit /b`r`n"
[IO.File]::WriteAllText((Join-Path $Dest "Uninstall.bat"), $un)
$exe = Join-Path $Dest "X8Brawl.exe"
New-Item -ItemType Directory -Force $StartMenu | Out-Null
Link "$StartMenu\X8 Brawl.lnk" (Join-Path $Dest "launch.bat") $Dest $exe 7
Link "$StartMenu\Update X8 Brawl.lnk" (Join-Path $Dest "Update.bat") $Dest $exe
Link "$StartMenu\Uninstall X8 Brawl.lnk" (Join-Path $Dest "Uninstall.bat") $Dest $exe
if (-not $NoDesktop) {
    New-Item -ItemType Directory -Force $Desktop | Out-Null
    Link "$Desktop\X8 Brawl.lnk" (Join-Path $Dest "launch.bat") $Dest $exe 7
    Link "$Desktop\Update X8 Brawl.lnk" (Join-Path $Dest "Update.bat") $Dest $exe
}
$made = @("$StartMenu\X8 Brawl.lnk", "$StartMenu\Update X8 Brawl.lnk", "$StartMenu\Uninstall X8 Brawl.lnk", $StartMenu)
if (-not $NoDesktop) { $made = @("$Desktop\X8 Brawl.lnk", "$Desktop\Update X8 Brawl.lnk") + $made }
[IO.File]::WriteAllLines((Join-Path $Dest "shortcuts.txt"), [string[]]$made)
Write-Host "Done. Start the game from the X8 Brawl shortcut (it updates itself first)." -F Green
if (-not $NoLaunch) { Start-Process -FilePath (Join-Path $Dest "launch.bat") -WorkingDirectory $Dest -WindowStyle Minimized }
