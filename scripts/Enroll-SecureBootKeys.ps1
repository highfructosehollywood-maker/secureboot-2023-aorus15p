# Enroll-SecureBootKeys.ps1
# ---------------------------------------------------------------------------
# Enrolls the Microsoft default Secure Boot key set (2011 + 2023 certificates)
# into firmware while the machine is in SETUP MODE (PK undefined).
#
# Use this when Secure Boot keys have been erased (e.g. to unlock a hidden BIOS)
# and "Restore Factory Keys" would only install the 2011 certificates, which
# breaks boot on a machine whose Windows boot manager is already signed by the
# "Windows UEFI CA 2023" certificate.
#
# Key material (in ..\keys\) comes from Microsoft's official repository:
#   https://github.com/microsoft/secureboot_objects   (release v1.6.5)
#   LegacyFirmwareDefaults/Firmware  +  PreSignedObjects
# Licensed BSD-2-Clause-Patent by Microsoft.
#
#   DB.bin  = Windows Production PCA 2011 + Windows UEFI CA 2023
#             + Microsoft UEFI CA 2011 + Microsoft UEFI CA 2023
#             + Microsoft Option ROM UEFI CA 2023        (5 certificates)
#   KEK.bin = Microsoft KEK CA 2011 + Microsoft KEK 2K CA 2023
#   PK.bin  = Windows OEM Devices PK  (Microsoft shared PK)
#   DBX.bin = current Microsoft revocation list (enrolled only with -IncludeDbx)
#
# For each variable the script tries a raw EFI_SIGNATURE_LIST write first, and
# falls back to the documented Format-SecureBootUEFI cert-based flow if the
# firmware rejects the raw write.
#
# Run in an ELEVATED PowerShell.  Suspend BitLocker first if it is enabled.
# ---------------------------------------------------------------------------

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$IncludeDbx
)

$ErrorActionPreference = 'Stop'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$keys    = Join-Path (Split-Path -Parent $here) 'keys'
$certs   = Join-Path $keys 'certs'
# Deliberately early timestamp. Firmware records the time of an authenticated write
# and rejects later writes bearing an OLDER timestamp (anti-rollback). Using an early
# date avoids blocking future Windows-delivered dbx/db updates. Microsoft's own docs
# use 2011-11-01 for the same reason.
$time    = '2011-11-01T00:00:00Z'
$msOwner = [Guid]'77fa9abd-0359-4d32-bd60-28f4e78f784b'   # Microsoft SignatureOwner

# --- 1. Require UEFI boot + genuine Setup Mode (read SetupMode explicitly) ---
# PEFirmwareType is simply absent on some Windows installs (verified on Win11 26200), so
# only an explicit 1 = legacy BIOS is a hard stop. The SetupMode read below is the real
# gate anyway: Get-SecureBootUEFI cannot succeed on a machine that is not UEFI-booted.
$fw = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name PEFirmwareType -ErrorAction SilentlyContinue).PEFirmwareType
if ($fw -eq 1) {
    Write-Error 'System is booted in legacy BIOS mode (PEFirmwareType=1). Secure Boot variable writes will not work.'
}
try { $setupMode = (Get-SecureBootUEFI -Name SetupMode).bytes[0] } catch {
    Write-Error "Could not read the SetupMode variable ($($_.Exception.Message)). Aborting rather than guessing the state."
}
if ($setupMode -ne 1) {
    # Deliberately not Write-Error. Landing here almost always means the keys are already
    # enrolled - this script's own goal state - so a red error would report a healthy
    # machine as a failure. State the situation, say plainly that nothing was written, and
    # point at whatever step is actually left.
    $sb = $null
    try { $sb = Confirm-SecureBootUEFI } catch { }
    Write-Host "[i] SetupMode = $setupMode - not in Setup Mode, so there are no keys to enroll." -ForegroundColor Cyan
    Write-Host '    NOTHING WAS WRITTEN. A key set is already present in the firmware.' -ForegroundColor Cyan
    if ($sb -eq $true) {
        Write-Host '    Secure Boot is ON as well - this scenario is complete. If Windows still warns' -ForegroundColor Green
        Write-Host '    about certificates, that is Scenario A: docs\scenario-a-secureboot-on-warning.md' -ForegroundColor Green
    } else {
        Write-Host '    Secure Boot is still OFF, but that is a BIOS toggle rather than an enrollment:' -ForegroundColor Yellow
        Write-Host '    continue with docs\scenario-b-stuck-setup-mode.md, Step 3.' -ForegroundColor Yellow
    }
    Write-Host '    To re-enroll on purpose, erase the Secure Boot keys in the BIOS first' -ForegroundColor DarkGray
    Write-Host '    (that is what returns SetupMode = 1), then run this again.' -ForegroundColor DarkGray
    exit 0
}
Write-Host '[OK] UEFI mode confirmed; system is in Setup Mode (SetupMode=1).' -ForegroundColor Green

