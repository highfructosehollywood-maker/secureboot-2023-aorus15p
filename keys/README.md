# Secure Boot key material (Microsoft `secureboot_objects`)

These files are **redistributed from Microsoft's official
[`secureboot_objects`](https://github.com/microsoft/secureboot_objects) repository**,
release **v1.6.5**, variant **`LegacyFirmwareDefaults`** (plus individual certificates
from `PreSignedObjects`). They are licensed by Microsoft under **BSD-2-Clause-Patent**
and are **not** covered by this repo's MIT license. That licence requires the copyright
notice and conditions to travel with binary redistributions, so Microsoft's own licence
text is kept verbatim next to the files: [`License.txt`](License.txt).

They are included here so the guide is self-contained. For the newest revocation list
(DBX), you can always re-fetch the latest release from upstream.

## Files

| File | Contents |
|---|---|
| `DB.bin`  | raw EFI_SIGNATURE_LIST: Windows Production PCA 2011 + Windows UEFI CA 2023 + Microsoft UEFI CA 2011 + Microsoft UEFI CA 2023 + Microsoft Option ROM UEFI CA 2023 (5 certs) |
| `KEK.bin` | raw EFI_SIGNATURE_LIST: Microsoft KEK CA 2011 + Microsoft KEK 2K CA 2023 |
| `PK.bin`  | raw EFI_SIGNATURE_LIST: Windows OEM Devices PK (Microsoft shared PK) |
| `DBX.bin` | raw EFI_SIGNATURE_LIST: current Microsoft revocation list |
| `WindowsOEMDevicesPK.der` | the PK as a plain X.509 certificate, for manual enrollment via BIOS Key Management |
| `certs/`  | individual `.der` certificates used by the script's cert-based fallback enrollment path |

## SHA-256

| File | SHA-256 |
|---|---|
| `DB.bin` | `82569e1d45ff5fd40ab861e562113421410649e436f6bb0b6445310cf7a8c018` |
| `KEK.bin` | `cc3a5dbc7b3aec3b60c0da33510bf93f402479bbf445dc360e6111afa70c6342` |
| `PK.bin` | `485aca0cb5f875572c905e6f19ec0a249cf438b005a3e27257ac4bd3f56777bd` |
| `DBX.bin` | `140da251d008f95069c2412b1e432e392b1a2988845a0aebbcaac9ed2cc03716` |
| `WindowsOEMDevicesPK.der` | `2f569e8edaf9657dc4951c29598725255c7f821472db71374211fe44d082546f` |

## A note on the Platform Key (PK)

`PK.bin` / `WindowsOEMDevicesPK.der` is Microsoft's **Windows OEM Devices PK** — a
*shared* Platform Key that Microsoft publishes for exactly this kind of recovery.
Enrolling it means the root of trust for your platform becomes that Microsoft-held
key, not one you (or Gigabyte) control. In practice that means you can't sign your own
KEK updates. For a personal laptop whose goal is simply "pass Secure Boot again with
the Microsoft trust chain," this is a reasonable and common choice.

If you'd rather **own your platform's root of trust**, the alternative is to generate
your own PK (and optionally KEK) and enroll that instead of `PK.bin`, keeping the
Microsoft `db`/`KEK` certificates so Windows still boots. That's more involved and out
of scope here; search for "custom Secure Boot keys" / `sbctl` / `KeyTool`. This repo
uses the Microsoft shared PK to keep the recovery simple.

## Enrollment order

Always enroll **db → KEK → PK** (PK last — writing PK exits Setup Mode). DBX is
optional; Windows Update populates it automatically once Secure Boot is on. The
`scripts/Enroll-SecureBootKeys.ps1` helper does this for you and verifies the result.

## Verifying integrity

Run [`scripts/Verify-Keys.ps1`](../scripts/Verify-Keys.ps1) to check the SHA-256 of
every file here — both the four `.bin` payloads / PK `.der`, and all eight
certificates under `certs/` used by the enrollment fallback path.

## Verifying against upstream

Download `edk2-x64-secureboot-binaries` from the
[v1.6.5 release](https://github.com/microsoft/secureboot_objects/releases/tag/v1.6.5)
and compare `LegacyFirmwareDefaults/Firmware/Default3PDb.bin` (→ `DB.bin`),
`DefaultKek.bin` (→ `KEK.bin`), `DefaultPk.bin` (→ `PK.bin`), `DefaultDbx.bin`
(→ `DBX.bin`). The individual certs come from `PreSignedObjects/`.
