# Build the Windows bridge end to end: C++ subprocess -> web remote -> Flutter
# desktop app, which bundles the first two (apps/bridge/windows/CMakeLists.txt).
# The Windows counterpart of scripts/build-bridge-mac.sh.
#
# Usage (from any directory):
#   powershell -ExecutionPolicy Bypass -File scripts\build-bridge-windows.ps1
#   ... -Zip        also write dist\Open-OBSBOT-Bridge-<ver>-windows-x64.zip
#   ... -Installer  also write dist\Open-OBSBOT-Bridge-Setup-<ver>-x64.exe
#                   (Inno Setup 6; apps\bridge\windows\installer\*.iss)
# Either writes dist\SHA256SUMS-<ver>.txt to publish alongside.
#
# Needs: Visual Studio 2022 (Build Tools is enough) with "Desktop development
# with C++", Flutter, Windows Developer Mode (Flutter plugin symlinks), and the
# OBSBOT SDK at third_party\obsbot-sdk\ including its windows\ directory.
# -Installer also needs Inno Setup 6 (https://jrsoftware.org/isdl.php).
param([switch]$Zip, [switch]$Installer)
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $root

if (-not (Test-Path 'third_party\obsbot-sdk\windows\win64-release\libdev.lib')) {
    throw 'OBSBOT SDK (windows\win64-release) not found under third_party\obsbot-sdk. See docs\GETTING_THE_SDK.md.'
}

# CMake ships with the VS C++ workload; find it through vswhere rather than
# requiring it on PATH.
$cmake = (Get-Command cmake -ErrorAction SilentlyContinue).Source
if (-not $cmake) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    # -all: while the VS installer is updating itself, vswhere reports the
    # instance as incomplete and hides it, though its tools still work.
    $vs = & $vswhere -all -products * -latest -property installationPath
    $cmake = if ($vs) { Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe' }
    if (-not $cmake -or -not (Test-Path $cmake)) {
        throw 'Visual Studio 2022 with "Desktop development with C++" (which includes CMake) is not installed.'
    }
}

Write-Host '==> building obsbot-bridge.exe'
& $cmake -S apps/bridge_cpp -B apps/bridge_cpp/build -G 'Visual Studio 17 2022' -A x64
if ($LASTEXITCODE) { throw 'cmake configure failed' }
& $cmake --build apps/bridge_cpp/build --config Release -j
if ($LASTEXITCODE) { throw 'cmake build failed' }

# A remote built from a different revision than its bridge connects, renders,
# and then never shows video (docs/LINUX.md). Always build it from this tree.
# --no-web-resources-cdn: CanvasKit must load offline (CLAUDE.md gotcha #49).
Write-Host '==> building the web remote'
Push-Location apps/rc
flutter build web --release --no-web-resources-cdn
if ($LASTEXITCODE) { Pop-Location; throw 'flutter build web failed' }
Pop-Location

Write-Host '==> building the bridge app'
Push-Location apps/bridge
flutter build windows --release
if ($LASTEXITCODE) { Pop-Location; throw 'flutter build windows failed' }
Pop-Location

$bundle = 'apps\bridge\build\windows\x64\runner\Release'

# App-local VC++ runtime. libdev.dll and the Flutter runner both import
# msvcp140 / vcruntime140(_1); a PC without the VC++ Redistributable would
# otherwise fail to start the bridge with a missing-DLL error. Microsoft.VC143.CRT
# is the folder Microsoft designates for exactly this kind of app-local copy.
$crt = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\*\VC\Redist\MSVC\*\x64\Microsoft.VC143.CRT",
                     "$env:ProgramFiles\Microsoft Visual Studio\2022\*\VC\Redist\MSVC\*\x64\Microsoft.VC143.CRT" -Directory -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1
if (-not $crt) { throw 'VC++ runtime (Microsoft.VC143.CRT) not found in the Visual Studio install.' }
Copy-Item "$($crt.FullName)\*.dll" $bundle -Force

foreach ($f in 'open_obsbot_bridge.exe', 'obsbot-bridge.exe', 'libdev.dll', 'vcruntime140.dll', 'msvcp140.dll', 'web\index.html') {
    if (-not (Test-Path (Join-Path $bundle $f))) { throw "bundle is missing $f" }
}
Write-Host "==> built $bundle"

$version = (Select-String -Path apps\bridge\pubspec.yaml -Pattern '^version:\s*([0-9.]+)').Matches[0].Groups[1].Value

if ($Zip) {
    New-Item -ItemType Directory -Force dist | Out-Null
    $out = "dist\Open-OBSBOT-Bridge-$version-windows-x64.zip"
    if (Test-Path $out) { Remove-Item $out }
    Compress-Archive -Path "$bundle\*" -DestinationPath $out
    Write-Host "==> wrote $out"
}

if ($Installer) {
    $iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $iscc) { throw 'Inno Setup 6 not found. Install it from https://jrsoftware.org/isdl.php' }
    New-Item -ItemType Directory -Force dist | Out-Null
    & $iscc /Q "/DAppVersion=$version" "/DBundleDir=$(Resolve-Path $bundle)" "/DOutputDir=$(Resolve-Path dist)" apps\bridge\windows\installer\open-obsbot-bridge.iss
    if ($LASTEXITCODE) { throw 'Inno Setup compile failed' }
    Write-Host "==> wrote dist\Open-OBSBOT-Bridge-Setup-$version-x64.exe"
}

if ($Zip -or $Installer) {
    # Unsigned builds: publish these next to the downloads so users can
    # check what they got.
    Get-ChildItem dist -File -Include *.zip, *.exe -Recurse | Where-Object { $_.Name -like "*$version*" } |
        ForEach-Object { "$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower())  $($_.Name)" } |
        Set-Content -Encoding ascii "dist\SHA256SUMS-$version.txt"
    Write-Host "==> wrote dist\SHA256SUMS-$version.txt"
}
