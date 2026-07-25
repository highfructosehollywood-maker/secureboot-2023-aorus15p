# SREP config — unhide the full Security page (AORUS 15P XD, FB0A only)

`SREP_Config.cfg` is a config for **SREP (Smokeless Runtime EFI Patcher)** that
un-hides the full **Security** BIOS page on the **AORUS 15P XD** with AMI BIOS
**`FB0A`**, exposing the Secure Boot submenu that Gigabyte's stock firmware hides.

It extends Sweet_Kitten's original AORUS 15P SREP config by one entry: the original
un-hides Main / Advanced / Chipset; this version also un-hides **Security**. See
[../docs/aorus-15p-hidden-form.md](../docs/aorus-15p-hidden-form.md) for exactly what
it patches and why.

## ⚠️ Firmware-specific

The byte pattern in this config is extracted from the **FB0A** AMITSE module. It will
**not** match other models or BIOS versions and must not be used on them. On a
different firmware you need a config built from *that* firmware's table.

The SREP binary itself is **not** firmware-specific — nothing about your machine is
compiled into it. The same `.efi` works on any x64 UEFI system; only the config is
tied to FB0A.

## What the stick actually contains

| File on the stick | What it is |
|---|---|
| `EFI\BOOT\BOOTX64.EFI` | **UEFI Shell** (EDK2). Boots first, runs `startup.nsh`. |
| `startup.nsh` | One-off registration: `bcfg driver add 0 <srep>.efi` → a `Driver####` NVRAM entry. |
| `srep-0.2.3-driver.efi` | SREP, built as a **UEFI driver** (not an application). |
| `Oniguruma.efi` | EDK2 `RegularExpressionDxe`; SREP loads it at start to get `RegularExpressionProtocol`. |
| `SREP_Config.cfg` | The patch itself — this repo's file, already inside the archive. |
| `LICENSES.txt` | Licences of everything on the stick (EDK2 BSD-2-Clause-Patent verbatim). |
| `SREP.log` | Written by SREP on every run (appears after the first boot). |

**Why a driver and not just a bootable app.** The config uses `Op Loaded AMITSE`: it
patches the AMITSE copy that is already resident in RAM, and that patch is gone at the
next reboot. So it has to be applied *in the same boot* in which you open Setup. An
application launched from the Shell can't hand control to Setup without rebooting —
which throws the patch away. A driver listed in `DriverOrder` is loaded during BDS,
before you press <kbd>Del</kbd>, so the tabs are there when Setup opens.

That is also why `scripts/Manage-UefiDrivers.ps1` exists: the `Driver####` entry is
persistent NVRAM state and is removed from Windows when you no longer want it.

## Getting the files: build them

**This repository ships no binaries.** SREP itself carries no licence statement at all
(its author deleted their account in 2022 — details in
[`build/THIRD-PARTY.md`](build/THIRD-PARTY.md)), so redistributing a compiled copy would
be on shaky ground. Instead the build is a single command and fully reproducible:

```powershell
.\build\Build-SrepUsb.ps1                 # Docker is the only requirement
```

