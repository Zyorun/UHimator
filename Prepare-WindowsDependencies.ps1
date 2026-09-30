<#
Prepare versioned dependency files on Windows. The GitHub workflow supplies
VS 2022, MFC, CMake, .NET 8, CPython 3.11 and Perl through its Windows runner.
Qt is built from source with a static runtime and Windows Schannel TLS.
No account credentials, administrator access or machine policy changes needed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DevDir,
    [ValidateRange(1,8)][int]$Threads = 2
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'Windows x64 is required.' }
foreach ($Tool in @('cl.exe','perl.exe','curl.exe','tar.exe')) {
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) { throw "Required tool missing: $Tool" }
}
New-Item -ItemType Directory -Path $DevDir -Force | Out-Null
$DevDir = (Resolve-Path -LiteralPath $DevDir).Path
$Downloads = Join-Path $DevDir 'downloads'
New-Item -ItemType Directory -Path $Downloads -Force | Out-Null
$DownloadRecords = [System.Collections.Generic.List[object]]::new()

function Invoke-Native([string]$File, [string[]]$Arguments) {
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $File" }
}

function Get-Package([string]$Name, [string[]]$Uri, [string]$Sha256 = '') {
    $Destination = Join-Path $Downloads $Name
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        $Partial = "$Destination.partial"
        $Done = $false
        foreach ($Candidate in $Uri) {
            Write-Host "Downloading $Name from $Candidate"
            Remove-Item -LiteralPath $Partial -Force -ErrorAction SilentlyContinue
            # A stalled server (under 20 KB/s for 45 s) is abandoned instead of hanging for 30 minutes.
            & curl.exe --fail --location --retry 2 --retry-delay 3 --connect-timeout 20 `
                --speed-limit 20000 --speed-time 45 --max-time 900 --silent --show-error `
                --output $Partial $Candidate
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Partial)) { $Done = $true; break }
            Write-Host "Mirror failed (curl exit $LASTEXITCODE), trying the next one."
        }
        if (-not $Done) { throw "Could not download $Name from any mirror." }
        Move-Item -LiteralPath $Partial -Destination $Destination -Force
        Write-Host ("Downloaded {0} ({1:N1} MB)" -f $Name, ((Get-Item -LiteralPath $Destination).Length / 1MB))
    }
    $ActualHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Sha256 -and $ActualHash -ne $Sha256.ToLowerInvariant()) {
        throw "SHA-256 mismatch for $Name. Delete the cached download and retry."
    }
    $DownloadRecords.Add([ordered]@{
        name=$Name; url=($Uri -join ' | '); sha256=$ActualHash; upstream_hash_checked=[bool]$Sha256
        bytes=(Get-Item -LiteralPath $Destination).Length
    })
    $DownloadRecords | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $DevDir 'DOWNLOADS.json') -Encoding UTF8
    return $Destination
}

# tar.exe on the runner can resolve to a different tar (Git/MSYS) and hang on .tar.xz, so 7-Zip does the extraction.
function Find-SevenZip {
    foreach ($Candidate in @('C:\Program Files\7-Zip\7z.exe','C:\Program Files (x86)\7-Zip\7z.exe')) {
        if (Test-Path -LiteralPath $Candidate -PathType Leaf) { return $Candidate }
    }
    $Found = Get-Command '7z.exe' -ErrorAction SilentlyContinue
    if ($Found) { return $Found.Source }
    return $null
}

