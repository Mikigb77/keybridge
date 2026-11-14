#!/bin/bash
# KeyBridge: builds MediaTek-capable Bluetooth USB drivers (btusb + btmtk & co.) for the RUNNING WSL kernel.
# Needed once per WSL kernel version, and only for MediaTek adapters (Start-KeyBridge offers to run it).
# Takes ~20 min and ~15 GB in $B. Run as root inside the WSL distribution.
#
# Why it's done this way (details: docs/building-drivers.md):
#  - WSL's kernel has CONFIG_BT_HCIBTUSB_MTK off, so its btusb can't drive MediaTek chips.
#  - Modules must match the running kernel's struct layout -> build with its EXACT config (/proc/config.gz).
#  - CONFIG_MODVERSIONS=y -> symbol CRCs must match; they are taken from the stock WSL modules
#    (their export tables and import lists) instead of trusting our own build.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
KV="$(uname -r)"                       # e.g. 6.18.33.1-microsoft-standard-WSL2
TAG="linux-msft-wsl-${KV%%-*}"         # e.g. linux-msft-wsl-6.18.33.1
B="${KEYBRIDGE_BUILD_DIR:-/root/keybridge-kbuild}"
K="$B/WSL2-Linux-Kernel-$TAG"
J=$(nproc)

echo ">> Kernel $KV  (source tag $TAG), build directory $B"
avail_gb=$(( $(df --output=avail -k "$(dirname "$B")" | tail -1) / 1024 / 1024 ))
if [ "$avail_gb" -lt 16 ] && [ ! -d "$K" ]; then
  echo "!! Only ${avail_gb} GB free; the build needs about 15 GB."; exit 1
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential flex bison bc libelf-dev \
  libssl-dev dwarves cpio kmod curl python3 xz-utils zstd >/dev/null

mkdir -p "$B"; cd "$B"
if [ ! -d "$K" ]; then
  echo ">> Downloading kernel source (~250 MB)"
  curl -fsSL -o src.tar.gz "https://github.com/microsoft/WSL2-Linux-Kernel/archive/refs/tags/$TAG.tar.gz"
  tar xzf src.tar.gz && rm src.tar.gz
fi
cd "$K"

# --- Pass 1: full build (debug info off for speed), only to learn every symbol's owner -> Module.symvers
if [ ! -f "$B/Module.symvers.full.$KV" ]; then
  echo ">> Pass 1: full kernel build (~15 min). Log: $B/build.log"
  zcat /proc/config.gz > .config
  scripts/config --enable BT_HCIBTUSB_MTK --disable DEBUG_INFO --enable DEBUG_INFO_NONE \
    --disable DEBUG_INFO_BTF --disable DEBUG_INFO_BTF_MODULES --disable WERROR
  make olddefconfig >/dev/null
  make -j"$J" KCFLAGS="-Wno-error" > "$B/build.log" 2>&1 || { tail -30 "$B/build.log"; exit 1; }
  cp Module.symvers "$B/Module.symvers.full.$KV"
fi

# --- Pass 2: exact running config (+ MediaTek) so struct layouts match
echo ">> Pass 2: driver build with the exact running config"
zcat /proc/config.gz > .config
scripts/config --enable BT_HCIBTUSB_MTK
make olddefconfig >/dev/null
make -j"$J" modules_prepare >/dev/null 2>&1

# Symbol CRCs: stock module exports (__kcrctab) > stock module imports > our pass-1 build
KCRC="$HERE/kcrc.py" FULL="$B/Module.symvers.full.$KV" python3 - <<'PY'
import glob, os, subprocess, tempfile
kv = os.uname().release
crc = {}

def raw(ko):
    if ko.endswith(".xz"):
        return subprocess.run(["xz", "-dc", ko], capture_output=True).stdout
    if ko.endswith(".zst"):
        return subprocess.run(["zstd", "-dcq", ko], capture_output=True).stdout
    return None

mods = glob.glob(f"/lib/modules/{kv}/**/*.ko*", recursive=True)
for ko in mods:                       # exports, with their real CRCs
    data, path = raw(ko), ko
    if data is not None:
        t = tempfile.NamedTemporaryFile(suffix=".ko", delete=False)
        t.write(data)
        t.close()
        path = t.name
    out = subprocess.run(["python3", os.environ["KCRC"], path], capture_output=True, text=True).stdout
    for line in out.splitlines():
        c, s = line.split()
        crc[s] = c
    if path != ko:
        os.unlink(path)
for ko in mods:                       # what stock modules expect from vmlinux
    out = subprocess.run(["modprobe", "--dump-modversions", ko], capture_output=True, text=True).stdout
    for line in out.splitlines():
        p = line.split()
        if len(p) == 2:
            crc.setdefault(p[1], p[0])
stock = fill = 0
with open("Module.symvers", "w") as f:
    for line in open(os.environ["FULL"]):
        p = line.rstrip("\n").split("\t")
        if len(p) < 4 or p[2].startswith("drivers/bluetooth/"):
            continue
        c = crc.get(p[1])
        if c:
            stock += 1
        else:
            c, fill = p[0], fill + 1
        f.write("\t".join([c] + p[1:]) + "\n")
print(f">> Module.symvers: {stock} CRCs from stock modules, {fill} from our build")
PY

# Skip module BTF generation (WSL kernels have MODULE_ALLOW_BTF_MISMATCH=y)
if [ -f vmlinux ]; then mv vmlinux "$B/vmlinux.nobtf"; fi
make -j"$J" M=drivers/bluetooth modules > "$B/bt.log" 2>&1 || { tail -30 "$B/bt.log"; exit 1; }

OUT="$HERE/modules/$KV"; mkdir -p "$OUT"
for m in btintel btrtl btbcm btmtk btusb; do strip --strip-debug -o "$OUT/$m.ko" "drivers/bluetooth/$m.ko"; done
echo ">> Done. Drivers saved to $OUT"
echo ">> You can delete $B (~15 GB) to get the space back; it is only needed to rebuild."
