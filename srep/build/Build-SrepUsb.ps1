# Build-SrepUsb.ps1
# Builds the SREP stick contents from source in a throwaway ubuntu:22.04 container and
# leaves the archive + hashes in srep\build\work\ (git-ignored - this repository ships
# no third-party binaries, everyone builds their own).
#
#   .\Build-SrepUsb.ps1                      # build with the pinned tags
#   .\Build-SrepUsb.ps1 -SrepTag 0.2.2       # another SREP release
#   .\Build-SrepUsb.ps1 -EdkTag edk2-stable202411
#   .\Build-SrepUsb.ps1 -Clean               # drop the cached edk2 volume first
#
# Requires Docker only - nothing is installed on the host. The edk2 checkout
# (~2 GB with submodules) is cached in a named docker volume, so the first run is
# slow (20-40 min) and later runs take a couple of minutes.

[CmdletBinding()]
param(
    # edk2 >= stable202411 is required: SREP's .dsc references StackCheckLib.
    [string]$EdkTag  = 'edk2-stable202502',
    # 0.2.3 is the newest release that builds without patching edk2's BaseTools
    # (0.2.4 embeds Oniguruma.efi as an HII image and needs a BaseTools hack).
    [string]$SrepTag = '0.2.3',
    [string]$SrepRepo = 'https://github.com/Maxinator500/SmokelessRuntimeEFIPatcher-RUS.git',
    [string]$Image = 'srep-build:22.04',
    [string]$Volume = 'srep-edk2-build',
    [switch]$Clean,
    [switch]$KeepStage
)

$ErrorActionPreference = 'Stop'

$srepDir = Split-Path -Parent $PSScriptRoot           # <repo>\srep
$workDir = Join-Path $PSScriptRoot 'work'             # bind-mounted as /out, git-ignored

docker info --format '{{.ServerVersion}}' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Docker does not respond - start Docker Desktop.' }

if ($Clean) {
    Write-Host "Removing cached build volume '$Volume' ..." -ForegroundColor Yellow
    docker volume rm $Volume 2>$null | Out-Null
}

if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Path $workDir | Out-Null

# Docker wants forward slashes; a drive-letter path works as-is on Docker Desktop.
$srepMount = ($srepDir -replace '\\', '/')
$outMount  = ($workDir -replace '\\', '/')

Write-Host "Preparing build image $Image ..." -ForegroundColor Cyan
docker build -t $Image $PSScriptRoot
if ($LASTEXITCODE -ne 0) { throw 'docker build of the build environment failed.' }

Write-Host "Building SREP $SrepTag against $EdkTag in $Image ..." -ForegroundColor Cyan
docker run --rm `
    -v "${Volume}:/build" `
    -v "${srepMount}:/srep:ro" `
    -v "${outMount}:/out" `
    -e "EDK_TAG=$EdkTag" -e "SREP_TAG=$SrepTag" -e "SREP_REPO=$SrepRepo" `
    $Image bash /srep/build/build.sh
if ($LASTEXITCODE -ne 0) { throw "Container build failed (exit $LASTEXITCODE)." }

# --- report -------------------------------------------------------------------
$zip = Get-ChildItem -Path $workDir -Filter 'srep-usb-*.zip' | Select-Object -First 1
if (-not $zip) { throw "No archive produced in $workDir." }

if (-not $KeepStage) {
    Remove-Item -Recurse -Force (Join-Path $workDir 'stage') -ErrorAction SilentlyContinue
}

Write-Host "`nBuild output in $workDir :" -ForegroundColor Green
Get-ChildItem $workDir | Where-Object { -not $_.PSIsContainer } |
    Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
Get-Content (Join-Path $workDir 'SHA256SUMS.txt')

Write-Host @"

Compare those hashes with srep\build\REFERENCE-BUILD.txt - with the same tags they
should match exactly.

Next: format a FAT32 stick, unpack $($zip.Name) to its root, boot it from the boot
menu (F12) and follow README.txt on the stick. Full walkthrough: srep\README.md
"@ -ForegroundColor DarkGray
