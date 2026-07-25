# Manage-UefiDrivers.ps1
# Lists / removes UEFI Driver#### entries and fixes DriverOrder, from Windows.
# Driver####  and DriverOrder are NV+RT+BS, so they are reachable at OS runtime.
#
#   .\Manage-UefiDrivers.ps1                 # list only (safe, read-only)
#   .\Manage-UefiDrivers.ps1 -Remove 1,2     # delete Driver0001 + Driver0002, rewrite DriverOrder
#
# Run as Administrator.

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    # NOTE: values are DECIMAL indices matching the Driver#### hex id, e.g. Driver000A = -Remove 10
    [int[]]$Remove
)

$ErrorActionPreference = 'Stop'
$EFI_GLOBAL = '{8be4df61-93ca-11d2-aa0d-00e098032b8c}'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'Run as Administrator.'
}

if (-not ('Uefi.NativeV3' -as [type])) {
Add-Type -Namespace Uefi -Name NativeV3 -MemberDefinition @'
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

# --- enable SeSystemEnvironmentPrivilege (present but disabled by default) ---
$tok = [IntPtr]::Zero
[void][Uefi.NativeV3]::OpenProcessToken([Uefi.NativeV3]::GetCurrentProcess(), 0x28, [ref]$tok)
$luid = 0L
if (-not [Uefi.NativeV3]::LookupPrivilegeValueW($null, 'SeSystemEnvironmentPrivilege', [ref]$luid)) {
    Write-Error 'LookupPrivilegeValue failed.'
}
$tp = New-Object Uefi.NativeV3+TP
$tp.Count = 1; $tp.Luid = $luid; $tp.Attr = 2   # SE_PRIVILEGE_ENABLED
if (-not [Uefi.NativeV3]::AdjustTokenPrivileges($tok, $false, [ref]$tp, 0, [IntPtr]::Zero, [IntPtr]::Zero)) {
    Write-Error 'AdjustTokenPrivileges failed.'
}
Write-Host '[OK] SeSystemEnvironmentPrivilege enabled.' -ForegroundColor Green

function Get-Var($name) {
    $buf = New-Object byte[] 4096
    $attr = 0
    $n = [Uefi.NativeV3]::GetFirmwareEnvironmentVariableExW($name, $EFI_GLOBAL, $buf, $buf.Length, [ref]$attr)
    if ($n -eq 0) { return $null }
    return [pscustomobject]@{ Bytes = $buf[0..($n-1)]; Attributes = $attr }
}

function Remove-Var($name, [uint32]$attr) {
    # Deletion = nSize 0. dwAttributes MUST be the variable's real attributes,
    # otherwise Windows returns 87 ERROR_INVALID_PARAMETER.
    if ([Uefi.NativeV3]::SetFirmwareEnvironmentVariableExW($name, $EFI_GLOBAL, (New-Object byte[] 0), 0, $attr)) { return $true }
    $e1 = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ([Uefi.NativeV3]::SetFirmwareEnvVarPtr($name, $EFI_GLOBAL, [IntPtr]::Zero, 0, $attr)) { return $true }
    $e2 = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Write-Host ("      (byte[] err=$e1, IntPtr err=$e2)") -ForegroundColor DarkGray
    return $false
}

function Set-Var($name, [byte[]]$data, [uint32]$attr) {
    return [Uefi.NativeV3]::SetFirmwareEnvironmentVariableExW($name, $EFI_GLOBAL, $data, $data.Length, $attr)
}

# --- read DriverOrder ---
$ord = Get-Var 'DriverOrder'
if (-not $ord) { Write-Host 'DriverOrder is not present - nothing to do.' -ForegroundColor Yellow; exit 0 }
$ids = @()
for ($i = 0; $i -lt $ord.Bytes.Length; $i += 2) { $ids += [BitConverter]::ToUInt16($ord.Bytes, $i) }
Write-Host ("DriverOrder: " + (($ids | ForEach-Object { 'Driver{0:X4}' -f $_ }) -join ', ')) -ForegroundColor Cyan
Write-Host ("Attributes : 0x{0:X}" -f $ord.Attributes)

# --- describe each entry ---
Write-Host "`nEntries:" -ForegroundColor Cyan
foreach ($id in $ids) {
    $n = 'Driver{0:X4}' -f $id
    $v = Get-Var $n
    if (-not $v) { Write-Host "  $n : <missing>" -ForegroundColor Yellow; continue }
    $b = $v.Bytes
    # EFI_LOAD_OPTION: UINT32 Attributes, UINT16 FilePathListLength, CHAR16 Description[] (null-terminated)
    $desc = ''
    for ($i = 6; $i -lt $b.Length - 1; $i += 2) {
        $ch = [BitConverter]::ToUInt16($b, $i)
        if ($ch -eq 0) { break }
        $desc += [char]$ch
    }
    Write-Host ("  {0} : '{1}'  ({2} bytes)" -f $n, $desc, $b.Length)
}

if (-not $Remove) {
    Write-Host "`nRead-only run. To delete e.g. Driver0001 and Driver0002:" -ForegroundColor DarkGray
    Write-Host "   .\Manage-UefiDrivers.ps1 -Remove 1,2" -ForegroundColor DarkGray
    exit 0
}

# --- delete requested entries ---
Write-Host ''
$keep = @()
foreach ($id in $ids) {
    if ($Remove -contains $id) {
        $n = 'Driver{0:X4}' -f $id
        $v = Get-Var $n
        $a = if ($v) { $v.Attributes } else { 7 }
        if (-not $PSCmdlet.ShouldProcess($n, 'Delete UEFI variable')) { $keep += $id; continue }
        Write-Host "  deleting $n (attr=0x$('{0:X}' -f $a)) ..." -NoNewline
        if (Remove-Var $n $a) { Write-Host ' OK' -ForegroundColor Green }
        else { Write-Host (" FAILED (err {0})" -f [Runtime.InteropServices.Marshal]::GetLastWin32Error()) -ForegroundColor Red; $keep += $id }
    } else {
        $keep += $id
    }
}

# --- rewrite DriverOrder ---
if ($keep.Count -eq 0) {
    Write-Host '  removing DriverOrder (no entries left) ...' -NoNewline
    if (Remove-Var 'DriverOrder' $ord.Attributes) { Write-Host ' OK' -ForegroundColor Green } else { Write-Host ' FAILED' -ForegroundColor Red }
} else {
    $new = New-Object byte[] ($keep.Count * 2)
    for ($i = 0; $i -lt $keep.Count; $i++) { [BitConverter]::GetBytes([uint16]$keep[$i]).CopyTo($new, $i * 2) }
    Write-Host ("  rewriting DriverOrder -> " + (($keep | ForEach-Object { 'Driver{0:X4}' -f $_ }) -join ', ') + ' ...') -NoNewline
    if (Set-Var 'DriverOrder' $new $ord.Attributes) { Write-Host ' OK' -ForegroundColor Green }
    else { Write-Host (" FAILED (err {0})" -f [Runtime.InteropServices.Marshal]::GetLastWin32Error()) -ForegroundColor Red }
}

Write-Host "`nDone. Re-run without -Remove to verify." -ForegroundColor Green
