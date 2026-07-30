#!/usr/bin/env bash
# Builds the three .efi files of the SREP stick from source, inside a container.
# Not meant to be run on your host directly - use Build-SrepUsb.ps1, which builds the
# image from the Dockerfile beside this file and starts it with the mounts and the
# version pins this script expects:
#
#   /srep   (ro)  this repo's srep/ directory  - build/templates/, SREP_Config.cfg
#   /out    (rw)  output directory (build/work) - stage/, zip, SHA256SUMS.txt, BUILD-INFO.txt
#   /build  (rw)  docker named volume          - edk2 + SREP checkouts, cached between runs
set -euo pipefail

# No defaults on purpose: Build-SrepUsb.ps1's param() block is the single place the
# pinned versions live, and it always passes all three. Defaults here could only ever
# be redundant or - after a bump applied in one file - silently wrong.
EDK_TAG="${EDK_TAG:?must be set by the caller (see Build-SrepUsb.ps1)}"
SREP_TAG="${SREP_TAG:?must be set by the caller (see Build-SrepUsb.ps1)}"
SREP_REPO="${SREP_REPO:?must be set by the caller (see Build-SrepUsb.ps1)}"
JOBS="$(nproc)"

echo "=== SREP USB build ==="
echo "    edk2 tag : $EDK_TAG"
echo "    SREP tag : $SREP_TAG"
echo "    jobs     : $JOBS"

# --- 1. toolchain -------------------------------------------------------------
# The Dockerfile beside this script is the single declaration of the toolchain; this
# only catches "started the script in the wrong container".
for tool in gcc make nasm iasl git python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "!!! $tool is missing - run via Build-SrepUsb.ps1 so the build image is used"
    exit 1
  }
done

mkdir -p /build /out
cd /build

# --- 2. edk2 -------------------------------------------------------------------
if [ ! -d edk2/.git ]; then
  echo "--- cloning edk2 $EDK_TAG (with submodules, this is the slow part)"
  # -c advice.detachedHead=false: cloning a tag is exactly the point here, and git's 15-line
  # lecture about it goes to stderr - which a PowerShell caller renders as an error.
  git -c advice.detachedHead=false clone --quiet --depth 1 -b "$EDK_TAG" \
    --recurse-submodules --shallow-submodules \
    https://github.com/tianocore/edk2.git edk2
else
  echo "--- reusing cached edk2 checkout"
fi

# ALL submodules, on purpose. Cherry-picking the ones "this build needs" looks tempting -
# it is the step that dominates the wall clock - but edk2 does not work that way, and two
# concrete failures prove it:
#   * BaseTools' own make builds BrotliCompress, so a missing
#     BaseTools/Source/C/BrotliCompress/brotli ends the script with
#     "[footer.makefile] BrotliCompress.o Error 1" before SREP is even cloned;
#   * MdePkg.dec declares an include path inside MdePkg/Library/MipiSysTLib/mipisyst, and
#     build.py validates it while parsing the .dec - "MdePkg.dec(33): error 000E:
#     File/directory not found in workspace" - so a module that never links mipi-sys-t
#     still fails. Other .dec files in the tree do the same thing.
# Re-run on every build, not only after a fresh clone: `update --init` is a no-op when the
# trees are already there, and it repairs a volume cached by an earlier version of this
# script instead of failing the same way twice.
echo "--- checking out submodules"
git -C edk2 submodule update --init --depth 1 --recursive --quiet
cd edk2

# Source/C only: the top-level BaseTools target also runs unit tests that invoke
# `python`, which Ubuntu does not provide (only `python3`).
echo "--- building BaseTools"
make -C BaseTools/Source/C -j"$JOBS" >/tmp/basetools.log 2>&1 \
  || { tail -40 /tmp/basetools.log; exit 1; }

# --- 3. SREP source ------------------------------------------------------------
# Built unmodified from the tag: the driver module type, the English-only output and
# the GCC flags are commits in the fork, not edits made here. See srep/build/THIRD-PARTY.md.
#
# The checkout is cached in the docker volume, so it has to be checked against the
# requested repo+tag - otherwise a -SrepTag (or a fork change) would silently build
# whatever the volume happens to hold. The pin file lives outside SREPPkg to keep the
# checkout pristine.
PIN="$SREP_REPO@$SREP_TAG"
if [ -d SREPPkg ] && [ "$(cat /build/.srep-pin 2>/dev/null)" != "$PIN" ]; then
  echo "--- cached SREP checkout is not $PIN - dropping it"
  rm -rf SREPPkg
