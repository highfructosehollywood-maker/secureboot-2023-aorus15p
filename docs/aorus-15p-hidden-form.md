# Why the Secure Boot menu is hidden on the AORUS 15P XD (and how it was found)

This is the "show your work" appendix. None of it is needed to follow the guide, but
it explains *why* the SREP config is built the way it is, and documents the
firmware-specific values so others can verify them.

> All values below were extracted from the **official Gigabyte AORUS 15P XD BIOS
> `FB0A` (`X5LVD`)** image, obtained from Gigabyte's support site and parsed locally.
> The firmware image itself is **not** redistributed in this repo — it's Gigabyte's
> copyrighted code. Only factual descriptors (GUIDs, offsets, form IDs) are listed.

## The stock Security page is a trimmed copy

The Setup module contains **two** forms titled "Security":

| Form ID | Title | Contents |
|---|---|---|
| `0x2714` | Security (stock) | Passwords, System Mode, and *Enroll all Factory Default keys* / *Delete all Secure Boot variables*. **No link to the Secure Boot page.** |
| `0x271a` | Security (full)  | Passwords **plus a link to the full Secure Boot form** `0x2978`. |

The tab you normally see is `0x2714`. It has **no reference** to the Secure Boot form
`0x2978` — so the Secure Boot page isn't hidden by a `suppress-if` condition, it's
simply **orphaned**: nothing links to it. That's why a form-condition patcher alone
doesn't reveal it; the *link* has to be restored, which is what unhiding the full
Security form `0x271a` does.

The full Secure Boot form `0x2978` itself is complete and present: Secure Boot toggle,
Secure Boot Mode, Restore Factory Keys, Reset To Setup Mode, Key Management, Image
Execution Policy.

## The Secure Boot toggle variable

The toggle is a UEFI variable, reachable from an EFI shell (it is boot-services-only,
so it is not accessible once the OS is running):

- **Variable:** `SecureBootSetup`
- **GUID:** `7B59104A-C00D-4158-87FF-F04D6396A915`
- **Attributes:** `NV+BS` (non-volatile, boot-services-only — no runtime access)
- **Size:** `0x7` bytes

Two separate reasons this variable is not reachable the "normal" way from Windows:
first, `Set-SecureBootUEFI` only ever operates on the standard Secure Boot variables
(`db`/`dbx`/`KEK`/`PK`) and would never touch a vendor variable like
`SecureBootSetup`. Second, because the variable is boot-services-only (`BS`, no `RT`),
it isn't accessible at OS runtime at all — changing it requires an EFI shell before
the OS starts (or the unhidden BIOS menu). Note this is *not* the same as the standard
`SetupMode`/`SecureBoot`/`Boot####` variables, which are runtime-accessible and which
`scripts/Test-UefiVarAccess.ps1` does read via `GetFirmwareEnvironmentVariableExW`.

Field layout (offset → meaning), as decoded from the FB0A IFR:

| Offset | Field | Values |
|---|---|---|
| `0x0` | **Secure Boot** | `0x0` Disabled / `0x1` Enabled |
| `0x1` | Secure Boot Mode | `0x0` Standard / `0x1` Custom |
| `0x2` | Factory Key Provision | `0x0` / `0x1` — do **not** set to `1`: provisions factory (2011-only) keys |
| `0x3` | (reserved / unused in the visible form) | leave as read |
| `0x4` | Option ROM policy | `0x00`..`0x05` (see below) |
| `0x5` | Removable Media policy | `0x04` Deny / `0x05` Query User |
| `0x6` | Fixed Media policy | `0x04` Deny / `0x05` Query User |

Because offsets `0x2` and `0x3` carry state you don't want to disturb (setting
`Factory Key Provision` could re-provision the 2011-only factory keys — exactly what
this guide avoids), **never blind-write all 7 bytes.** Read the current value first
and change only the byte you mean to.

Image Execution Policy options as encoded in the firmware:

