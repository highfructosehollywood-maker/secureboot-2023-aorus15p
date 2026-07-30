# Scenario B — Secure Boot is OFF / keys erased, and it won't turn back on

**Symptoms:** Secure Boot is disabled. It was probably turned off by **erasing the
keys** (the way this laptop's BIOS "disables" it — e.g. to run SREP and unlock hidden
tabs). Now:

- `Confirm-SecureBootUEFI` returns `False` or errors;
- **"Restore Factory Keys" makes the machine fail to boot** (factory set is 2011-only,
  but your boot manager is signed by 2023 — the [mismatch](00-background.md));
- there is **no Secure Boot toggle** anywhere in the visible BIOS.

**Goal:** put a proper **2011 + 2023** key set back into firmware, then re-enable
Secure Boot — without a BIOS update, and keeping your ability to get back into the
unlocked BIOS if you need it.

> **BitLocker:** suspend it first —
> `Suspend-BitLocker -MountPoint C: -RebootCount 1`. Changing Secure Boot state
> changes PCR 7 and can prompt for your recovery key. `Enroll-SecureBootKeys.ps1`
> also suspends it, but that covers only one reboot.

---

## Overview

1. Confirm you're in Setup Mode and see what signs your boot manager.
2. Enroll the full 2011+2023 key set from Windows (`Enroll-SecureBootKeys.ps1`).
3. Unhide the Secure Boot toggle in the BIOS (this laptop hides it — see
   [aorus-15p-hidden-form.md](aorus-15p-hidden-form.md)).
4. Enable Secure Boot. Keep re-entry to the unlocked BIOS via **Query User**.

---

## Step 1 — Diagnose

Run the diagnostics script (read-only, changes nothing):

```powershell
# from an elevated PowerShell, in the repo's scripts\ folder
Get-ChildItem .\*.ps1 | Unblock-File     # UefiVars.ps1 is dot-sourced, so unblock it too
.\Test-UefiVarAccess.ps1
```

While you're here — and **before** erasing any keys, i.e. while Secure Boot is still
intact — verify the key material you're about to rely on is undamaged:

```powershell
Unblock-File .\Verify-Keys.ps1
.\Verify-Keys.ps1        # all files should report OK
```

You want to confirm three things:

- **Firmware state.** If keys are still present you'll see `SetupMode = 00`; the
  enrollment in Step 2 requires **Setup Mode**, so you must erase the keys in the BIOS
  first (stock Security page → *Delete all Secure Boot variables*, or "erase all keys")
  to reach `SetupMode = 01`. If they're already erased you'll see `SetupMode = 01` and
  can go straight to Step 2. **The script only runs when `SetupMode = 01`; it refuses
  otherwise and writes nothing.**
- `SecureBoot = 00` (enforcement off).
- The boot manager Issuer (see [background](00-background.md)) is
  `Windows UEFI CA 2023` — the reason "Restore Factory Keys" (2011-only) would fail,
  and why we enroll the full set instead.

## Step 2 — Enroll the full 2011 + 2023 key set

This writes `db` (5 certs) + `KEK` (2 certs) + `PK` from Windows while in Setup Mode.
It tries a raw ESL write and falls back to a cert-based enrollment if the firmware
rejects it. **PK is written last**, which exits Setup Mode.

```powershell
Unblock-File .\Enroll-SecureBootKeys.ps1
.\Enroll-SecureBootKeys.ps1            # db + KEK + PK (recommended)
```

> **`-IncludeDbx`:** the script can also enroll the revocation list up front. This
> path was **not tested** on the AORUS 15P XD in this write-up — the tested flow left
> `dbx` empty and let Windows Update populate it after Secure Boot came on. dbx
> additions are hard to undo (see the Scenario A warning), so only use `-IncludeDbx`
> if you know you want it.

Expected tail:

```
Verification:
  db  contains PCA 2011             : True
  db  contains Windows UEFI CA 2023 : True
  kek contains KEK CA 2011          : True
  kek contains KEK 2K CA 2023       : True
```

If the machine wasn't in Setup Mode, the script stops and does nothing. If only the
**PK** write is refused, follow its printed fallback (enroll
`keys\WindowsOEMDevicesPK.der` from BIOS Key Management) — `db`/`KEK` are already in.

Because `db` now holds **both** 2011 and 2023, there is no mismatch: your
2023-signed boot manager is trusted, and the "certificates outdated" warning is gone
too. You do **not** need the Scenario A registry steps.

## Step 3 — Get the Secure Boot toggle back in the BIOS

On the AORUS 15P XD (FB0A) the stock Security page has **no** Secure Boot control —
Gigabyte shipped a trimmed page and dropped the link to the full one. Details and how
this was determined: **[aorus-15p-hidden-form.md](aorus-15p-hidden-form.md)**.

Use **SREP** (Smokeless Runtime EFI Patcher) with the config in
[`srep/SREP_Config.cfg`](../srep/SREP_Config.cfg), which unhides the full **Security**
page (in addition to the Main/Advanced/Chipset pages the original Sweet_Kitten config
already exposed).