fi
if [ ! -d SREPPkg/.git ]; then
  # The directory MUST be named SREPPkg: SREP's own .dsc/.inf reference SREPPkg/...
  echo "--- cloning SREP $SREP_TAG into SREPPkg"
  git -c advice.detachedHead=false clone --quiet --depth 1 -b "$SREP_TAG" "$SREP_REPO" SREPPkg
  echo "$PIN" > /build/.srep-pin
else
  echo "--- reusing cached SREP checkout ($PIN)"
fi

# A tag can be moved; the build should say which commit it actually compiled, and a dirty
# checkout would break the published hashes without any sign of it.
git -C SREPPkg diff --quiet || {
  echo "!!! the SREP checkout has local modifications - the reference hashes will not match"
  git -C SREPPkg status --short
  exit 1
}

# --- 4. build ------------------------------------------------------------------
set +u
source ./edksetup.sh >/dev/null
set -u

b() {  # b <log name> <build args...>
  local name="$1"; shift
  echo "--- building $name"
  build -b RELEASE -t GCC5 -a X64 -n "$JOBS" "$@" >"/tmp/$name.log" 2>&1 \
    || { echo "!!! $name build failed, tail of log:"; tail -60 "/tmp/$name.log"; exit 1; }
}

# --- 4a. pin the stack cookie so the SREP image is reproducible ------------------
# edk2 >= stable202411 gives modules a stack cookie, and build.py seeds it randomly: on the
# first build of a platform it writes 100 random values into
# Build/<platform>/<target>_<tool>/StackCookieValues64.json, and AutoGen picks
# values[hash(module GUID) % 100] - a Python string hash, i.e. randomised per process too.
# The value lands in .data, so the image hash changes on every recompile. SREP's own .dsc
# maps the real StackCheckLib; ShellPkg and MdeModulePkg do not, which is exactly why only
# the SREP image drifted while the other two stayed byte-identical.
#
# A one-element list makes the modulo index constant, so neither the seed nor Python's hash
# randomisation matters any more. The value is fixed and public on purpose: a canary that a
# local, unsigned pre-boot driver keeps in its own stack frame protects nothing that an
# attacker already on this path could not do anyway, while byte-for-byte reproducibility is
# what makes REFERENCE-BUILD.txt - and therefore "build it yourself" - worth anything.
COOKIE_HEX=5352455053544B43                      # "SREPSTKC", recognisable in a hex dump
COOKIE_DIR=Build/SmokelessRuntimeEFIPatcher/RELEASE_GCC5
# Drop just this platform's tree: a tree compiled with a different cookie is "up to date",
# so the pin would silently not take effect. It rebuilds in seconds - unlike Shell and
# MdeModulePkg, whose caches are the slow ones and carry no cookie.
rm -rf Build/SmokelessRuntimeEFIPatcher
mkdir -p "$COOKIE_DIR"
python3 -c "import json,sys; json.dump([0x$COOKIE_HEX], open(sys.argv[1],'w'))" \
        "$COOKIE_DIR/StackCookieValues64.json"
python3 -c "import json,sys; json.dump([0x53544B43],  open(sys.argv[1],'w'))" \
        "$COOKIE_DIR/StackCookieValues32.json"

b srep  -p SREPPkg/SmokelessRuntimeEFIPatcher.dsc

