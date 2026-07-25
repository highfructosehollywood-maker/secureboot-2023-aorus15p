#!/usr/bin/env python3
"""Turn an SREP source checkout into a UEFI *driver* build with English messages.

Usage:  python3 patch-srep.py <path to SREP checkout>

Four edits, and why each is needed:

1. .inf  MODULE_TYPE  UEFI_APPLICATION -> UEFI_DRIVER, and the entry-point library
   class swapped to UefiDriverEntryPoint.
       The config in this repo uses `Op Loaded AMITSE`, i.e. it patches the AMITSE
       copy that is *already resident in RAM*. That patch only survives until the
       next reboot, so it has to be applied in the same boot in which you enter
       Setup. An application launched from the UEFI Shell cannot hand control to
       Setup without rebooting (which throws the patch away), while a UEFI driver
       registered in `DriverOrder` is loaded during BDS - before you press Del.
       Upstream ships both variants as a commented-out pair; this flips the comment.

2. .dsc  uncomment the UefiDriverEntryPoint library mapping (same reason).

3. .c    default UI language "ru-RU" -> "en-GB".
       Upstream stores the language in the `SREPLang` NV variable and only switches
       to English when launched as `SREP.efi ENG` from the Shell. A driver gets no
       command line, so without this edit every console message and SREP.log entry
       would be in Russian.

4. .dsc  GCC build flags in [BuildOptions].
       Upstream is developed with MSVC and its .dsc only carries MSFT flags. Under
       edk2's GCC5 toolchain:
         -Wno-unknown-pragmas, -Wno-missing-braces - MSVC-only `#pragma warning(...)`
             lines and GUID initialiser macros, which edk2's -Werror would reject;
         -fcommon, -Wl,--allow-multiple-definition - the code defines globals
             (`Log`, `LogFile`, `genericBufferSize`, several GUIDs) in headers that
             more than one .c file includes. MSVC's linker merges those; GNU ld with
             edk2's -fno-common reports "multiple definition".
       None of this changes what the code does.

The script asserts on exact upstream text: if an anchor is missing it fails loudly
rather than silently producing an unpatched binary. Re-running it is a no-op.
"""

import sys
from pathlib import Path

INF = "SmokelessRuntimeEFIPatcher/SmokelessRuntimeEFIPatcher.inf"
DSC = "SmokelessRuntimeEFIPatcher.dsc"
MAIN = "SmokelessRuntimeEFIPatcher/SmokelessRuntimeEFIPatcher.c"


def edit(path, rules):
    """Apply line rules to `path`. rules = [(old, new, required_once)] on rstripped lines."""
    raw = path.read_bytes().decode("utf-8", errors="surrogateescape")
    lines = raw.splitlines(keepends=True)
    done = {i: 0 for i, _ in enumerate(rules)}
    out = []
    for line in lines:
        body = line.rstrip("\r\n")
        eol = line[len(body):]
        for i, (old, new, _) in enumerate(rules):
            if body == old and done[i] == 0:
                body, eol = new, eol
                done[i] += 1
                break
        out.append(body + eol)
    changed = "".join(out)
    for i, (old, new, required) in enumerate(rules):
        if done[i] == 0:
            already = any(l.rstrip("\r\n") == new for l in lines)
            if already:
                print(f"  [skip] already patched: {old!r}")
                continue
            if required:
                raise SystemExit(
                    f"ERROR: {path}: neither the expected line\n"
                    f"         {old!r}\n"
                    f"       nor its patched form\n"
                    f"         {new!r}\n"
                    f"       was found. Upstream changed - review before building."
                )
        else:
            print(f"  [ok]   {old.strip()!r} -> {new.strip()!r}")
    if changed != raw:
        path.write_bytes(changed.encode("utf-8", errors="surrogateescape"))


MARKER = "# Added by patch-srep.py"
GCC_BLOCK = [
    f"  {MARKER}: upstream is MSVC-developed and needs three concessions under GCC.",
    "  # The two -Wno- flags silence warnings edk2 promotes to errors; -fcommon and",
    "  # --allow-multiple-definition cover the globals this code defines in headers",
    "  # that are included by several .c files (MSVC's linker merges them).",
    "  GCC:*_*_*_CC_FLAGS = -Wno-unknown-pragmas -Wno-missing-braces -fcommon",
    "  GCC:*_*_*_DLINK_FLAGS = -Wl,--allow-multiple-definition",
]


def append_build_options(path):
    """Put our GCC flags into the .dsc's [BuildOptions] section (upstream ships an
    MSFT-only one). Replaces the block if an older version of it is already there."""
    raw = path.read_bytes().decode("utf-8", errors="surrogateescape")
    eol = "\r\n" if "\r\n" in raw else "\n"
    lines = raw.splitlines()

    def write(new_lines):
        path.write_bytes((eol.join(new_lines) + eol).encode("utf-8", errors="surrogateescape"))

    # Drop a previously inserted block (marker line plus the comment/GCC lines after it).
    marker_at = next((i for i, l in enumerate(lines) if MARKER in l), None)
    if marker_at is not None:
        end = marker_at
        while end < len(lines) and (lines[end].startswith("  #") or lines[end].startswith("  GCC:")):
            end += 1
        if lines[marker_at:end] == GCC_BLOCK:
            print("  [skip] GCC build options already present")
            return
        del lines[marker_at:end]
        verb = "updated"
    else:
        verb = "added"

    for i, line in enumerate(lines):
        if line.strip() == "[BuildOptions]":
            lines[i + 1:i + 1] = GCC_BLOCK
            write(lines)
            print(f"  [ok]   GCC build options {verb} in the existing [BuildOptions] section")
            return

    write(lines + ["", "[BuildOptions]"] + GCC_BLOCK)
    print(f"  [ok]   [BuildOptions] section with GCC flags {verb}")


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    root = Path(sys.argv[1])
    for rel in (INF, DSC, MAIN):
        if not (root / rel).is_file():
            raise SystemExit(f"ERROR: {root / rel} not found - wrong checkout path?")

    print(f"Patching {root} for a UEFI_DRIVER build with English messages")

    print(f"{INF}:")
    edit(root / INF, [
        ("\tMODULE_TYPE                    = UEFI_APPLICATION",
         "\tMODULE_TYPE                    = UEFI_DRIVER", True),
        ("  UefiApplicationEntryPoint", "  # UefiApplicationEntryPoint", True),
        ("  # UefiDriverEntryPoint", "  UefiDriverEntryPoint", True),
    ])

    print(f"{DSC}:")
    edit(root / DSC, [
        ("  # UefiDriverEntryPoint|MdePkg/Library/UefiDriverEntryPoint/UefiDriverEntryPoint.inf",
         "  UefiDriverEntryPoint|MdePkg/Library/UefiDriverEntryPoint/UefiDriverEntryPoint.inf", True),
    ])
    append_build_options(root / DSC)

    print(f"{MAIN}:")
    edit(root / MAIN, [
        ("  if (GetLangVarStatus == EFI_NOT_FOUND || GetLangVarStatus == EFI_BUFFER_TOO_SMALL || AsciiStrCmp(SREPLangData, \"ru-RU\")) {",
         "  if (GetLangVarStatus == EFI_NOT_FOUND || GetLangVarStatus == EFI_BUFFER_TOO_SMALL || AsciiStrCmp(SREPLangData, \"en-GB\")) {", True),
        ("      \"ru-RU\"", "      \"en-GB\"", True),
    ])

    print("Done.")


if __name__ == "__main__":
    main()
