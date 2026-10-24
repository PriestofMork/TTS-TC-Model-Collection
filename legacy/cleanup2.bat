<# : batch launcher (runs the PowerShell part below as admin)
@echo off
net session >nul 2>&1 || (powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" & exit /b)
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ((Get-Content -LiteralPath '%~f0' -Raw))"
echo.
pause
exit /b
#>

$ErrorActionPreference = 'SilentlyContinue'
$U  = $env:USERPROFILE
$dl = "$U\Downloads"; $dt = "$U\Desktop"
$LA = $env:LOCALAPPDATA; $RA = $env:APPDATA; $LL = "$U\AppData\LocalLow"
$free0 = (Get-PSDrive C).Free

function Del($p) {
  if (Test-Path -LiteralPath $p) {
    Remove-Item -LiteralPath $p -Recurse -Force
    Write-Host "  deleted  $p"
  }
}
function Empty($p) {  # clear a folder's contents, keep the folder
  if (Test-Path -LiteralPath $p) {
    Get-ChildItem -LiteralPath $p -Force | Remove-Item -Recurse -Force
    Write-Host "  emptied  $p"
  }
}

Write-Host "`n[1/7] Downloads and Desktop leftovers"
@(
 "$dl\UnitySetup64-6000.6.2f1.exe", "$dl\UnityHubSetup-x64.exe", "$dl\HexTrenchV2_folder.zip",
 "$dl\rock_boulder_dry_2k.zip", "$dl\sand_01_2k.zip", "$dl\seaside_rock_2k.zip", "$dl\brown_mud_03_2k.zip",
 "$dl\weathered_brown_planks_2k.zip", "$dl\cracked_red_ground_2k.zip",
 "$dl\hex_black5_height_folder.zip", "$dl\hex_black5_height.unitypackage",
 "$dl\look_mud_a.png", "$dl\look_mud_b.png", "$dl\look_sand_a.png", "$dl\look_sand_b.png",
 "$dl\~`$ench Crusade Formating Template.docx",
 "$dl\hex_trench_walls_wood", "$dl\cracked_red_ground_2k", "$dl\hex_black5_height_folder",
 "$dt\The death factories.zip", "$dt\death factory temp", "$dt\~WRD0004.tmp",
 "$dt\New Text Document.txt", "$dt\Firefox.exe"
) | ForEach-Object { Del $_ }
Get-ChildItem -LiteralPath "$U\Documents\My Games\Tabletop Simulator\Saves" -Filter '*.backup' | ForEach-Object { Del $_.FullName }

Write-Host "`n[2/7] Unused Unity editors (your tile project uses 6000.0.62f1, which stays)"
$u62 = 'C:\Program Files\Unity 6000.6.2f1'
if (Test-Path "$u62\Editor\Uninstall.exe") {
  Write-Host "  uninstalling Unity 6000.6.2f1 (takes a minute)..."
  Start-Process -FilePath "$u62\Editor\Uninstall.exe" -ArgumentList '/S', "_?=$u62\Editor" -Wait
}
Del $u62
Del 'C:\Program Files\Unity\Hub\Editor\6000.6.6f1'
Empty "$RA\UnityHub\downloads"

Write-Host "`n[3/7] GWENT"
if (Test-Path 'C:\Program Files (x86)\Steam\steamapps\common\GWENT The Witcher Card Game') {
  Write-Host "  Steam will ask you to confirm the GWENT uninstall."
  Start-Process 'steam://uninstall/1284410'
}
Del "$LA\Programs\CD Projekt Red"
Del "$LL\CDProjektRED"

Write-Host "`n[4/7] Old GIMP 3.0 (the Store GIMP 3.2 stays)"
$gu = "$LA\Programs\GIMP 3\uninst\unins000.exe"
if (Test-Path $gu) { Start-Process -FilePath $gu -ArgumentList '/VERYSILENT', '/NORESTART' -Wait; Start-Sleep 5 }
Del "$LA\Programs\GIMP 3"
Del "$dt\GIMP 3.0.6-1.lnk"

Write-Host "`n[5/7] Caches, temp files and uninstall leftovers"
Empty "$LA\Temp"
Empty "C:\Windows\Temp"
Empty "$LA\Unity\cache"
Empty "$LA\Steam\htmlcache"
Get-ChildItem "$LA\EpicGamesLauncher\Saved" -Directory -Filter 'webcache*' | ForEach-Object { Del $_.FullName }
Empty "C:\ProgramData\GOG.com\Galaxy\webcache"
Empty "C:\ProgramData\GOG.com\Galaxy\logs"
Del "$LA\AviraWebView2Cache"
Del "C:\Windows\System32\Tasks\Avira"
Empty "C:\Windows\SoftwareDistribution\Download"
Empty "C:\Windows\Logs\CBS"
Get-ChildItem "$LA\CrashDumps", "C:\Windows\Minidump" -Force | Remove-Item -Force
if (-not (Get-Process Discord)) { Empty "$RA\discord\Cache"; Empty "$RA\discord\Code Cache" }

Write-Host "`n[6/7] Windows Update leftovers (DISM, can take 5-15 minutes, don't close)"
Dism.exe /Online /Cleanup-Image /StartComponentCleanup /Quiet /NoRestart

Write-Host "`n[7/7] Emptying the Recycle Bin"
Clear-RecycleBin -DriveLetter C -Force

$freed = ((Get-PSDrive C).Free - $free0) / 1GB
Write-Host ("`nDone. Freed about {0:N1} GB. Free now: {1:N1} GB" -f $freed, ((Get-PSDrive C).Free / 1GB))
Write-Host "If Steam showed a GWENT prompt, its space is freed once you confirm it."