# The pin is path-dependent (PLATFORM_NAME comes from SREP's .dsc), so prove it took rather
# than quietly shipping a one-off binary.
COOKIE_H="$(find Build/SmokelessRuntimeEFIPatcher -path '*/SmokelessRuntimeEFIPatcher/DEBUG/AutoGen.h' | head -1)"
grep -q "define STACK_COOKIE_VALUE 0x${COOKIE_HEX}ULL" "$COOKIE_H" 2>/dev/null || {
  echo "!!! the stack cookie was not pinned - this build is not reproducible."
  echo "    expected 0x${COOKIE_HEX} in ${COOKIE_H:-<no AutoGen.h found>}"
  grep -h "STACK_COOKIE_VALUE" "$COOKIE_H" 2>/dev/null
  echo "    check that $COOKIE_DIR still matches the platform name in SREP's .dsc"
  exit 1
}
echo "    stack cookie pinned to 0x$COOKIE_HEX"
b shell -p ShellPkg/ShellPkg.dsc
b regex -p MdeModulePkg/MdeModulePkg.dsc \
        -m MdeModulePkg/Universal/RegularExpressionDxe/RegularExpressionDxe.inf

# --- 5. stage the stick layout -------------------------------------------------
STAGE=/out/stage
rm -rf "$STAGE"
mkdir -p "$STAGE/EFI/BOOT"

# ShellPkg.dsc builds two shells and only the "all commands integrated" one has the bcfg
# command that startup.nsh needs. Pick it by its FILE_GUID, which is what REFERENCE-BUILD.txt
# pins; fall back to the largest image if a -EdkTag bump ever renumbers that .dsc override.
# Both images contain the string "bcfg" (the command tables are shared even where the
# implementation is not), so the check below can only catch a wholly wrong file - it cannot
# tell the two variants apart, which is why the GUID stays the primary selector.
SHELL_DIR=Build/Shell/RELEASE_GCC5/X64
SHELL_EFI="$SHELL_DIR/Shell_EA4BB293-2D7F-4456-A681-1F22F42CD0BC.efi"
if [ ! -f "$SHELL_EFI" ]; then
  SHELL_EFI="$(ls -S "$SHELL_DIR"/Shell_*.efi | head -1)"
  echo "    (the pinned shell GUID is gone in $EDK_TAG; falling back to the largest image)"
fi
# The command name appears as a UTF-16 string in the image.
grep -qaUP "b\x00c\x00f\x00g\x00" "$SHELL_EFI" \
  || { echo "!!! $SHELL_EFI has no bcfg command - startup.nsh would fail"; exit 1; }
echo "    shell variant: $(basename "$SHELL_EFI")"
cp "$SHELL_EFI"                                                            "$STAGE/EFI/BOOT/BOOTX64.EFI"
cp Build/SmokelessRuntimeEFIPatcher/RELEASE_GCC5/X64/SmokelessRuntimeEFIPatcher.efi \
                                                                           "$STAGE/srep-${SREP_TAG}-driver.efi"
cp Build/MdeModule/RELEASE_GCC5/X64/RegularExpressionDxe.efi               "$STAGE/Oniguruma.efi"
cp /srep/SREP_Config.cfg                                                   "$STAGE/SREP_Config.cfg"
cp /srep/build/templates/README.txt                                        "$STAGE/README.txt"

# BSD-2-Clause-Patent wants the notice and conditions to travel with the binaries, so
# EDK2's own licence text goes on the stick rather than staying behind in the repo.
{
  echo "Licences for the files on this stick"
  echo "===================================="
  echo
  echo "EFI/BOOT/BOOTX64.EFI, Oniguruma.efi"
  echo "  Built from TianoCore EDK2 ($EDK_TAG). Full licence text below."
  echo
  echo "srep-${SREP_TAG}-driver.efi"
  echo "  Built from $SREP_REPO, tag $SREP_TAG:"
  echo "  SmokelessRuntimeEFIPatcher by SmokelessCPUv2, forked by Maxinator500,"
  echo "  forked again for an English-only driver build. NONE of these carries a"
  echo "  licence statement - see srep/build/THIRD-PARTY.md in the repository"
  echo "  before you redistribute this file."
  echo
  echo "SREP_Config.cfg, startup.nsh, README.txt"
  echo "  MIT, from the secureboot-2023-aorus15p repository."
  echo
  echo "-------------------------------------------------------------------------------"
  echo "TianoCore EDK2 - $EDK_TAG"
  echo "-------------------------------------------------------------------------------"
  cat License.txt
} > "$STAGE/LICENSES.txt"
# CRLF, like the shell script on the known-working stick. Strip first, so this stays
# correct even if the template arrives with CRLF from a Windows checkout.
sed "s/@SREP_EFI@/srep-${SREP_TAG}-driver.efi/g; s/\r\$//; s/\$/\r/" \
    /srep/build/templates/startup.nsh                                    > "$STAGE/startup.nsh"