1. Build the stick: run `srep\build\Build-SrepUsb.ps1` (Docker required, one command) and
   unpack the resulting `srep\build\work\srep-usb-*.zip` onto a FAT32 stick — the config
   is already inside it. [srep/README.md](../srep/README.md) has the layout and the
   reasoning; in short the stick holds a UEFI Shell, SREP built as a **UEFI driver**, the
   EDK2 regex driver and this repo's `SREP_Config.cfg`. No binaries are shipped in this
   repository, so this step is where they come from.
2. Boot the stick once from the boot menu: the Shell's `startup.nsh` registers SREP as a
   `Driver####` entry. Then reboot **with the stick still in** — the firmware loads SREP
   as a driver, it patches AMITSE in RAM and writes `SREP.log` to the stick. (Driver mode
   is required: the RAM patch has to happen in the same boot in which you open Setup.)
3. **Press <kbd>F2</kbd> while SREP's output is on screen.** Patching does not open the
   BIOS for you: let the log scroll past and the machine boots Windows, taking the patch
   with it, and you need another reboot. Not during the `Press L to write a log`
   countdown at the start, though — SREP reads a key there itself and swallows it.
4. In the BIOS, scroll the tab bar to the **right** (there's a `▶` marker). A second
   **Security** tab appears after the extra Advanced/Chipset tabs.
5. Open it → **Secure Boot** submenu.

## Step 4 — Enable Secure Boot

In that Secure Boot submenu:

- **Secure Boot** → `Enabled`
- **Secure Boot Mode** → leave `Custom` (matches manually enrolled keys)
- **Do NOT** touch *Restore Factory Keys* (2011-only → breaks boot) or *Reset To
  Setup Mode*.

Save & Exit (F10), remove the USB stick, reboot. Verify in Windows:

```powershell
Confirm-SecureBootUEFI      # expect: True
```

On the stock Security page, *"Enroll all Factory Default keys"* will now read
*"Delete all Secure Boot variables"* — a second confirmation it worked, and your way
back to Setup Mode later if ever needed.

## Step 5 — Keep BIOS re-entry without erasing keys (recommended)

Once Secure Boot is on, an **unsigned** SREP driver normally can't load, so the hidden
tabs would be gone — and getting them back would mean erasing keys again. Avoid that
loop with **Image Execution Policy**:

- BIOS → Security → Secure Boot → **Image Execution Policy**
- **Removable Media** → `Query User`

With `Query User`, when you boot the SREP stick the firmware **asks for confirmation**
instead of silently blocking it. You approve, SREP loads, the tabs come back — all
**with Secure Boot still enabled** and **without erasing keys**. (The only other menu
option is `Deny Execute`; AMI doesn't expose `Always Execute` for removable media
here.)

> Trade-off: `Query User` slightly weakens removable-media enforcement (you can
> approve unsigned images at boot). It does **not** disable Secure Boot — the
> `SecureBoot` flag stays `1`. Anti-cheats such as Vanguard that gate on Secure Boot
> being on will still be satisfied *as far as is known at time of writing*, but
> anti-cheat policies change over time, so this isn't a guarantee.

**What to expect on subsequent boots.** With `Query User` set, any time you boot an
*unsigned* removable image — the SREP stick, or any other non-Secure-Boot USB media —
the firmware shows a confirmation prompt before executing it, rather than blocking it
silently. Approve it to continue booting that media; decline to fall through to the
next boot entry. Signed media (a normal Windows installer, for example) boots without
the prompt as usual. So this affects only unsigned USB boots, and only by adding a
one-key confirmation — it does not change how your internal Windows drive boots.

## Cleanup (optional) — leftover SREP driver entries

If your SREP stick is set up as a **UEFI driver** (you'll see `Driver####` entries
named like `srep(...).efi`), each boot can add another one. Duplicates are harmless,
but you can tidy them:

```powershell
Get-ChildItem .\*.ps1 | Unblock-File           # Manage-UefiDrivers dot-sources UefiVars.ps1
.\Manage-UefiDrivers.ps1                       # list only (read-only)
.\Manage-UefiDrivers.ps1 -Remove 1             # delete a duplicate (prompts to confirm)
.\Manage-UefiDrivers.ps1 -Remove 1 -Confirm:$false   # delete without prompting
```

**With the stick this repo builds, keep at least one entry.** That layout loads SREP
*from* the `Driver####` entry during BDS; `EFI/BOOT/BOOTX64.EFI` on it is only the UEFI
Shell that created the entry in the first place (see
[srep/README.md](../srep/README.md)). Delete every entry and SREP stops loading until
you boot the stick and let `startup.nsh` register it again.

Removing all of them is only safe with an *application* build of SREP that you launch by
hand from a shell — not the layout produced here, and not one that can patch AMITSE in
the same boot in which you open Setup.

---

## If you ever need the unlocked BIOS again

You don't have to erase keys. Boot the SREP stick, approve it at the **Query User**
prompt, and the hidden tabs return with Secure Boot still on.

If you *do* end up erasing keys (stock Security → *Delete all Secure Boot variables*),
just re-run **Step 2** to enroll them again — or use BIOS **Key Management** to import
the files from [`keys/`](../keys/): `DB.bin`, `KEK.bin`, and for the Platform Key use
`WindowsOEMDevicesPK.der` (in that order, PK last). Enroll them via *Update* (replace),
not *Append*. The `keys/` files work in both the script and the BIOS.
