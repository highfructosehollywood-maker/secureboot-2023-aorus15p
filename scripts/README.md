# Scripts

All scripts are PowerShell and must be run from an **elevated** prompt.

**Execution policy.** On client Windows 10/11 the default is `Restricted`, which
blocks *all* scripts — you'll see "running scripts is disabled on this system". Allow
scripts for the current session only (nothing persistent, no admin policy change):

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Separately, files downloaded from the internet carry a "mark of the web" that can
block them even when the policy allows scripts. Clear it:

```powershell
Get-ChildItem . -Recurse | Unblock-File
```

## Verify-Keys.ps1  — check key integrity (read-only)

Confirms the SHA-256 of every file in `..\keys\` against the known-good hashes for
Microsoft secureboot_objects v1.6.5. Run this before enrolling.

```powershell
.\Verify-Keys.ps1
```

## Test-UefiVarAccess.ps1  — diagnostics (read-only)

Reports `SetupMode` / `SecureBoot`, reads `BootOrder`/`BootCurrent` as control
values, dumps `DriverOrder` + any `Driver####` entries, and shows precise Win32 error
codes for each read. Changes nothing. Run this first in Scenario B.

```powershell
.\Test-UefiVarAccess.ps1
```

## Enroll-SecureBootKeys.ps1  — enroll 2011+2023 keys (Scenario B, Step 2)

Enrolls `db` + `KEK` + `PK` from `..\keys\` while in Setup Mode (raw ESL write, with a
cert-based fallback). PK is written last, which exits Setup Mode. Refuses to run if
the system isn't in Setup Mode. Suspends BitLocker for one reboot.

```powershell
.\Enroll-SecureBootKeys.ps1            # db + KEK + PK (DBX left for Windows Update)
.\Enroll-SecureBootKeys.ps1 -IncludeDbx
```

## Manage-UefiDrivers.ps1  — clean up leftover SREP driver entries (optional)

Lists and removes `Driver####` NVRAM entries that SREP adds, and rewrites
`DriverOrder`. Read-only unless you pass `-Remove`. Supports `-WhatIf` and prompts
for confirmation before each deletion.

The `-Remove` values are **decimal** indices that map to the hex `Driver####` id:
to delete `Driver0001` pass `-Remove 1`; to delete `Driver000A` pass `-Remove 10`.

```powershell
.\Manage-UefiDrivers.ps1               # list only
.\Manage-UefiDrivers.ps1 -Remove 1 -WhatIf     # preview
.\Manage-UefiDrivers.ps1 -Remove 1     # delete Driver0001 (prompts to confirm)
.\Manage-UefiDrivers.ps1 -Remove 1 -Confirm:$false   # delete without prompting
```

Deletion is flagged high-impact, so `-Remove` prompts for confirmation on each entry
by default. Add `-Confirm:$false` for non-interactive runs (otherwise the command
waits at the prompt). Keep at least one entry if you rely on the **Query User** method
to load SREP.

### Notes on the firmware-variable API

`UefiVars.ps1` holds this layer once and is **dot-sourced** by `Test-UefiVarAccess.ps1`
and `Manage-UefiDrivers.ps1` — don't run it directly. It calls
`Get/SetFirmwareEnvironmentVariableExW` and enables `SeSystemEnvironmentPrivilege` in the
process token, so it requires the OS to be booted in **UEFI** mode (the reads are no-ops
on legacy BIOS). Deleting a variable is a zero-size `Set` with the variable's real
attributes — which is why attributes are read before deletion.

Reads return the exact Win32 error alongside the bytes, so callers can tell "the variable
does not exist" (203) apart from "access denied" (5) or "not booted in UEFI mode" (1)
instead of treating every empty read as absence.

One PowerShell trap to know if you edit these scripts: a read that returns a **single `0x00`
byte** — which is exactly `SetupMode` once keys are enrolled — arrives as the one-element
array `@(0)`, and PowerShell unwraps that to the falsy scalar `0`. So callers test
`$null -ne $result.Bytes`, never `if ($result.Bytes)`; the truthy form reports the most
important variable in this repo as unreadable. `Test-UefiVarAccess.ps1` also prints
`SetupMode` through `Get-SecureBootUEFI` as an independent cross-check.
