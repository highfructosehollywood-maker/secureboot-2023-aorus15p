SREP stick - AORUS 15P XD (AMI BIOS FB0A) only
==============================================

What is on this stick
  EFI/BOOT/BOOTX64.EFI    UEFI Shell (EDK2), boots first and runs startup.nsh
  startup.nsh             registers the SREP driver in DriverOrder (bcfg driver add)
  srep-*-driver.efi       SREP, built as a UEFI driver
  Oniguruma.efi           EDK2 regex driver, loaded by SREP at start
  SREP_Config.cfg         the patch itself - FB0A ONLY, do not use on other firmware

How to use it
  1. Boot the stick from the boot menu (F12). The Shell runs startup.nsh, which adds
     a Driver#### entry pointing at srep-*-driver.efi on this stick.
  2. Reboot with the stick still plugged in. The firmware loads SREP as a driver, it
     patches AMITSE in RAM and writes SREP.log to this stick's root.
  3. Enter BIOS setup (Del) and scroll the tab bar right: extra Advanced / Chipset
     and a second Security tab appear. Security -> Secure Boot.

Notes
  - The patch lives in RAM only. Nothing is written to the BIOS flash. Without the
    stick plugged in, the firmware is stock again.
  - Step 1 is a one-off; the Driver#### entry stays in NVRAM until you delete it with
    scripts/Manage-UefiDrivers.ps1 from Windows.
  - Once Secure Boot enforces, this unsigned driver only loads if you set
    Image Execution Policy -> Removable Media -> Query User (see docs/).

Licences of the files here: LICENSES.txt on this stick.
Full provenance: srep/build/THIRD-PARTY.md in the repository.
