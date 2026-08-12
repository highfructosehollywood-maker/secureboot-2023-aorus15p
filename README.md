# Secure Boot 2023 Certificate Recovery — AORUS 15P XD (AMI FB0A)

Practical guide and tooling for the Microsoft **Windows UEFI CA 2023** Secure Boot
transition on the **Gigabyte AORUS 15P XD** laptop, where no BIOS update is
available and the stock Security page hides the Secure Boot controls.

It covers two situations people hit after Windows updates started rolling out the
2023 certificates:

- **[Scenario A](docs/scenario-a-secureboot-on-warning.md)** — Secure Boot is still
  **enabled**, but Windows shows a warning that the Secure Boot certificates are out
  of date / expiring. *No key erasure, no BIOS trip — this is the easy one.*
- **[Scenario B](docs/scenario-b-stuck-setup-mode.md)** — Secure Boot was **disabled
  / keys were erased** (often to unlock hidden BIOS tabs) and now it **won't turn
  back on**: "Restore Factory Keys" fails to boot, and there is no Secure Boot toggle
  in the visible BIOS. *This repo's main reason to exist.*

> This grew out of an [r/gigabyte thread](https://www.reddit.com/r/gigabyte/comments/1ubzexr/aorus_15p_xd_secure_boot_help/)
> where users diagnosed the 2011/2023 certificate mismatch. Full credit in
> [ATTRIBUTION](#attribution).

---

## ⚠️ Read before doing anything

- **This is written for one specific firmware: AMI BIOS `FB0A` (`X5LVD`), as shipped
  on the AORUS 15P XD.** What has to match is the **BIOS build, not the model badge**
  — the same `FB0A` image ships on other 15P variants, which differ mainly in their
  Nvidia chip. On a *different BIOS version* the UEFI variable offsets, form IDs and
  the SREP pattern will all differ, and blindly copying them can leave a machine
  unbootable. The *concepts* transfer; the *exact bytes* do not.
  *Reported working unmodified on an **AORUS 15P YD** running the same `FB0A` BIOS,
  by u/Maurarg, who checked the patterns against their own firmware first.*
- **"Restore Factory Keys" and "Enroll all Factory Default keys" are the same trap.**
  The first is on the hidden Secure Boot page, the second on the stock Security page
  — the only one you can reach before unhiding anything. Both provision the factory
  set, which on this laptop holds only the **2011** certificate. If your Windows boot
  manager is already signed by **Windows UEFI CA 2023** (very likely by now), that set
  cannot verify it and the machine fails to boot. Use the full 2011+2023 set from this
  repository instead.
- **Suspend BitLocker before changing Secure Boot state or keys**
  (`Suspend-BitLocker -MountPoint C: -RebootCount 1`). Otherwise you may be asked
  for your recovery key on the next boot. Know where your key is either way.
- Everything here is **fully reversible**: erasing Secure Boot keys in the BIOS
  returns you to Setup Mode, exactly where you started.
- Provided **as-is, at your own risk**. See [LICENSE](LICENSE). The authors are not
  responsible for bricked boots, lost recovery keys, or firmware quirks.

---

## Which scenario am I in?

Run this in an **elevated PowerShell**:

```powershell
# 1) Is Secure Boot currently on?
Confirm-SecureBootUEFI      # True = on, False = off, error = no keys / setup mode

# 2) What signs your Windows boot manager?
mountvol X: /s
(Get-AuthenticodeSignature 'X:\EFI\Microsoft\Boot\bootmgfw.efi').SignerCertificate.Issuer
mountvol X: /d
```

| `Confirm-SecureBootUEFI` | Meaning | Go to |
|---|---|---|
| `True` | Secure Boot on; you just want the warning gone | **[Scenario A](docs/scenario-a-secureboot-on-warning.md)** |
| `False` / error | Secure Boot off, keys erased, can't re-enable | **[Scenario B](docs/scenario-b-stuck-setup-mode.md)** |

If the boot-manager **Issuer** is `Windows UEFI CA 2023`, you are on the 2023 path
and must **not** restore 2011-only keys (relevant mainly to Scenario B).

New to the whole thing? Start with **[background](docs/00-background.md)**.

---

## Repository layout

```
docs/
  00-background.md                     Why this happens: 2011 expiry, the mismatch
  scenario-a-secureboot-on-warning.md  Secure Boot ON: clear the warning
  scenario-b-stuck-setup-mode.md       Secure Boot OFF/erased: full recovery
  aorus-15p-hidden-form.md             Why the Secure Boot menu is hidden + how it was found
keys/                                  Microsoft default key set (BSD-2-Clause-Patent)
  DB.bin KEK.bin PK.bin DBX.bin        raw EFI_SIGNATURE_LIST payloads
  WindowsOEMDevicesPK.der              PK as a plain cert (for BIOS Key Management)
  certs/                               individual .der certs (fallback enrollment path)
  License.txt                          Microsoft's licence, kept verbatim with the files
scripts/
  Enroll-SecureBootKeys.ps1            Scenario B: enroll 2011+2023 from Setup Mode
  Verify-Keys.ps1                      Check SHA-256 of the key files (run before enrolling)
  Test-UefiVarAccess.ps1               Diagnostics: read SecureBoot/SetupMode/keys
  Manage-UefiDrivers.ps1               Clean up leftover SREP Driver#### NVRAM entries
  UefiVars.ps1                         Shared firmware-variable helpers (dot-sourced, not run)
srep/
  SREP_Config.cfg                      Unhide the full Security page (AORUS 15P XD FB0A only)
  build/                               Build the stick contents from source (Docker + EDK2)
    Build-SrepUsb.ps1                  One command: builds Shell + SREP driver + regex driver
    Dockerfile  build.sh               Build container (Ubuntu 22.04 + edk2 deps) and its script
    templates/                         startup.nsh + stick README that go into the archive
    REFERENCE-BUILD.txt                Pinned commits + expected SHA-256 of a correct build
    THIRD-PARTY.md                     Provenance and licence of everything the build produces
    work/                              Build output (git-ignored): srep-usb-*.zip lands here
```

No third-party binaries are committed here: `Build-SrepUsb.ps1` builds the stick contents
on your machine, reproducibly, and the archive it makes already includes the config.

The key material is a copy of Microsoft's
[`secureboot_objects`](https://github.com/microsoft/secureboot_objects) v1.6.5
(`LegacyFirmwareDefaults`), kept here so the guide is self-contained. For the
newest DBX you can always re-fetch from upstream.

---

## Attribution

- **Microsoft** — the Secure Boot key objects in `keys/`
  ([secureboot_objects](https://github.com/microsoft/secureboot_objects),
  BSD-2-Clause-Patent).
- **SmokelessCPUv2** — **SREP** (Smokeless Runtime EFI Patcher), the tool that unhides
  BIOS forms, and **[Maxinator500](https://github.com/Maxinator500/SmokelessRuntimeEFIPatcher-RUS)**
  for the maintained fork that added most of what this
  repository relies on. The original author's repository is gone (account deleted in
  2022); `srep/build/` builds the binary from
  [our fork](https://github.com/djwinston/SmokelessRuntimeEFIPatcher) of that fork — see
  [srep/build/THIRD-PARTY.md](srep/build/THIRD-PARTY.md) for the licence situation.
- **TianoCore/EDK2** — the UEFI Shell and `RegularExpressionDxe` on the stick
  (BSD-2-Clause-Patent).
- **Sweet_Kitten** — the original AORUS 15P SREP config that this repo's
  `SREP_Config.cfg` extends (adds the Security page).
- **[u/Training-Honey9821](https://www.reddit.com/user/Training-Honey9821/)** — for
  posting the [r/gigabyte thread](https://www.reddit.com/r/gigabyte/comments/1ubzexr/aorus_15p_xd_secure_boot_help/)
  this repository grew out of, and everyone in it who worked out the 2011/2023
  boot-manager mismatch that pointed the way.
- **[u/Maurarg](https://www.reddit.com/user/Maurarg/)** — for confirming the whole
  procedure on an AORUS 15P YD with the same `FB0A` BIOS, having first checked the
  config's patterns against that firmware. That report is what established the
  BIOS build, not the model, as the thing that has to match.

If you were involved and want different credit (or none), open an issue.

## License

Documentation and scripts in this repo: **MIT** (see [LICENSE](LICENSE)).
Files under `keys/` are Microsoft's, licensed **BSD-2-Clause-Patent**
(see [keys/README.md](keys/README.md) and [keys/License.txt](keys/License.txt)). No
third-party executable is distributed here; what `srep/build/` builds on your machine
keeps its own terms — see
[srep/build/THIRD-PARTY.md](srep/build/THIRD-PARTY.md).
