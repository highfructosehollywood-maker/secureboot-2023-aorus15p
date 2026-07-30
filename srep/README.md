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
| `srep-0.2.3b-driver.efi` | SREP, built as a **UEFI driver** (not an application). |
| `Oniguruma.efi` | EDK2 `RegularExpressionDxe`; SREP loads it at start to get `RegularExpressionProtocol`. |
| `SREP_Config.cfg` | The patch itself — this repo's file, already inside the archive. |
| `LICENSES.txt` | Licences of everything on the stick (EDK2 BSD-2-Clause-Patent verbatim). |
| `SREP.log` | Written by SREP on every run (appears after the first boot). |

**Why a driver and not just a bootable app.** The config uses `Op Loaded AMITSE`: it
patches the AMITSE copy that is already resident in RAM, and that patch is gone at the
next reboot. So it has to be applied *in the same boot* in which you open Setup. An
application launched from the Shell can't hand control to Setup without rebooting —
which throws the patch away. A driver listed in `DriverOrder` is loaded during BDS,
before you press <kbd>F2</kbd>, so the tabs are there when Setup opens.

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

It leaves `srep-usb-0.2.3b.zip` in `build\work\` (git-ignored). Unpack that to the root of
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
| `srep-0.2.3b-driver.efi` | [djwinston/SmokelessRuntimeEFIPatcher](https://github.com/djwinston/SmokelessRuntimeEFIPatcher) tag `0.2.3b`, checked out as `SREPPkg` (its `.dsc`/`.inf` reference `SREPPkg/…`) |
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
- **SREP `0.2.3b`** — our fork of upstream `0.2.3`, which is the newest release that
  builds against stock edk2. `0.2.4` embeds `Oniguruma.efi` as an HII image and needs a
  hand-patch to edk2's BaseTools; `0.1.9` and older include `<Protocol/FirmwareVolume.h>`,
  an EDK1 header edk2 no longer ships.

The SREP source is **built unmodified from a tag** — nothing is patched during the build.
Relative to upstream `0.2.3` the tag is a driver build with an English UI, GCC build
flags, and a set of memory-safety fixes; `git log 0.2.3..0.2.3b` in
[djwinston/SmokelessRuntimeEFIPatcher](https://github.com/djwinston/SmokelessRuntimeEFIPatcher)
has the reasoning for each.

Two of those fixes are worth knowing about even if you never read the source, because they
decide what happens when something goes wrong on *your* machine rather than on the one this
config was written for:

- both pattern-scan loops ended at `i < ImageSize - ARG6` in `UINTN` arithmetic, which wraps
  when the pattern is longer than the image and sends the scan past the end of it — in BDS,
  where an unmapped page is a hang and not an error message;
- when the preceding `Op Loaded` failed to find its target, the patch step called `FreePool`
  on the loaded-image protocol structure, which belongs to the firmware and was never a pool
  allocation, and then read from it. That is exactly the path a machine takes when the module
  name does not match — i.e. any firmware other than FB0A.

Neither was reachable with a *successful* run of this repository's config, and the second is
the reason the "nothing is damaged" promise further down is now literally true rather than
true in practice.

The build refuses to run if the checkout is dirty, and re-clones it when the cached copy
is not the requested repo + tag. It then verifies the PE header — subsystem must be `11`
(`EFI_BOOT_SERVICE_DRIVER`), not `10` (application) — and checks the built shell really
contains `bcfg`, since `startup.nsh` depends on it.

**On hashes:** rebuilding with the same tags in the pinned container reproduces the same
bytes, which is what lets [`build/REFERENCE-BUILD.txt`](build/REFERENCE-BUILD.txt) list
expected hashes at all. Three things make that true: the checkout paths are fixed, edk2's
GCC5 toolchain zeroes the PE timestamp, and `build.sh` **pins the stack cookie**.

That last one is worth knowing about, because without it the driver is not reproducible at
all. edk2 ≥ `stable202411` gives every module a stack cookie, and `build.py` seeds it with
100 random values per platform, from which AutoGen picks one by a Python string hash — so
the value baked into `.data` changes on every recompile. SREP's `.dsc` maps the real
`StackCheckLib` (that is why it needs edk2 ≥ `stable202411`), while `ShellPkg` and
`MdeModulePkg` do not — which is exactly why only the SREP image drifted while the shell
and the regex driver stayed byte-identical. `build.sh` writes a one-element cookie list, so
the value is fixed and the modulo index cannot vary either, then asserts that the pin
actually reached `AutoGen.h`. A fixed canary in a local, unsigned pre-boot driver costs
nothing an attacker on that path did not already have; verifiability is worth more.

A build with a different edk2 tag, compiler version or checkout path behaves the same but
hashes differently.

## Preparing the stick

1. Give the stick **one FAT32 partition**. That is the whole requirement — UEFI firmware
   reads FAT, and it launches `\EFI\BOOT\BOOTX64.EFI` from it. No ISO-writing tool, no
   boot flag, no special partition type is involved. GPT is what SREP's docs assume; MBR
   boots just as well on this firmware. Pick whichever of these you are comfortable with:

   **`diskpart`** (built in, most predictable) — elevated prompt. ⚠️ `clean` erases the
   whole disk, so check `list disk` twice and make sure `<N>` is the stick:

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

   **Disk Management** (built in, graphical) — <kbd>Win</kbd>+<kbd>X</kbd> → *Disk
   Management*, or `diskmgmt.msc`. Right-click each existing partition on the stick →
   *Delete Volume*; right-click the unallocated space → *New Simple Volume* → next
   through → **File system: FAT32**, *Quick format*, label `SREP`. To also switch the
   partition table, right-click the disk name on the left (*Disk N*) → *Convert to
   GPT Disk* — that option only lights up while the disk has no partitions.

   **A partition manager** (MiniTool Partition Wizard, AOMEI Partition Assistant,
   GParted…) — delete the existing partitions, create one primary FAT32 partition, apply.

   > **64 GB+ sticks:** *every* built-in Windows tool refuses to create a FAT32 volume
   > larger than 32 GB — Explorer and Disk Management then offer only NTFS/exFAT, which
   > this firmware cannot read, and `diskpart` answers *"The volume size is too big."*
   > Either use a third-party manager, which has no such limit, or simply make the
   > partition small: in the `diskpart` recipe above replace `create partition primary`
   > with `create partition primary size=8192` (8 GB). The stick contents are ~1.6 MB, so
   > the leftover space costs you nothing.

   If the stick is already a single FAT32 volume of 32 GB or less, plain **Explorer →
   right-click → Format → FAT32 → Quick Format** is enough; nothing else needs changing.

2. Unpack the archive to the **root** of the stick — config included, nothing else to
   copy. If you add a second config as a backup, rename it so it does **not** end in
   `.cfg` (e.g. `something.cfg.bk`): SREP 0.2.x uses the first `.cfg` it finds in the root.

   > **Re-using a stick built before the fork switch:** the driver is now called
   > `srep-0.2.3b-driver.efi`, not `srep-0.2.3-driver.efi`. A `Driver####` entry
   > registered earlier points at the old filename, so it silently does nothing once the
   > stick holds the new build. Delete the stale files, redo step 3 to register the new
   > name, and drop the old entry from Windows with
   > `scripts\Manage-UefiDrivers.ps1 -Remove <n>`.