- **Option ROM** (offset `0x4`): `0x00` Always Execute, `0x01` Always Deny,
  `0x02` Allow Execute, `0x03` Defer Execute, `0x04` Deny Execute, `0x05` Query User.
- **Removable Media** (offset `0x5`) and **Fixed Media** (offset `0x6`): the menu only
  exposes `0x04` Deny Execute and `0x05` Query User. (`0x00` Always Execute exists in
  the underlying enum but AMI doesn't list it for media here.)

## Two ways to flip Secure Boot on

**Via the unhidden menu** (what the guide recommends): unhide the full Security page
with the SREP config, then use the toggle. Cleaner and reversible from the UI.

**Directly from an EFI shell** (no UI needed). **Read the variable first, then change
only offset `0x0`** — do not type a 7-byte literal from memory, since your `0x2`/`0x3`
bytes may differ and blind-writing them is risky:

```
# 1) read current 7 bytes
dmpstore -guid 7B59104A-C00D-4158-87FF-F04D6396A915

# 2) write back the SAME bytes but with offset 0x0 set to 01 (Enabled).
#    Example ONLY - substitute the actual bytes you just read for offsets 0x1..0x6:
#    if dmpstore showed  00 01 00 00 00 04 04  then set:
setvar SecureBootSetup -guid 7B59104A-C00D-4158-87FF-F04D6396A915 -bs -nv =01 01 00 00 00 04 04

# 3) verify
dmpstore -guid 7B59104A-C00D-4158-87FF-F04D6396A915
```

Revert by writing offset `0x0` back to `00` (again, preserving the other six bytes as
read). Exact `setvar` argument syntax varies between EFI shell builds — check the
`help setvar` output of the shell you're using.

> Do this **while Secure Boot is still off** — the EFI shell binary is itself
> unsigned and won't load once enforcement is on (not a dead end: erase keys →
> Setup Mode → shell works again).

## How the SREP config works

The AMITSE module holds a table that hides the full menu forms behind the stock ones.
Each 32-byte entry is `<Setup formset GUID> <FormId>`. The original Sweet_Kitten config
rewrites the Main/Advanced/Chipset entries (`0x2717`/`0x2718`/`0x2719`) to `0x2710`,
un-hiding those pages. It does **not** touch the Security entry (`0x271a`), which is
why the extended Advanced/Chipset tabs appeared but Security never did.

[`srep/SREP_Config.cfg`](../srep/SREP_Config.cfg) extends the search/replace pattern
by one more 32-byte entry so `0x271a` (Security-full) is also rewritten to `0x2710`,
un-hiding the full Security page and, with it, the link to the Secure Boot form.

The pattern is anchored on the unique start of that table (a short pattern matches the
`0x271a` entry in three different tables inside AMITSE, so the long anchored form is
required). This config is **specific to FB0A** and derived from Sweet_Kitten's config.

### The second FastPatch (inherited, unchanged)

The config has a second `Op FastPatch` block:

```
Pattern  4A10597B0DC0584187FFF04D6396A915 1727    (Setup formset GUID + FormId 0x2717 = Main)
Replace  4A10597B0DC0584187FFF04D6396A915 2828    (                        + FormId 0x2828 = OverClocking Performance Menu)
```

This one is **from Sweet_Kitten's original config — not added by this repo — and is
left unchanged.** Unlike the first block (which un-hides pages by pointing hidden
entries at `Setup`), this rewrites a menu reference from the Main form (`0x2717`) to
the **OverClocking Performance Menu** form (`0x2828`), which is how the extra
*OverClocking* tab appears in the tab bar. It's orthogonal to the Secure Boot fix; we
kept it so behaviour matches the original config people were already using. If you
don't want the OverClocking tab, you can delete that second `Op FastPatch` block.

## No BIOS update needed

None of this requires a Gigabyte BIOS update. A vendor update would only refresh the
*factory-default* key set that "Restore Factory Keys" loads; it wouldn't add a Secure
Boot toggle or change any of the above. Enrolling the keys from Windows and flipping
the variable achieves the same result on the shipping FB0A firmware.
