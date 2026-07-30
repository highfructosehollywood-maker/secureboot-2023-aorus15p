# Build-SrepUsb.ps1
# Builds the SREP stick contents from source in a throwaway container (image built from
# the Dockerfile beside this script) and leaves the archive + hashes in srep\build\work\
# (git-ignored - this repository ships no third-party binaries, everyone builds their own).
#
#   .\Build-SrepUsb.ps1                      # build with the pinned tags
#   .\Build-SrepUsb.ps1 -SrepTag 0.2.2       # another SREP release
#   .\Build-SrepUsb.ps1 -EdkTag edk2-stable202411
#   .\Build-SrepUsb.ps1 -Clean               # drop the cached edk2 volume first
#
# Both steps are logged into work\ (docker-image.log, docker-run.log), so do NOT wrap the
# call in `2>&1 | Tee-Object`: piping a native command's stderr through PowerShell turns
# every line of ordinary output into a red error record, which makes a clean build look
# like a failed one.
#
# Requires Docker only - nothing is installed on the host. The edk2 checkout is cached in
# a named docker volume, so the first run is slow (20-40 min) and later runs take a couple
# of minutes.
#
# This param() block is the single source of the pinned versions: build.sh requires all
# three to be passed in rather than carrying its own defaults.

[CmdletBinding()]
param(
    # edk2 >= stable202411 is required: SREP's .dsc references StackCheckLib.
    [string]$EdkTag  = 'edk2-stable202502',
    # Our fork of SREP: upstream 0.2.3 built as a UEFI driver with English-only output.
    # 0.2.3 is upstream's newest release that builds without patching edk2's BaseTools
    # (0.2.4 embeds Oniguruma.efi as an HII image and needs a BaseTools hack).
    [string]$SrepTag = '0.2.3b',
    [string]$SrepRepo = 'https://github.com/djwinston/SmokelessRuntimeEFIPatcher.git',
    [switch]$Clean,
    [switch]$KeepStage
)

$ErrorActionPreference = 'Stop'

# Internal names, not tunables.
$Image  = 'srep-build:22.04'
$Volume = 'srep-edk2-build'

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
$srepMount = ((Split-Path -Parent $PSScriptRoot) -replace '\\', '/')   # <repo>\srep -> /srep
$outMount  = ($workDir -replace '\\', '/')

# `docker build` writes its whole progress display to stderr, so showing it here would paint
# a successful run red - and piping it through PowerShell would turn every line into an
# error record. Keep it in a log and only surface it if the step actually fails.
$imageLog = Join-Path $workDir 'docker-image.log'
Write-Host "Preparing build image $Image ..." -ForegroundColor Cyan
docker build -t $Image $PSScriptRoot *> $imageLog
if ($LASTEXITCODE -ne 0) {
    Get-Content $imageLog | Write-Host
    throw "docker build of the build environment failed - see $imageLog."
}

# The container's progress is worth watching live (a first run takes 20-40 min), so it stays
# on the console. Only stdout is teed: piping stderr as well is what makes PowerShell render
# ordinary log lines as red errors, and there is no need to ask the user for `2>&1`.
$runLog = Join-Path $workDir 'docker-run.log'
Write-Host "Building SREP $SrepTag against $EdkTag in $Image ..." -ForegroundColor Cyan
docker run --rm `
    -v "${Volume}:/build" `
    -v "${srepMount}:/srep:ro" `
    -v "${outMount}:/out" `
    -e "EDK_TAG=$EdkTag" -e "SREP_TAG=$SrepTag" -e "SREP_REPO=$SrepRepo" `
    $Image bash /srep/build/build.sh | Tee-Object -FilePath $runLog
if ($LASTEXITCODE -ne 0) { throw "Container build failed (exit $LASTEXITCODE) - see $runLog." }

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

Compare those hashes with srep\build\REFERENCE-BUILD.txt - with the same tags all eight
should match exactly (build.sh pins the stack cookie edk2 would otherwise randomise,
which is what makes that possible).

Next: format a FAT32 stick, unpack $($zip.Name) to its root, boot it from the boot
menu (F12) and follow README.txt on the stick. Full walkthrough: srep\README.md
"@ -ForegroundColor DarkGray
