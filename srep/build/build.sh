#!/usr/bin/env bash
# Builds the three .efi files of the SREP stick from source, inside a container.
# Not meant to be run on your host directly - use Build-SrepUsb.ps1, which starts
# ubuntu:22.04 with the mounts this script expects:
#
#   /srep   (ro)  this repo's srep/ directory  - patch script, build/templates/, SREP_Config.cfg
#   /out    (rw)  output directory (build/work) - stage/, zip, *.diff, SHA256SUMS.txt
#   /build  (rw)  docker named volume          - edk2 + SREP checkouts, cached between runs
set -euo pipefail

EDK_TAG="${EDK_TAG:-edk2-stable202502}"
SREP_TAG="${SREP_TAG:-0.2.3}"
SREP_REPO="${SREP_REPO:-https://github.com/Maxinator500/SmokelessRuntimeEFIPatcher-RUS.git}"
JOBS="$(nproc)"

echo "=== SREP USB build ==="
echo "    edk2 tag : $EDK_TAG"
echo "    SREP tag : $SREP_TAG"
echo "    jobs     : $JOBS"

# --- 1. toolchain (skipped when the volume is already warm) ---------------------
if ! command -v nasm >/dev/null 2>&1; then
  echo "--- installing build dependencies"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    build-essential uuid-dev iasl git nasm python3 python3-setuptools ca-certificates
fi

mkdir -p /build /out
cd /build

# --- 2. edk2 -------------------------------------------------------------------
# Submodules are required: CryptoPkg/OpensslLib (SREP declares BaseCryptLib) and
# RegularExpressionDxe/oniguruma (the regex driver we ship as Oniguruma.efi).
if [ ! -d edk2/.git ]; then
  echo "--- cloning edk2 $EDK_TAG (with submodules, this is the slow part)"
  git clone --quiet --depth 1 -b "$EDK_TAG" --recurse-submodules --shallow-submodules \
    https://github.com/tianocore/edk2.git edk2
else
  echo "--- reusing cached edk2 checkout"
fi
cd edk2

# Source/C only: the top-level BaseTools target also runs unit tests that invoke
# `python`, which Ubuntu does not provide (only `python3`).
echo "--- building BaseTools"
make -C BaseTools/Source/C -j"$JOBS" >/tmp/basetools.log 2>&1 \
  || { tail -40 /tmp/basetools.log; exit 1; }

# --- 3. SREP source + our driver/English patch ---------------------------------
if [ ! -d SREPPkg/.git ]; then
  # The directory MUST be named SREPPkg: SREP's own .dsc/.inf reference SREPPkg/...
  echo "--- cloning SREP $SREP_TAG into SREPPkg"
  git clone --quiet --depth 1 -b "$SREP_TAG" "$SREP_REPO" SREPPkg
fi
python3 /srep/build/patch-srep.py SREPPkg
git -C SREPPkg diff > "/out/srep-${SREP_TAG}-driver.diff"

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

b srep  -p SREPPkg/SmokelessRuntimeEFIPatcher.dsc
b shell -p ShellPkg/ShellPkg.dsc
b regex -p MdeModulePkg/MdeModulePkg.dsc \
        -m MdeModulePkg/Universal/RegularExpressionDxe/RegularExpressionDxe.inf

# --- 5. stage the stick layout -------------------------------------------------
STAGE=/out/stage
rm -rf "$STAGE"
mkdir -p "$STAGE/EFI/BOOT"

# ShellPkg.dsc builds two shells; EA4BB293 is the "all commands integrated" one.
# Fall back to the largest Shell_*.efi if upstream ever renumbers the GUIDs.
SHELL_EFI="Build/Shell/RELEASE_GCC5/X64/Shell_EA4BB293-2D7F-4456-A681-1F22F42CD0BC.efi"
if [ ! -f "$SHELL_EFI" ]; then
  SHELL_EFI="$(ls -S Build/Shell/RELEASE_GCC5/X64/Shell_*.efi | head -1)"
  echo "    (falling back to $SHELL_EFI)"
fi
# startup.nsh needs bcfg; the command name is a UTF-16 string in the image.
grep -acoUP "b\x00c\x00f\x00g\x00" "$SHELL_EFI" >/dev/null \
  || { echo "!!! $SHELL_EFI has no bcfg command - startup.nsh would fail"; exit 1; }
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
  echo "  Built from SmokelessRuntimeEFIPatcher (SmokelessCPUv2, fork by Maxinator500),"
  echo "  tag $SREP_TAG, with local modifications. Upstream carries NO licence"
  echo "  statement - see srep/build/THIRD-PARTY.md in the repository before you"
  echo "  redistribute this file."
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
find . -type f | LC_ALL=C sort | sed 's|^\./||' | xargs sha256sum > /out/SHA256SUMS.txt
ZIP="/out/srep-usb-${SREP_TAG}.zip"
rm -f "$ZIP"
python3 - "$ZIP" <<'PY'
import os, sys, zipfile
zip_path = sys.argv[1]
files = sorted(
    os.path.relpath(os.path.join(dirpath, name), '.').replace(os.sep, '/')
    for dirpath, _, names in os.walk('.') for name in names
)
# Fixed timestamp so re-zipping identical content gives an identical archive.
with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as z:
    for f in files:
        info = zipfile.ZipInfo(f, date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        z.writestr(info, open(f, 'rb').read())
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
  echo "  local changes    : srep-${SREP_TAG}-driver.diff (see srep/build/patch-srep.py)"
  echo "  shell variant    : $(basename "$SHELL_EFI")"
  echo
  echo "Rebuild with: srep\\build\\Build-SrepUsb.ps1 -EdkTag $EDK_TAG -SrepTag $SREP_TAG"
  echo "Note: rebuilding with the same tags in this container reproduces these hashes"
  echo "(paths are fixed and edk2/GCC5 stamps a deterministic PE timestamp). A build"
  echo "with a different edk2 tag, compiler version or checkout path will behave the"
  echo "same but hash differently."
} > /out/BUILD-INFO.txt

echo
echo "=== result ==="
cat /out/BUILD-INFO.txt
ls -l "$STAGE" "$STAGE/EFI/BOOT"
cat /out/SHA256SUMS.txt
