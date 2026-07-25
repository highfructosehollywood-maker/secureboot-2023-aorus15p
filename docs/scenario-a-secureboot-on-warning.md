# Scenario A — Secure Boot is ON, and Windows warns the certificates are outdated

**Symptoms:** the machine boots normally, Secure Boot is enabled, but Windows
Security shows a notice that **Secure Boot certificates need updating / are expiring**,
often linking to Microsoft's page
[Windows Secure Boot certificate expiration and CA updates](https://support.microsoft.com/en-us/servicing/os/secure-boot/2025/06/windows-secure-boot-certificate-expiration-and-ca-updates)
(KB5062710). `Confirm-SecureBootUEFI` returns `True`.

**Goal:** get the **Windows UEFI CA 2023** certificate into your firmware `db` so the
warning clears and the machine keeps booting after the 2011 certificate expires.

This is the **easy** case. You do **not** touch the BIOS, do **not** erase keys, and
do **not** need anything from `keys/`. Windows can write the update itself — you're
only nudging a rollout that hasn't reached your device yet.

## Or just dismiss it

The notice in Windows Security has a **Dismiss** button, and clicking it is a valid
choice: nothing breaks immediately. Per Microsoft, devices that don't receive the 2023
certificates **keep starting and installing normal Windows updates** — they simply
stop receiving *early-boot* security updates (boot manager, Secure Boot db/dbx,
revocations) once the 2011 certificates begin expiring in **June 2026**. So dismissing
hides the reminder without fixing the underlying expiry. If you're fine with that
trade-off, dismiss and move on. If you'd rather actually apply the update, continue
below.

> **BitLocker:** enabling later firmware changes can alter PCR 7. This scenario only
> adds a db certificate and normally does not trip BitLocker, but make sure you know
> where your recovery key is before proceeding.

---

## Step 1 — Prerequisites

- Secure Boot **enabled** (`Confirm-SecureBootUEFI` → `True`).
- Windows fully updated. The servicing logic needs a recent cumulative update
  (KB5036210 or later). If `\Microsoft\Windows\PI\Secure-Boot-Update` doesn't exist
  as a scheduled task, you're missing updates — install them first.

Check whether 2023 is already present (if `True`, you're basically done — just
reboot twice and the warning clears):

```powershell
[System.Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI db).bytes) -match 'Windows UEFI CA 2023'
```

## Step 2 — Trigger the DB update (adds Windows UEFI CA 2023)

Elevated PowerShell:

```powershell
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Secureboot' `
    -Name 'AvailableUpdates' -Value 0x40 -Type DWord
Start-ScheduledTask -TaskName '\Microsoft\Windows\PI\Secure-Boot-Update'
```

`0x40` tells Windows to write the **Windows UEFI CA 2023** certificate into `db`.
**Reboot twice** (some firmware needs two boots to commit the db write), then verify:

```powershell
[System.Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI db).bytes) -match 'Windows UEFI CA 2023'
# expect: True
```

For most people, **db now trusting 2023 is enough** to clear the expiry warning and
keep the machine booting. You can stop here.

## Step 3 (optional) — Boot manager + KEK, the full transition

If you want the complete transition (boot manager re-signed under 2023, plus the 2023
KEK), continue. `AvailableUpdates` is a **bitmask that both triggers and reports
progress**; each bit clears as it's processed, so it reads back `0x0` when done — that
is normal, not a failure.

```powershell
# update the boot manager to the 2023-signed version
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Secureboot' `
    -Name 'AvailableUpdates' -Value 0x100 -Type DWord
Start-ScheduledTask -TaskName '\Microsoft\Windows\PI\Secure-Boot-Update'
# reboot twice
```

> ⚠️ **The "do everything at once" value writes the dbx revocation list too.**
> Applying `0x5944` runs *all* steps, including adding forbidden signatures to `dbx`.
> **dbx additions are effectively irreversible** without erasing keys, and they can
> break old USB recovery media / WinRE that still carry a revoked (2011-signed) boot
> chain. Prefer the targeted values (`0x40`, then `0x100`) unless you specifically
> want the revocations. **This block was not tested on the AORUS 15P XD** — it is a
> summary of Microsoft's KB guidance.
>
> If you *do* apply revocations and an old USB installer / recovery stick then fails
> to boot, it can be re-issued: Microsoft's **Make2023BootableMedia.ps1** rebuilds
> Windows media (ISO / USB / local / network) with the 2023-signed boot manager so it
> boots on machines that trust *Windows UEFI CA 2023*. See
> [Updating Windows bootable media to use the PCA2023 signed boot manager](https://support.microsoft.com/en-us/servicing/os/windows/2025/02/updating-windows-bootable-media-to-use-the-pca2023-signed-boot-manager)
> (KB5053484). It needs the Windows ADK and a media source with current updates.

If you understand the trade-off above and still want the one-shot full transition,
set the composite value and let Windows work through it across several reboots:

```powershell
# FULL transition incl. revocations - see warning above
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Secureboot' `
    -Name 'AvailableUpdates' -Value 0x5944 -Type DWord
Start-ScheduledTask -TaskName '\Microsoft\Windows\PI\Secure-Boot-Update'
# reboot several times; Windows works through the bitmask across reboots
```

Track progress:

```powershell
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Secureboot' |
    Select-Object UEFICA2023Status, UEFICA2023Error, AvailableUpdates
```

- `UEFICA2023Status`: `NotStarted → InProgress → Updated`.
- `AvailableUpdates`: transient; intermediate values like `0x4100` (staged, pending
  reboot) → `0x4000`/`0x0` (done) are expected.
- `UEFICA2023Error` non-zero → a firmware conflict; see notes below.

## Bitmask values

Individual actions (per Microsoft KB5025885 — the exact bit assignments have been
revised by Microsoft over time, so treat this as a guide and check the current
[KB5025885](https://support.microsoft.com/en-us/topic/how-to-manage-the-windows-boot-manager-revocations-for-secure-boot-changes-associated-with-cve-2023-24932-41a975df-beb2-40c1-99a3-b3ff139f832d)
before relying on a
specific bit):

| Value | Action |
|---|---|
| `0x40`   | Add **Windows UEFI CA 2023** to `db` |
| `0x100`  | Update the **boot manager** to the 2023-signed version |
| `0x80`   | Add **KEK 2K CA 2023** to `KEK` |
| `0x5944` | IT-managed "do all steps" — db + KEK + boot manager **+ dbx revocations** |

Note `0x5944` is a composite of several action bits (not simply `0x40+0x80+0x100`);
its exact composition is Microsoft's and includes staging/revocation bits. Don't
try to derive it by hand — use it only as the whole "do everything" trigger, with
the caveat above.

## Troubleshooting

- **`db` update stays `False` after two reboots.** Usually missing OS updates (no
  `Secure-Boot-Update` task) or the firmware isn't accepting the db write yet. Fully
  update Windows and retry. On the AORUS 15P XD specifically, the automatic rollout
  has been unreliable — the registry trigger above is the manual push.
- **Status stalls at `InProgress` / KEK won't update.** The 2023 KEK must be signed
  such that your current `PK` trusts it. On OEM machines that's fine; on unusual key
  setups it can stall — the db (Step 2) is the part that actually matters for booting.
- **You'd rather enroll from the BIOS.** The `keys/` set here works there too: BIOS
  → Secure Boot → Key Management → import `db`/`KEK`. But for Scenario A the Windows
  method above is simpler and Microsoft-supported.

---

**If Secure Boot is OFF and you can't turn it back on**, you're in the wrong doc —
see **[Scenario B](scenario-b-stuck-setup-mode.md)**.
