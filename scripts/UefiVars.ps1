# UefiVars.ps1
# Shared firmware-variable layer. Dot-source it, do not run it:
#
#   . (Join-Path $PSScriptRoot 'UefiVars.ps1')
#
# Get/SetFirmwareEnvironmentVariableExW need SeSystemEnvironmentPrivilege (it is in an
# elevated token but disabled by default) and an OS booted in UEFI mode - on legacy BIOS
# every read fails with 1 ERROR_INVALID_FUNCTION. Deleting a variable is a zero-size
# Set carrying the variable's *real* attributes, which is why callers read before delete.

$EfiGlobalGuid = '{8be4df61-93ca-11d2-aa0d-00e098032b8c}'

# The Win32 codes these APIs actually return, and what each one means here.
$EfiErrorText = @{
    0    = 'SUCCESS'
    1    = 'ERROR_INVALID_FUNCTION (system not booted in UEFI mode?)'
    2    = 'ERROR_FILE_NOT_FOUND'
    5    = 'ERROR_ACCESS_DENIED'
    87   = 'ERROR_INVALID_PARAMETER'
    122  = 'ERROR_INSUFFICIENT_BUFFER'
    203  = 'ERROR_ENVVAR_NOT_FOUND (variable really does not exist)'
    1300 = 'ERROR_NOT_ALL_ASSIGNED (privilege NOT actually granted)'
    1314 = 'ERROR_PRIVILEGE_NOT_HELD'
}

# Codes that mean "the variable simply is not there", as opposed to a failed read. 0 is in
# the list because Windows does not always set an error code for an absent variable.
$EfiNotFoundErrors = @(0, 2, 203)

function Format-Win32Error([int]$Code) {
    if ($EfiErrorText.ContainsKey($Code)) { "$Code = $($EfiErrorText[$Code])" } else { "$Code" }
}