3. Boot the stick from the boot menu (<kbd>F12</kbd>). The Shell runs `startup.nsh`,
   which adds the `Driver####` entry and prints the resulting `DriverOrder`.
4. Reboot **with the stick still plugged in**. SREP now loads as a driver, patches
   AMITSE and writes `SREP.log` to the stick.
5. **Press <kbd>F2</kbd> while SREP's output is on screen** to enter Setup. This is the
   step people miss: patching does not open the BIOS by itself. If you just watch the log
   scroll past, boot continues and Windows starts — with the patch gone, because it only
   ever existed in this boot's copy of AMITSE. Then it is another reboot to try again.

   Do not press it during the `Press L to write a log` countdown at the very start: SREP
   reads a keystroke there itself, and an <kbd>F2</kbd> pressed in that window is swallowed
   instead of reaching the firmware. Wait for the patch lines, then press it.

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

## Once Setup opens

Scroll the BIOS tab bar **right** (`▶` marker): a second
**Security** tab appears after the extra Advanced/Chipset tabs → open it →
**Secure Boot**. Then continue with
[Scenario B, Step 4](../docs/scenario-b-stuck-setup-mode.md).

If the pattern doesn't match, SREP reports the failure and continues without applying
it — nothing is damaged, and since `0.2.3b` that holds for the code path as well, not just
for the firmware image. As a fallback you can enable Secure Boot directly from an EFI
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