function Expand-Archive7z([string]$Archive, [string]$Destination) {
    $SevenZip = Find-SevenZip
    Write-Host "Extracting $(Split-Path -Leaf $Archive) ..."
    if ($SevenZip) {
        if ($Archive -match '\.tar\.(xz|gz|bz2)$') {
            $Unpack = Join-Path $Downloads ('unpack-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $Unpack -Force | Out-Null
            & $SevenZip x -y -bso0 -bsp0 "-o$Unpack" $Archive
            if ($LASTEXITCODE -ne 0) { throw "7-Zip failed to decompress $Archive ($LASTEXITCODE)" }
            $Tar = Get-ChildItem -LiteralPath $Unpack -Filter '*.tar' -File | Select-Object -First 1
            if (-not $Tar) { throw "No .tar found after decompressing $Archive" }
            & $SevenZip x -y -bso0 -bsp0 "-o$Destination" $Tar.FullName
            $Code = $LASTEXITCODE
            Remove-Item -LiteralPath $Unpack -Recurse -Force -ErrorAction SilentlyContinue
            if ($Code -ne 0) { throw "7-Zip failed to extract $Archive ($Code)" }
        } else {
            & $SevenZip x -y -bso0 -bsp0 "-o$Destination" $Archive
            if ($LASTEXITCODE -ne 0) { throw "7-Zip failed to extract $Archive ($LASTEXITCODE)" }
        }
    } else {
        Write-Host '7-Zip not found; falling back to the Windows tar.'
        Invoke-Native (Join-Path $env:SystemRoot 'System32\tar.exe') @('-xf',$Archive,'-C',$Destination)
    }
    Write-Host "Extracted $(Split-Path -Leaf $Archive)"
}

function Expand-Package([string]$Archive, [string]$Destination, [string]$RequiredFile) {
    if (Test-Path -LiteralPath (Join-Path $Destination $RequiredFile) -PathType Leaf) { return }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Expand-Archive7z $Archive $Destination
    if (-not (Test-Path -LiteralPath (Join-Path $Destination $RequiredFile) -PathType Leaf)) {
        throw "Unexpected archive structure: $Archive; missing $RequiredFile"
    }
}

# Headers match the precompiled libraries bundled with the uploaded source.
$Package = Get-Package 'libzip-1.9.2.tar.xz' 'https://libzip.org/download/libzip-1.9.2.tar.xz'
Expand-Package $Package (Join-Path $DevDir 'Libzip') 'libzip-1.9.2\lib\zip.h'
$Package = Get-Package 'freetype-2.9.1.tar.gz' @('https://downloads.sourceforge.net/project/freetype/freetype2/2.9.1/freetype-2.9.1.tar.gz','https://download.savannah.gnu.org/releases/freetype/freetype-2.9.1.tar.gz','https://download.savannah.nongnu.org/releases/freetype/freetype-2.9.1.tar.gz')
Expand-Package $Package (Join-Path $DevDir 'FreeType') 'freetype-2.9.1\include\ft2build.h'
$Package = Get-Package 'ffmpeg-5.0.tar.xz' @('https://ffmpeg.org/releases/ffmpeg-5.0.tar.xz','https://ftp.osuosl.org/pub/blfs/conglomeration/ffmpeg/ffmpeg-5.0.tar.xz')
Expand-Package $Package (Join-Path $DevDir 'FFmpeg') 'ffmpeg-5.0\libavcodec\avcodec.h'
$Package = Get-Package 'openal-soft-1.22.0.tar.bz2' 'https://openal-soft.org/openal-releases/openal-soft-1.22.0.tar.bz2'
Expand-Package $Package (Join-Path $DevDir 'OpenAL') 'openal-soft-1.22.0\include\AL\al.h'

# Runtime tools are independent from the native program's FFmpeg 5.0 libraries.
$Package = Get-Package 'ffmpeg-8.1.2-essentials_build.zip' `
    'https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-8.1.2-essentials_build.zip' `
    'db580001caa24ac104c8cb856cd113a87b0a443f7bdf47d8c12b1d740584a2ec'
$FfmpegRoot = Join-Path $DevDir 'Runtime\ffmpeg'
Expand-Package $Package $FfmpegRoot 'ffmpeg-8.1.2-essentials_build\bin\ffmpeg.exe'
$FfmpegDir = Join-Path $FfmpegRoot 'ffmpeg-8.1.2-essentials_build\bin'
if (-not (Test-Path -LiteralPath (Join-Path $FfmpegDir 'ffprobe.exe'))) { throw 'FFprobe is missing.' }
# Keep the original FFmpeg license and build configuration with the executables.
Get-ChildItem -LiteralPath (Split-Path -Parent $FfmpegDir) -File | Where-Object {
    $_.Name -match '^(LICENSE|COPYING|NOTICE|README)'
} | Copy-Item -Destination $FfmpegDir -Force

$PoseModel = Get-Package 'pose_landmarker_lite.task' `
    'https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/1/pose_landmarker_lite.task'
if ((Get-Item -LiteralPath $PoseModel).Length -lt 1000000) { throw 'The pose model download is incomplete.' }

$JomArchive = Get-Package 'jom_1_1_4.zip' 'https://download.qt.io/official_releases/jom/jom_1_1_4.zip' `
    'd533c1ef49214229681e90196ed2094691e8c4a0a0bef0b2c901debcb562682b'
$JomDir = Join-Path $DevDir 'Jom'
Expand-Package $JomArchive $JomDir 'jom.exe'
$QtArchive = Get-Package 'qtbase-everywhere-opensource-src-5.15.9.zip' `
    'https://download.qt.io/archive/qt/5.15/5.15.9/submodules/qtbase-everywhere-opensource-src-5.15.9.zip' `
    '61f827046106772324ec5253c26f3e48868bfe462ecf1c1f7f8eefd0d02746c5'
$QtRoot = Join-Path $DevDir 'Qt\5.15.9'
$QtSource = Join-Path $QtRoot 'qtbase-everywhere-src-5.15.9'
$QtInstall = Join-Path $QtRoot 'build'
$QtMarker = Join-Path $QtInstall 'MI_CUSTOM_QT_COMPLETE.json'
if (-not (Test-Path -LiteralPath $QtMarker)) {
    # The .zip's root name is verified after extraction instead of assumed.
    New-Item -ItemType Directory -Path $QtRoot -Force | Out-Null
    Expand-Archive7z $QtArchive $QtRoot
    $Candidates = @(Get-ChildItem -LiteralPath $QtRoot -Directory | Where-Object {
        $_.Name -like 'qtbase-everywhere*5.15.9' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'configure.bat'))
    })
    if ($Candidates.Count -ne 1) { throw 'Cannot locate the Qt 5.15.9 source directory.' }
    $QtSource = $Candidates[0].FullName
    $QtBuild = Join-Path $QtRoot 'compile'
    New-Item -ItemType Directory -Path $QtBuild -Force | Out-Null
    Push-Location $QtBuild
    try {
        # Schannel uses Windows TLS and avoids a separately built OpenSSL library.
        $ConfigArgs = @('-platform','win32-msvc','-prefix',$QtInstall,'-opensource','-confirm-license',
            '-release','-static','-static-runtime','-qt-libjpeg','-qt-libpng','-qt-freetype',
            '-opengl','desktop','-no-openssl','-schannel','-no-icu',
            '-nomake','tests','-nomake','examples','-nomake','tools')
        & (Join-Path $QtSource 'configure.bat') @ConfigArgs 2>&1 | Tee-Object -FilePath (Join-Path $DevDir 'qt-configure.log')
        if ($LASTEXITCODE -ne 0) { throw 'Qt configure failed. See qt-configure.log.' }
        & (Join-Path $JomDir 'jom.exe') '-j' $Threads 2>&1 | Tee-Object -FilePath (Join-Path $DevDir 'qt-build.log')
        if ($LASTEXITCODE -ne 0) { throw 'Qt compilation failed. See qt-build.log.' }
        & (Join-Path $JomDir 'jom.exe') 'install' 2>&1 | Tee-Object -FilePath (Join-Path $DevDir 'qt-install.log')
        if ($LASTEXITCODE -ne 0) { throw 'Qt install failed. See qt-install.log.' }
    } finally { Pop-Location }
    $QtLicenses = Join-Path $QtInstall 'licenses'
    New-Item -ItemType Directory -Path $QtLicenses -Force | Out-Null
    Get-ChildItem -LiteralPath $QtSource -File | Where-Object {
        $_.Name -match '^(LICENSE|COPYING|NOTICE)'
    } | Copy-Item -Destination $QtLicenses -Force
    if (-not (Test-Path -LiteralPath (Join-Path $QtInstall 'lib\cmake\Qt5\Qt5Config.cmake'))) {
        throw 'Qt installation is incomplete.'
    }
    @{version='5.15.9'; static_runtime=$true; tls='Schannel'; source_sha256='61f827046106772324ec5253c26f3e48868bfe462ecf1c1f7f8eefd0d02746c5'} |
        ConvertTo-Json | Set-Content -LiteralPath $QtMarker -Encoding UTF8
}
foreach ($Required in @('lib\cmake\Qt5\Qt5Config.cmake','lib\Qt5Core.lib','lib\Qt5Gui.lib','lib\Qt5Widgets.lib','lib\Qt5Network.lib')) {
    if (-not (Test-Path -LiteralPath (Join-Path $QtInstall $Required))) { throw "Cached Qt is incomplete: $Required" }
}

# Build-Windows.ps1 consumes these exact resolved locations in the next step.
# Jolt Physics (HCl physics engine) is built from source by CMake.
$JoltDir = Join-Path $DevDir 'JoltPhysics'
if (-not (Test-Path -LiteralPath (Join-Path $JoltDir 'Build\CMakeLists.txt'))) {
    if (Test-Path -LiteralPath $JoltDir) { Remove-Item -LiteralPath $JoltDir -Recurse -Force }
    Invoke-Native 'git.exe' @('clone','--depth','1','--branch','v5.6.0','https://github.com/jrouwe/JoltPhysics.git',$JoltDir)
}
if (-not (Test-Path -LiteralPath (Join-Path $JoltDir 'Build\CMakeLists.txt'))) { throw 'Jolt Physics v5.6.0 could not be downloaded.' }

@{dev_dir=$DevDir; ffmpeg_dir=$FfmpegDir; pose_model=$PoseModel} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $DevDir 'BUILD_INPUTS.json') -Encoding UTF8
Write-Host "Dependencies prepared in $DevDir"