if (-not ('Uefi.Native' -as [type])) {
Add-Type -Namespace Uefi -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern uint GetFirmwareEnvironmentVariableExW(string lpName, string lpGuid, byte[] pBuffer, uint nSize, out uint pdwAttributes);

[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern bool SetFirmwareEnvironmentVariableExW(string lpName, string lpGuid, byte[] pValue, uint nSize, uint dwAttributes);

[DllImport("kernel32.dll", EntryPoint="SetFirmwareEnvironmentVariableExW", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern bool SetFirmwareEnvVarPtr(string lpName, string lpGuid, IntPtr pValue, uint nSize, uint dwAttributes);

[DllImport("advapi32.dll", SetLastError=true)]
public static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);

[DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern bool LookupPrivilegeValueW(string host, string name, out long luid);

[StructLayout(LayoutKind.Sequential, Pack=4)]
public struct TP { public uint Count; public long Luid; public uint Attr; }

[DllImport("advapi32.dll", SetLastError=true)]
public static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TP newst, uint len, IntPtr prev, IntPtr ret);

[DllImport("kernel32.dll")]
public static extern IntPtr GetCurrentProcess();
'@
}

function Test-IsElevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FirmwareType {
    # 2 = UEFI, 1 = legacy BIOS.
    (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name PEFirmwareType `
        -ErrorAction SilentlyContinue).PEFirmwareType
}

function Enable-SystemEnvironmentPrivilege {
    # Reports each step instead of deciding for the caller: the diagnostics script wants
    # to print what happened, the management script wants to abort.
    # AdjustTokenPrivileges returns TRUE even when it granted nothing, so LastError (1300)
    # is the only reliable signal.
    $tok = [IntPtr]::Zero
    $opened = [Uefi.Native]::OpenProcessToken(
        [Uefi.Native]::GetCurrentProcess(), 0x28, [ref]$tok)   # QUERY | ADJUST_PRIVILEGES
    $luid = 0L
    $looked = [Uefi.Native]::LookupPrivilegeValueW($null, 'SeSystemEnvironmentPrivilege', [ref]$luid)
    $tp = New-Object Uefi.Native+TP
    $tp.Count = 1; $tp.Luid = $luid; $tp.Attr = 2              # SE_PRIVILEGE_ENABLED
    $adjusted = [Uefi.Native]::AdjustTokenPrivileges($tok, $false, [ref]$tp, 0, [IntPtr]::Zero, [IntPtr]::Zero)
    [pscustomobject]@{
        TokenOpened = $opened
        LuidFound   = $looked
        Luid        = $luid
        Adjusted    = $adjusted
        LastError   = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    }
}

function Get-UefiVar([Parameter(Mandatory)][string]$Name) {
    # Always returns an object: Bytes is $null when the read failed and LastError says why,
    # because "not present", "access denied" and "not UEFI" need different handling upstream.
    #
    # Callers MUST test `$null -ne $r.Bytes`, never `if ($r.Bytes)`. A one-byte variable
    # holding 0x00 - which is exactly SetupMode once keys are enrolled - comes back as the
    # single-element array @(0), and PowerShell unwraps that to the falsy scalar 0. The
    # truthiness form reports the most important variable in this repo as unreadable.
    $err = 0
    foreach ($size in 4096, 65536) {
        $buf  = New-Object byte[] $size
        $attr = 0
        $n    = [Uefi.Native]::GetFirmwareEnvironmentVariableExW(
            $Name, $EfiGlobalGuid, $buf, $buf.Length, [ref]$attr)
        $err  = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($n -gt 0) {
            return [pscustomobject]@{
                Name = $Name; Bytes = [byte[]]$buf[0..($n - 1)]; Attributes = $attr; LastError = 0
            }
        }
        # A bigger buffer is only worth a second call for ERROR_INSUFFICIENT_BUFFER.
        if ($err -ne 122) { break }
    }
    [pscustomobject]@{ Name = $Name; Bytes = $null; Attributes = 0; LastError = $err }
}

function Test-UefiVarMissing($Result) {
    # True when the read failed *because the variable does not exist*.
    $null -eq $Result.Bytes -and $EfiNotFoundErrors -contains $Result.LastError
}

function Set-UefiVar([Parameter(Mandatory)][string]$Name, [byte[]]$Data, [uint32]$Attributes) {
    [Uefi.Native]::SetFirmwareEnvironmentVariableExW($Name, $EfiGlobalGuid, $Data, $Data.Length, $Attributes)
}

function Remove-UefiVar([Parameter(Mandatory)][string]$Name, [uint32]$Attributes) {
    # Some firmware only accepts the NULL-pointer form of the zero-size Set, so try the
    # byte[] overload first and fall back. Both error codes travel back to the caller.
    if ([Uefi.Native]::SetFirmwareEnvironmentVariableExW(
            $Name, $EfiGlobalGuid, (New-Object byte[] 0), 0, $Attributes)) {
        return [pscustomobject]@{ Removed = $true; Errors = @() }
    }
    $e1 = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ([Uefi.Native]::SetFirmwareEnvVarPtr($Name, $EfiGlobalGuid, [IntPtr]::Zero, 0, $Attributes)) {
        return [pscustomobject]@{ Removed = $true; Errors = @() }
    }
    $e2 = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    [pscustomobject]@{ Removed = $false; Errors = @($e1, $e2) }
}

function Get-DriverVarName([uint16]$Id) { 'Driver{0:X4}' -f $Id }

function ConvertFrom-UefiIdList([byte[]]$Bytes) {
    # DriverOrder / BootOrder are packed little-endian UINT16 arrays.
    for ($i = 0; $i -lt $Bytes.Length; $i += 2) { [BitConverter]::ToUInt16($Bytes, $i) }
}

function ConvertTo-UefiIdList([int[]]$Ids) {
    [byte[]]($Ids | ForEach-Object { [BitConverter]::GetBytes([uint16]$_) })
}

function Get-EfiLoadOptionDescription([byte[]]$Bytes) {
    # EFI_LOAD_OPTION: UINT32 Attributes, UINT16 FilePathListLength, then a
    # null-terminated CHAR16 Description.
    $len = $Bytes.Length - 6
    if ($len -lt 2) { return '' }
    if ($len % 2) { $len-- }
    [Text.Encoding]::Unicode.GetString($Bytes, 6, $len).Split([char]0)[0]
}
