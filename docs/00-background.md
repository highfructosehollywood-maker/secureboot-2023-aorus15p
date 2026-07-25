# Background: the 2011 → 2023 Secure Boot certificate transition

## The short version

Secure Boot trusts firmware-stored certificates. The originals, issued by Microsoft
in 2011, **expire in 2026**. Microsoft is rolling out replacements — **Windows UEFI
CA 2023** (for the boot components in `db`) and **Microsoft Corporation KEK 2K CA
2023** (in `KEK`). Windows delivers these firmware updates gradually. On machines
where that rollout stalls, or where someone erased the keys, you can end up with a
warning or a machine that won't turn Secure Boot back on.

## Where the certificates actually live

Secure Boot keys are **not** part of the BIOS image (the flash ROM). They live in
**NVRAM UEFI variables** that the firmware merely reads:

| Variable | Role |
|---|---|
| `PK`  | Platform Key — root of trust, controls who may change KEK |
| `KEK` | Key Exchange Keys — controls who may change db/dbx |
| `db`  | allowed signatures — what is permitted to boot |
| `dbx` | forbidden signatures — revocation list |

Because these are just authenticated variables, they can be written from Windows
(`Set-SecureBootUEFI`) or from the BIOS, **without a firmware update**. A BIOS update
from the vendor would only change the *factory defaults* that "Restore Factory Keys"
loads — it is not required to get the 2023 certificates onto the machine.

Two firmware state flags matter:

- **`SetupMode`** — `1` when `PK` is undefined. In this state the firmware accepts
  unsigned variable writes, and Secure Boot cannot be enforced.
- **`SecureBoot`** — `1` when enforcement is actually active.

## The mismatch that breaks booting

As part of the transition, a Windows update can replace your on-disk boot manager
(`\EFI\Microsoft\Boot\bootmgfw.efi`) with a copy signed by **Windows UEFI CA 2023**.

If your firmware `db` still contains **only the 2011** certificate, you now have:

```
boot manager signed by:  Windows UEFI CA 2023
db trusts only:          Windows Production PCA 2011
                         => signature not trusted => Secure Boot blocks boot
```

This is exactly what "Restore Factory Keys" triggers on the AORUS 15P XD, whose
factory set is 2011-only. The fix is to make sure `db` contains **both** 2011 **and**
2023 certificates. That is what the `keys/` set in this repo does.

## How to check which certificate signs your boot manager

Elevated PowerShell:

```powershell
mountvol X: /s
(Get-AuthenticodeSignature 'X:\EFI\Microsoft\Boot\bootmgfw.efi').SignerCertificate.Issuer
mountvol X: /d
```

- `CN=Microsoft Windows Production PCA 2011` → old signing; 2011 keys still boot it.
- `CN=Windows UEFI CA 2023` → new signing; you need 2023 in `db` (most machines by now).

## How to check what's currently in your firmware

```powershell
# is 2023 already trusted in db?
[System.Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI db).bytes)  -match 'Windows UEFI CA 2023'
[System.Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI kek).bytes) -match 'KEK 2K CA 2023'

# state flags: SetupMode and SecureBoot are readable at runtime (these work here).
# Note: Get-SecureBootUEFI -Name PK errors when PK is undefined (erased/setup mode) -
# that's a property of PK, not of SetupMode/SecureBoot.
"SetupMode  = $((Get-SecureBootUEFI -Name SetupMode).bytes[0])"
"SecureBoot = $((Get-SecureBootUEFI -Name SecureBoot).bytes[0])"
```

From here:

- Secure Boot **on**, warning about outdated certs → **[Scenario A](scenario-a-secureboot-on-warning.md)**.
- Secure Boot **off / keys erased**, can't re-enable → **[Scenario B](scenario-b-stuck-setup-mode.md)**.

## References

- Microsoft KB5062710 — [Windows Secure Boot certificate expiration and CA updates](https://support.microsoft.com/en-us/servicing/os/secure-boot/2025/06/windows-secure-boot-certificate-expiration-and-ca-updates) (the page the Windows Security notice links to).
- Microsoft KB5025885 — managing Windows Boot Manager revocations (CVE-2023-24932).
- Microsoft KB5053484 — [Updating Windows bootable media to use the PCA2023 signed boot manager](https://support.microsoft.com/en-us/servicing/os/windows/2025/02/updating-windows-bootable-media-to-use-the-pca2023-signed-boot-manager) (re-issue recovery media broken by dbx revocations).
- Microsoft: *Registry key updates for Secure Boot* (the `AvailableUpdates` bitmask).
- Microsoft `secureboot_objects` repository (the key material).