# --- 6. verify the SREP image really is a driver, not an application -----------
python3 - "$STAGE/srep-${SREP_TAG}-driver.efi" <<'PY'
import struct, sys
p = sys.argv[1]
d = open(p, 'rb').read()
pe = struct.unpack_from('<I', d, 0x3c)[0]
assert d[pe:pe+4] == b'PE\0\0', 'not a PE image'
machine, = struct.unpack_from('<H', d, pe + 4)
subsystem, = struct.unpack_from('<H', d, pe + 24 + 68)
names = {10: 'EFI_APPLICATION', 11: 'EFI_BOOT_SERVICE_DRIVER', 12: 'EFI_RUNTIME_DRIVER'}
print(f"    machine   : 0x{machine:04x} (0x8664 = x64)")
print(f"    subsystem : {subsystem} ({names.get(subsystem, '?')})")
assert machine == 0x8664, 'not x86-64'
assert subsystem == 11, f'expected EFI_BOOT_SERVICE_DRIVER (11), got {subsystem}'
print("    -> driver image confirmed")
PY

# --- 7. hashes + zip ----------------------------------------------------------
cd "$STAGE"
ZIP="/out/srep-usb-${SREP_TAG}.zip"
rm -f "$ZIP"
# One walk of the stage tree, one read per file: hash and zip in the same pass.
python3 - "$ZIP" /out/SHA256SUMS.txt <<'PY'
import hashlib, os, sys, zipfile
zip_path, sums_path = sys.argv[1], sys.argv[2]
files = sorted(
    os.path.relpath(os.path.join(dirpath, name), '.').replace(os.sep, '/')
    for dirpath, _, names in os.walk('.') for name in names
)
sums = []
# Fixed timestamp so re-zipping identical content gives an identical archive.
with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as z:
    for f in files:
        info = zipfile.ZipInfo(f, date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        with open(f, 'rb') as fh:
            data = fh.read()
        z.writestr(info, data)
        sums.append(f"{hashlib.sha256(data).hexdigest()}  {f}\n")   # sha256sum's own format
with open(sums_path, 'w') as fh:
    fh.writelines(sums)
print('wrote', zip_path)
PY
( cd /out && sha256sum "$(basename "$ZIP")" >> SHA256SUMS.txt )

# --- 8. provenance ------------------------------------------------------------
{
  echo "SREP USB build"
  echo "  built            : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "  toolchain        : GCC5 / RELEASE / X64 ($(gcc --version | head -1))"
  echo "  edk2             : $EDK_TAG @ $(git -C /build/edk2 rev-parse HEAD)"
  echo "  SREP             : $SREP_TAG @ $(git -C /build/edk2/SREPPkg rev-parse HEAD)"
  echo "  SREP repo        : $SREP_REPO"
  echo "  local changes    : none - built unmodified from the tag above"
  echo "  shell variant    : $(basename "$SHELL_EFI")"
  echo "  stack cookie     : pinned to 0x$COOKIE_HEX (see build.sh - required for the hashes)"
  echo
  echo "Rebuild with: srep\\build\\Build-SrepUsb.ps1 -EdkTag $EDK_TAG -SrepTag $SREP_TAG"
  echo "Note: rebuilding with the same tags in this container is designed to reproduce these"
  echo "hashes byte for byte. Three things make that possible: fixed checkout paths, edk2/GCC5's"
  echo "zeroed PE timestamp, and the pinned stack cookie above (without the pin edk2 seeds it"
  echo "randomly and the SREP image differs by 8 bytes on every recompile). A build with a"
  echo "different edk2 tag, compiler version or checkout path behaves the same way but hashes"
  echo "differently. Whether a given release was actually rebuilt twice to confirm it is"
  echo "recorded in srep/build/REFERENCE-BUILD.txt, not here - this file cannot know."
} > /out/BUILD-INFO.txt

echo
echo "=== result ==="
cat /out/BUILD-INFO.txt
ls -l "$STAGE" "$STAGE/EFI/BOOT"
cat /out/SHA256SUMS.txt
