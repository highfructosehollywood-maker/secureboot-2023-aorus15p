# Test-UefiVarAccess.ps1  - diagnostics only, changes nothing.
# Run as Administrator. The firmware-variable API lives in UefiVars.ps1, shared with
# Manage-UefiDrivers.ps1.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UefiVars.ps1')

# --- 0. context ---
"Administrator      : $(Test-IsElevated)"
"PSVersion          : $($PSVersionTable.PSVersion)"
"Process bitness    : $([IntPtr]::Size * 8)-bit"
$fwType = Get-FirmwareType   # absent on some installs, hence the explicit wording
"PEFirmwareType     : $(if ($null -ne $fwType) { "$fwType  (2 = UEFI, 1 = legacy BIOS)" } else { '<value not present - tells us nothing either way>' })"
try { "Confirm-SecureBootUEFI : $(Confirm-SecureBootUEFI)" } catch { "Confirm-SecureBootUEFI : (error: $($_.Exception.Message))" }
# Scenario B hinges on SetupMode, and the supported cmdlet returns the byte even when the
# raw API below cannot (all-zero values - see UefiVars.ps1). Ask both.
try { "Get-SecureBootUEFI SetupMode : $((Get-SecureBootUEFI -Name SetupMode).Bytes[0])  (1 = Setup Mode, 0 = keys enrolled)" }
catch { "Get-SecureBootUEFI SetupMode : (error: $($_.Exception.Message))" }

# --- 1. privilege, checked properly ---
$priv = Enable-SystemEnvironmentPrivilege
"OpenProcessToken   : $($priv.TokenOpened)"
"LookupPrivilege    : $($priv.LuidFound)  (luid=$($priv.Luid))"
"AdjustTokenPriv    : returned=$($priv.Adjusted)  lastError=$(Format-Win32Error $priv.LastError)"
if ($priv.LastError -eq 1300) {
    Write-Host 'PRIVILEGE WAS NOT GRANTED - the reads below will fail.' -ForegroundColor Red
}

# --- 2. read several variables, report exact errors ---
function Format-VarResult($v) {
    # `$null -ne`, not truthiness: a one-byte 0x00 value (SetupMode with keys enrolled)
    # unwraps to the falsy scalar 0 - see the note in UefiVars.ps1.
    if (Test-UefiVarMissing $v) { return "{0,-14} : not present" -f $v.Name }
    if ($null -eq $v.Bytes) { return "{0,-14} : FAILED   {1}" -f $v.Name, (Format-Win32Error $v.LastError) }
    $hex = (($v.Bytes[0..([Math]::Min($v.Bytes.Length, 32) - 1)]) | ForEach-Object { '{0:x2}' -f $_ }) -join ' '
    "{0,-14} : {1,4} bytes  attr=0x{2:X}  [{3}]" -f $v.Name, $v.Bytes.Length, $v.Attributes, $hex
}

""
"--- control reads (BootOrder/BootCurrent should always work) ---"
'BootOrder', 'BootCurrent', 'SetupMode', 'SecureBoot' | ForEach-Object { Format-VarResult (Get-UefiVar $_) }

""
"--- what we actually care about ---"
# The Driver#### names come from DriverOrder rather than a fixed Driver0000..0002 probe:
# bcfg allocates the next free index, so repeated SREP boots land well past 0002.
$ord = Get-UefiVar 'DriverOrder'
Format-VarResult $ord
if ($null -ne $ord.Bytes) {
    foreach ($id in ConvertFrom-UefiIdList $ord.Bytes) {
        $v = Get-UefiVar (Get-DriverVarName $id)
        Format-VarResult $v
        if ($null -ne $v.Bytes) {
            "                 description = '{0}'" -f (Get-EfiLoadOptionDescription $v.Bytes)
        }
    }
}

""
"--- boot path per BCD (context only - Driver#### entries never appear here) ---"
# Windows' BCD firmware store carries Boot#### entries, not Driver####, so this cannot
# corroborate the driver list above - do not go looking for 'srep' in it. What it is good
# for is the other half of the picture: which boot manager the firmware starts and from
# where. Printed unfiltered on purpose; filtering on English words like 'identifier'
# silently produced nothing on a localised Windows.
# The {braces} are bcdedit's own aliases for well-known BCD GUIDs, not unsubstituted
# placeholders - add /v to see the raw GUIDs instead.
try { bcdedit /enum firmware 2>&1 } catch { "bcdedit failed: $_" }
