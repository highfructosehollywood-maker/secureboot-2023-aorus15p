# Test-UefiVarAccess.ps1  - diagnostics only, changes nothing.
# Run as Administrator.

$ErrorActionPreference = 'Stop'
$EFI_GLOBAL = '{8be4df61-93ca-11d2-aa0d-00e098032b8c}'

if (-not ('UefiDiag.NV2' -as [type])) {
Add-Type -Namespace UefiDiag -Name NV2 -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern uint GetFirmwareEnvironmentVariableExW(string lpName, string lpGuid, byte[] pBuffer, uint nSize, out uint pdwAttributes);

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

$ErrTable = @{
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
function E($c) { if ($ErrTable.ContainsKey($c)) { "$c = $($ErrTable[$c])" } else { "$c" } }

# --- 0. context ---
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
"Administrator      : $admin"
"PSVersion          : $($PSVersionTable.PSVersion)"
"Process bitness    : $([IntPtr]::Size * 8)-bit"
$fw = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name PEFirmwareType -ErrorAction SilentlyContinue).PEFirmwareType
"PEFirmwareType     : $fw  (2 = UEFI, 1 = legacy BIOS)"
try { "Confirm-SecureBootUEFI : $(Confirm-SecureBootUEFI)" } catch { "Confirm-SecureBootUEFI : (error: $($_.Exception.Message))" }

# --- 1. privilege, checked properly ---
$tok = [IntPtr]::Zero
$ok = [UefiDiag.NV2]::OpenProcessToken([UefiDiag.NV2]::GetCurrentProcess(), 0x28, [ref]$tok)
"OpenProcessToken   : $ok"
$luid = 0L
$ok = [UefiDiag.NV2]::LookupPrivilegeValueW($null, 'SeSystemEnvironmentPrivilege', [ref]$luid)
"LookupPrivilege    : $ok  (luid=$luid)"
$tp = New-Object UefiDiag.NV2+TP
$tp.Count = 1; $tp.Luid = $luid; $tp.Attr = 2
$ok = [UefiDiag.NV2]::AdjustTokenPrivileges($tok, $false, [ref]$tp, 0, [IntPtr]::Zero, [IntPtr]::Zero)
$le = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
"AdjustTokenPriv    : returned=$ok  lastError=$(E $le)"
if ($le -eq 1300) {
    Write-Host 'PRIVILEGE WAS NOT GRANTED - the reads below will fail.' -ForegroundColor Red
}

# --- 2. read several variables, report exact errors ---
function Try-Read($name) {
    $buf = New-Object byte[] 4096
    $attr = 0
    [Runtime.InteropServices.Marshal]::GetLastWin32Error() | Out-Null
    $n = [UefiDiag.NV2]::GetFirmwareEnvironmentVariableExW($name, $EFI_GLOBAL, $buf, $buf.Length, [ref]$attr)
    $lastErr = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($n -gt 0) {
        $hex = (($buf[0..([Math]::Min($n,32)-1)]) | ForEach-Object { '{0:x2}' -f $_ }) -join ' '
        "{0,-14} : {1,4} bytes  attr=0x{2:X}  [{3}]" -f $name, $n, $attr, $hex
    } else {
        "{0,-14} : FAILED   {1}" -f $name, (E $lastErr)
    }
}

""
"--- control reads (BootOrder/BootCurrent should always work) ---"
Try-Read 'BootOrder'
Try-Read 'BootCurrent'
Try-Read 'SetupMode'
Try-Read 'SecureBoot'
""
"--- what we actually care about ---"
Try-Read 'DriverOrder'
Try-Read 'Driver0000'
Try-Read 'Driver0001'
Try-Read 'Driver0002'
""
"--- cross-check via bcdedit (independent of this API) ---"
try { (bcdedit /enum firmware 2>&1 | Select-String -Pattern 'srep|identifier|description' | Select-Object -First 40) }
catch { "bcdedit failed: $_" }