# --- 2. BitLocker guard ---
# The system drive is the one whose TPM measurements the key writes disturb; it is not
# always C: (Windows-to-Go, or a recovery-environment boot).
$sysDrive = $env:SystemDrive
$blv = Get-BitLockerVolume -MountPoint $sysDrive -ErrorAction SilentlyContinue
if ($blv -and $blv.ProtectionStatus -eq 'On') {
    Write-Host "[!] BitLocker is ON for $sysDrive - suspending for 1 reboot..." -ForegroundColor Yellow
    Suspend-BitLocker -MountPoint $sysDrive -RebootCount 1 | Out-Null
    Write-Host '[OK] BitLocker suspended.' -ForegroundColor Green
} else {
    Write-Host "[OK] BitLocker not active on $sysDrive (or not present)." -ForegroundColor Green
}

# --- 3. Enrollment helper: raw ESL first, cert-based fallback ---
function Enroll {
    param([string]$Name, [string]$EslFile, [string[]]$CertFiles)
    $esl = Join-Path $keys $EslFile
    Write-Host "  [$Name]" -ForegroundColor Cyan
    try {
        Write-Host "    raw ESL ($EslFile)..." -NoNewline
        Set-SecureBootUEFI -Name $Name -Time $time -ContentFilePath $esl | Out-Null
        Write-Host ' OK' -ForegroundColor Green
        return $true
    } catch {
        Write-Host " failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    if ($CertFiles.Count -gt 0) {
        try {
            $paths = $CertFiles | ForEach-Object { Join-Path $certs $_ }
            $paths | ForEach-Object { if (-not (Test-Path $_)) { throw "missing cert: $_" } }
            Write-Host '    Format-SecureBootUEFI from certificates...' -NoNewline
            (Format-SecureBootUEFI -Name $Name -SignatureOwner $msOwner -Time $time -CertificateFilePath $paths -FormatWithCert) | Set-SecureBootUEFI | Out-Null
            Write-Host ' OK' -ForegroundColor Green
            return $true
        } catch {
            Write-Host " failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    return $false
}

$dbCerts  = @('MicWinProPCA2011.der','WindowsUEFICA2023.der','MicCorUEFCA2011.der','MicrosoftUEFICA2023.der','MicrosoftOptionRomUEFICA2023.der')
$kekCerts = @('MicCorKEKCA2011.der','MicrosoftKEK2KCA2023.der')
$pkCerts  = @('WindowsOEMDevicesPK.der')

# --- 4. Enroll. ORDER MATTERS: (dbx) -> db -> KEK -> PK (PK last exits Setup Mode) ---
if ($IncludeDbx) {
    if (-not (Enroll -Name 'dbx' -EslFile 'DBX.bin' -CertFiles @())) {
        Write-Host '  [!] DBX enrollment failed - continuing. Windows Update will populate DBX after Secure Boot is on.' -ForegroundColor Yellow
    }
} else {
    Write-Host '  [dbx] skipped (default) - Windows Update populates it automatically after first reboot.' -ForegroundColor DarkGray
}

if (-not (Enroll -Name 'db'  -EslFile 'DB.bin'  -CertFiles $dbCerts))  { Write-Error 'db enrollment failed by both strategies. System remains in Setup Mode - nothing destructive happened.' }
if (-not (Enroll -Name 'KEK' -EslFile 'KEK.bin' -CertFiles $kekCerts)) { Write-Error 'KEK enrollment failed by both strategies. System remains in Setup Mode.' }

Write-Host '  PK is written LAST (exits Setup Mode):' -ForegroundColor Cyan
if (-not (Enroll -Name 'PK' -EslFile 'PK.bin' -CertFiles $pkCerts)) {
    Write-Host ''
    Write-Host 'The firmware refused the unsigned PK write by both strategies (some AMI builds require this).' -ForegroundColor Yellow
    Write-Host 'Fallback: copy keys\WindowsOEMDevicesPK.der to a FAT32 USB stick, reboot into the BIOS,' -ForegroundColor Yellow
    Write-Host 'Secure Boot -> Key Management -> Platform Key -> Update/Enroll -> select the .der file.' -ForegroundColor Yellow
    Write-Host 'db/KEK written above stay in place; only PK is missing.' -ForegroundColor Yellow
    exit 1
}

# --- 5. Verify ---
Write-Host ''
Write-Host 'Verification:' -ForegroundColor Cyan
$db  = [Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI db).bytes)
$kek = [Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI kek).bytes)
"  db  contains PCA 2011             : $($db  -match 'Microsoft Windows Production PCA 2011')"
"  db  contains Windows UEFI CA 2023 : $($db  -match 'Windows UEFI CA 2023')"
"  kek contains KEK CA 2011          : $($kek -match 'Microsoft Corporation KEK CA 2011')"
"  kek contains KEK 2K CA 2023       : $($kek -match 'KEK 2K CA 2023')"

Write-Host ''
Write-Host 'All keys enrolled. Now enable Secure Boot in the BIOS, then reboot.' -ForegroundColor Green
Write-Host 'After reboot verify in Windows:  Confirm-SecureBootUEFI   (should return True)' -ForegroundColor Green