It leaves `srep-usb-0.2.3.zip` in `build\work\` (git-ignored). Unpack that to the root of
a FAT32 stick and you are done — the archive **already contains `SREP_Config.cfg`**, so
there is nothing to copy by hand, plus a `LICENSES.txt` covering everything on the stick.

Compare your hashes with [`build/REFERENCE-BUILD.txt`](build/REFERENCE-BUILD.txt): with
the same tags they match exactly, which is what makes "build it yourself" as trustworthy
as a download would have been.

The standalone [`SREP_Config.cfg`](SREP_Config.cfg) next to this file is what you need if
you build or obtain SREP some other way (a different fork, an application build, an
existing stick) — then it is the only file you take from here.

### What the build does

The script builds a small image from [`build/Dockerfile`](build/Dockerfile) (Ubuntu 22.04
with the edk2 build dependencies — the same base as SREP's upstream CI) and runs
everything inside it, so nothing is installed on your machine. The edk2 checkout is
cached in a named docker volume and the archive + hashes land in `build/work/`. First run
pulls ~2 GB and takes 20–40 min; later runs a couple of minutes. `-EdkTag` / `-SrepTag`
override the pinned versions, `-Clean` drops the cache, `-KeepStage` leaves the unpacked
stick layout next to the archive.

What it builds, all `-b RELEASE -t GCC5 -a X64`:

| Output | Source |
|---|---|
| `srep-0.2.3-driver.efi` | [Maxinator500/SmokelessRuntimeEFIPatcher-RUS](https://github.com/Maxinator500/SmokelessRuntimeEFIPatcher-RUS) tag `0.2.3`, checked out as `SREPPkg` (its `.dsc`/`.inf` reference `SREPPkg/…`) |
| `EFI/BOOT/BOOTX64.EFI` | edk2 `ShellPkg/ShellPkg.dsc` → `Shell_EA4BB293-…efi`, the "all commands integrated" shell (the build checks it really has `bcfg`) |
| `Oniguruma.efi` | edk2 `MdeModulePkg/Universal/RegularExpressionDxe` |

The non-binary files on the stick come from the repository: `SREP_Config.cfg` is copied
from [`SREP_Config.cfg`](SREP_Config.cfg), while `startup.nsh` and the stick's `README.txt`
are rendered from [`build/templates/`](build/templates/) (the `@SREP_EFI@` placeholder is
replaced with the built driver's filename).

Pinned versions and why:

- **edk2 `edk2-stable202502`** — SREP's `.dsc` references `StackCheckLib`, which only
  exists in edk2 ≥ `stable202411`. Submodules are required (`OpensslLib` for the
  declared `BaseCryptLib`, `oniguruma` for the regex driver).
- **SREP `0.2.3`** — newest release that builds against stock edk2. `0.2.4` embeds
  `Oniguruma.efi` as an HII image and needs a hand-patch to edk2's BaseTools; `0.1.9`
  and older include `<Protocol/FirmwareVolume.h>`, an EDK1 header edk2 no longer ships.

[`build/patch-srep.py`](build/patch-srep.py) makes four edits to the checkout, each
asserted against exact upstream text so it fails loudly if upstream changes:

1. `.inf`: `MODULE_TYPE` → `UEFI_DRIVER`;
2. `.inf` + `.dsc`: entry-point library → `UefiDriverEntryPoint` (upstream ships both
   as a commented-out pair — this flips the comment);
3. `.c`: default UI language `ru-RU` → `en-GB`. Upstream keeps the language in the
   `SREPLang` NV variable and only switches to English when started as `SREP.efi ENG`
   from the Shell — a driver gets no command line, so without this the console output
   and `SREP.log` would be in Russian;
4. `.dsc`: GCC flags — `-Wno-unknown-pragmas -Wno-missing-braces` (MSVC-only pragmas and
   GUID initialiser macros, which edk2's `-Werror` would reject) and `-fcommon` +
   `-Wl,--allow-multiple-definition` (upstream defines globals in headers that several
   `.c` files include; MSVC's linker merges them, GNU ld does not).

Each build writes the resulting diff next to the archive, and verifies the PE header:
subsystem must be `11` (`EFI_BOOT_SERVICE_DRIVER`), not `10` (application). It also
checks the built shell really contains `bcfg`, since `startup.nsh` depends on it.

**On hashes:** rebuilding with the same tags in the pinned container reproduces the same
bytes (the checkout paths are fixed and edk2's GCC5 toolchain writes a deterministic PE
timestamp) — verified by building repeatedly here, which is why
[`build/REFERENCE-BUILD.txt`](build/REFERENCE-BUILD.txt) can list expected hashes at all.
A build with a different edk2 tag, compiler version or checkout path behaves the same but
hashes differently.

## Preparing the stick

1. FAT32, GPT (MBR also boots on this firmware, GPT/ESP is what SREP's docs assume).
   In an elevated `diskpart` — ⚠️ `clean` erases the whole disk, check `list disk` twice:

   ```
   list disk
   select disk <N>          # your USB stick, NOT an internal drive
   clean
   convert gpt
   create partition primary
   format fs=fat32 quick label=SREP
   assign
   exit
   ```

2. Unpack the archive to the **root** of the stick — config included, nothing else to
   copy. If you add a second config as a backup, rename it so it does **not** end in
   `.cfg` (e.g. `something.cfg.bk`): SREP 0.2.3 uses the first `.cfg` it finds in the root.
3. Boot the stick from the boot menu (<kbd>F12</kbd>). The Shell runs `startup.nsh`,
   which adds the `Driver####` entry and prints the resulting `DriverOrder`.
4. Reboot **with the stick still plugged in**. SREP now loads as a driver, patches
   AMITSE and writes `SREP.log` to the stick.

Step 3 is a one-off; from then on the stick only needs to be plugged in. Two pieces of
firmware state are created: the `Driver####` entry (+ `DriverOrder`), and an NV variable
`SREPLang` that SREP 0.2.x uses to remember its UI language. Both are harmless and the
driver entry is removable from Windows — see the last section.

A successful run leaves lines like these in `SREP.log`:

```
Executing Fast Patch
Finding Pattern
 Offset in section: 0x503B0
Patched
```

## After the stick boots

Once SREP has patched AMITSE, scroll the BIOS tab bar **right** (`▶` marker): a second
**Security** tab appears after the extra Advanced/Chipset tabs → open it →
**Secure Boot**. Then continue with
[Scenario B, Step 4](../docs/scenario-b-stuck-setup-mode.md).

If the pattern doesn't match, SREP reports the failure and continues without applying
it — nothing is damaged. As a fallback you can enable Secure Boot directly from an EFI
shell; see [aorus-15p-hidden-form.md](../docs/aorus-15p-hidden-form.md).

## After Secure Boot is enabled

An unsigned SREP driver won't load once Secure Boot enforces — unless you set
**Image Execution Policy → Removable Media → Query User** (Scenario B, Step 5). With
that, the SREP stick prompts for approval at boot and still loads with Secure Boot on,
so you never have to erase keys just to get back into the unlocked BIOS.

## Removing it again

The patch itself is RAM-only: without the stick the firmware is stock. What persists is
the `Driver####` entry, which you delete from Windows:

```powershell
.\..\scripts\Manage-UefiDrivers.ps1              # list (read-only)
.\..\scripts\Manage-UefiDrivers.ps1 -Remove 1    # delete Driver0001, rewrite DriverOrder
```
