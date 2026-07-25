# Verify-Keys.ps1
# Verifies the SHA-256 of the key material in ..\keys\ against the known-good
# hashes for Microsoft secureboot_objects v1.6.5 (LegacyFirmwareDefaults).
# Read-only. Run from anywhere.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$keys = Join-Path (Split-Path -Parent $here) 'keys'

$expected = @{
    'DB.bin'                  = '82569E1D45FF5FD40AB861E562113421410649E436F6BB0B6445310CF7A8C018'
    'KEK.bin'                 = 'CC3A5DBC7B3AEC3B60C0DA33510BF93F402479BBF445DC360E6111AFA70C6342'
    'PK.bin'                  = '485ACA0CB5F875572C905E6F19EC0A249CF438B005A3E27257AC4BD3F56777BD'
    'DBX.bin'                 = '140DA251D008F95069C2412B1E432E392B1A2988845A0AEBBCAAC9ED2CC03716'
    'WindowsOEMDevicesPK.der' = '2F569E8EDAF9657DC4951C29598725255C7F821472DB71374211FE44D082546F'
}

# Individual certificates used by the enrollment fallback path (keys/certs/).
$expectedCerts = @{
    'MicCorKEKCA2011.der'             = 'A1117F516A32CEFCBA3F2D1ACE10A87972FD6BBE8FE0D0B996E09E65D802A503'
    'MicCorUEFCA2011.der'             = '48E99B991F57FC52F76149599BFF0A58C47154229B9F8D603AC40D3500248507'
    'MicWinProPCA2011.der'            = 'E8E95F0733A55E8BAD7BE0A1413EE23C51FCEA64B3C8FA6A786935FDDCC71961'
    'MicrosoftKEK2KCA2023.der'        = '3CD3F0309EDAE228767A976DD40D9F4AFFC4FBD5218F2E8CC3C9DD97E8AC6F9D'
    'MicrosoftOptionRomUEFICA2023.der'= 'E5BE3E64C6E66A281457ECDECE0D6D0787577AAD2A3A0144262C10C14BA8D8F1'
    'MicrosoftUEFICA2023.der'         = 'F6124E34125BEE3FE6D79A574EAA7B91C0E7BD9D929C1A321178EFD611DAD901'
    'WindowsOEMDevicesPK.der'         = '2F569E8EDAF9657DC4951C29598725255C7F821472DB71374211FE44D082546F'
    'WindowsUEFICA2023.der'           = '076F1FEA90AC29155EBF77C17682F75F1FDD1BE196DA302DC8461E350A9AE330'
}

$allOk = $true

function Check-Hash($name, $path, $want) {
    if (-not (Test-Path $path)) { Write-Host "  $name : MISSING" -ForegroundColor Red; return $false }
    $actual = (Get-FileHash -Algorithm SHA256 -Path $path).Hash
    if ($actual -eq $want) { Write-Host "  $name : OK" -ForegroundColor Green; return $true }
    Write-Host "  $name : MISMATCH" -ForegroundColor Red
    Write-Host "      expected $want"   -ForegroundColor DarkGray
    Write-Host "      actual   $actual" -ForegroundColor DarkGray
    return $false
}

Write-Host 'keys/' -ForegroundColor Cyan
foreach ($name in ($expected.Keys | Sort-Object)) {
    if (-not (Check-Hash $name (Join-Path $keys $name) $expected[$name])) { $allOk = $false }
}

Write-Host 'keys/certs/' -ForegroundColor Cyan
foreach ($name in ($expectedCerts.Keys | Sort-Object)) {
    if (-not (Check-Hash $name (Join-Path (Join-Path $keys 'certs') $name) $expectedCerts[$name])) { $allOk = $false }
}

Write-Host ''
if ($allOk) { Write-Host 'All key files match the expected hashes.' -ForegroundColor Green; exit 0 }
else { Write-Host 'One or more files did not match. Do NOT enroll these until resolved.' -ForegroundColor Red; exit 1 }
