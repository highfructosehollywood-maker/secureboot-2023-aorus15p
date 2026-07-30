# Manage-UefiDrivers.ps1
# Lists / removes UEFI Driver#### entries and fixes DriverOrder, from Windows.
# Driver####  and DriverOrder are NV+RT+BS, so they are reachable at OS runtime.
#
#   .\Manage-UefiDrivers.ps1                 # list only (safe, read-only)
#   .\Manage-UefiDrivers.ps1 -Remove 1,2     # delete Driver0001 + Driver0002, rewrite DriverOrder
#
# The firmware-variable API itself lives in UefiVars.ps1, shared with Test-UefiVarAccess.ps1.

#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    # NOTE: values are DECIMAL indices matching the Driver#### hex id, e.g. Driver000A = -Remove 10
    [int[]]$Remove
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UefiVars.ps1')

$priv = Enable-SystemEnvironmentPrivilege
if (-not $priv.TokenOpened) { Write-Error 'OpenProcessToken failed.' }
if (-not $priv.LuidFound)   { Write-Error 'LookupPrivilegeValue failed.' }
if (-not $priv.Adjusted -or $priv.LastError -eq 1300) {
    Write-Error "SeSystemEnvironmentPrivilege was not granted ($(Format-Win32Error $priv.LastError))."
}
Write-Host '[OK] SeSystemEnvironmentPrivilege enabled.' -ForegroundColor Green

# --- read DriverOrder ---
$ord = Get-UefiVar 'DriverOrder'
if ($null -eq $ord.Bytes) {
    # Only a genuine "does not exist" is nothing to do - reporting a denied or
    # non-UEFI read as success would send the user looking in the wrong place.
    if (Test-UefiVarMissing $ord) {
        Write-Host 'DriverOrder is not present - nothing to do.' -ForegroundColor Yellow
        exit 0
    }
    Write-Error "Could not read DriverOrder ($(Format-Win32Error $ord.LastError))."
}
$ids = @(ConvertFrom-UefiIdList $ord.Bytes)
Write-Host ("DriverOrder: " + (($ids | ForEach-Object { Get-DriverVarName $_ }) -join ', ')) -ForegroundColor Cyan
Write-Host ("Attributes : 0x{0:X}" -f $ord.Attributes)

# --- describe each entry, keeping what the delete pass below needs ---
Write-Host "`nEntries:" -ForegroundColor Cyan
$entries = foreach ($id in $ids) {
    $name = Get-DriverVarName $id
    $v = Get-UefiVar $name
    $read = $null -ne $v.Bytes        # not `if ($v.Bytes)` - see the note in UefiVars.ps1
    if ($read) {
        Write-Host ("  {0} : '{1}'  ({2} bytes)" -f $name, (Get-EfiLoadOptionDescription $v.Bytes), $v.Bytes.Length)
    } else {
        Write-Host ("  {0} : <missing>  ({1})" -f $name, (Format-Win32Error $v.LastError)) -ForegroundColor Yellow
    }
    [pscustomobject]@{
        Id   = $id
        Name = $name
        # 7 = NV|BS|RT, the attributes bcfg gives these entries; only a guess for an
        # entry DriverOrder names but we could not read.
        Attributes = if ($read) { $v.Attributes } else { 7 }
    }
}

# `-not $Remove` would be true for `-Remove 0`: the one-element array @(0) unwraps to the
# falsy scalar 0, so deleting Driver0000 - which exists on real machines - would silently
# turn into a read-only run.
if ($null -eq $Remove -or $Remove.Count -eq 0) {
    Write-Host "`nRead-only run. To delete e.g. Driver0001 and Driver0002:" -ForegroundColor DarkGray
    Write-Host "   .\Manage-UefiDrivers.ps1 -Remove 1,2" -ForegroundColor DarkGray
    exit 0
}

# --- delete requested entries; whatever survives goes back into DriverOrder ---
Write-Host ''
$keep = @(foreach ($e in $entries) {
    if ($Remove -notcontains $e.Id) { $e.Id; continue }
    if (-not $PSCmdlet.ShouldProcess($e.Name, 'Delete UEFI variable')) { $e.Id; continue }
    Write-Host ("  deleting {0} (attr=0x{1:X}) ..." -f $e.Name, $e.Attributes) -NoNewline
    $r = Remove-UefiVar $e.Name $e.Attributes
    if ($r.Removed) { Write-Host ' OK' -ForegroundColor Green; continue }
    Write-Host (" FAILED (byte[] err={0}, IntPtr err={1})" -f $r.Errors[0], $r.Errors[1]) -ForegroundColor Red
    $e.Id
})

# --- rewrite DriverOrder ---
# Only when the delete pass actually changed the list. Under -WhatIf, at a declined prompt,
# or for an -Remove id that was never in DriverOrder, $keep still equals $ids - and writing
# the identical value back would be a real NVRAM write that -WhatIf promised not to make.
# Past this guard every write is a consequence of a deletion the user already confirmed,
# so it needs no second ShouldProcess prompt of its own.
if (($keep -join ',') -eq ($ids -join ',')) {
    Write-Host '  DriverOrder unchanged - not rewriting it.' -ForegroundColor DarkGray
} elseif ($keep.Count -eq 0) {
    Write-Host '  removing DriverOrder (no entries left) ...' -NoNewline
    $r = Remove-UefiVar 'DriverOrder' $ord.Attributes
    if ($r.Removed) { Write-Host ' OK' -ForegroundColor Green }
    else { Write-Host (" FAILED (byte[] err={0}, IntPtr err={1})" -f $r.Errors[0], $r.Errors[1]) -ForegroundColor Red }
} else {
    Write-Host ("  rewriting DriverOrder -> " + (($keep | ForEach-Object { Get-DriverVarName $_ }) -join ', ') + ' ...') -NoNewline
    if (Set-UefiVar 'DriverOrder' (ConvertTo-UefiIdList $keep) $ord.Attributes) { Write-Host ' OK' -ForegroundColor Green }
    else {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Host (" FAILED (err {0})" -f (Format-Win32Error $err)) -ForegroundColor Red
    }
}

Write-Host "`nDone. Re-run without -Remove to verify." -ForegroundColor Green
