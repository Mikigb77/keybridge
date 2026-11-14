#!/bin/bash
# KeyBridge: prepares the WSL2 distribution to drive the laptop's Bluetooth adapter as a keyboard + mouse.
# Idempotent. Run as root, BEFORE the adapter is attached with usbipd (Start-KeyBridge.ps1 does all of this).
#
#   prepare.sh [--chip mediatek|intel|realtek|broadcom|qualcomm|unknown] [--name "Bluetooth name"]
#
# Exit codes (understood by Start-KeyBridge.ps1):
#   0 ready
#   1 error (message printed)
#   2 this adapter needs a driver that WSL's kernel lacks -> run build-drivers.sh once
#   3 systemd is stopping WSL's own processes in this boot -> restart the distribution
#   4 systemd was just enabled for this distribution        -> restart the distribution
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
KV="$(uname -r)"
MOD="$HERE/modules/$KV"              # drivers built by build-drivers.sh for this kernel
CHIP=unknown
NAME=KeyBridge
while [ $# -gt 0 ]; do
  case "$1" in
    --chip) CHIP="${2:-unknown}"; shift 2 ;;
    --name) NAME="${2:-KeyBridge}"; shift 2 ;;
    *) shift ;;
  esac
done
NAME="$(printf '%s' "$NAME" | tr -cd 'A-Za-z0-9 ._-')"
[ -n "$NAME" ] || NAME=KeyBridge

# --- 0. Environment --------------------------------------------------------------------------
case "$KV" in
  *WSL2*|*microsoft-standard*) ;;
  *) echo "!! This must run in a WSL2 distribution (kernel: $KV). Convert it with: wsl --set-version <distro> 2"; exit 1 ;;
esac
command -v apt-get >/dev/null || { echo "!! KeyBridge needs a Debian/Ubuntu-based WSL distribution (no apt-get here)."; exit 1; }

# BlueZ runs as a systemd service, so systemd must be PID 1. Switch it on (takes effect after a restart).
if [ "$(cat /proc/1/comm)" != systemd ]; then
  echo ">> Enabling systemd for this WSL distribution (BlueZ needs it). If this repeats: wsl --update"
  touch /etc/wsl.conf
  if grep -qE '^[[:space:]]*systemd[[:space:]]*=' /etc/wsl.conf; then
    sed -i -E 's/^[[:space:]]*systemd[[:space:]]*=.*/systemd=true/' /etc/wsl.conf
  elif grep -qE '^[[:space:]]*\[boot\]' /etc/wsl.conf; then
    sed -i -E '/^[[:space:]]*\[boot\]/a systemd=true' /etc/wsl.conf
  else
    printf '\n[boot]\nsystemd=true\n' >> /etc/wsl.conf
  fi
  exit 4
fi

# After ANY out-of-memory kill in the WSL VM, systemd's default OOMPolicy=stop makes it stop init.scope,
# which holds WSL's own init and every wsl.exe session, and SIGKILL them all 90 s later: the keyboard
# would die ~90 s after every start. Keep going instead (applies from the next boot of the distribution).
mkdir -p /etc/systemd/system.conf.d
printf '[Manager]\n# KeyBridge: never stop WSL'"'"'s own processes because of an out-of-memory kill.\nDefaultOOMPolicy=continue\n' \
  > /etc/systemd/system.conf.d/90-keybridge-keep-wsl.conf
if [ "$(systemctl show init.scope -p ActiveState --value 2>/dev/null)" = "deactivating" ]; then
  echo "!! systemd is stopping WSL's own processes in this boot; the distribution needs one restart"
  exit 3
fi

# --- 1. Packages (only what is missing) ------------------------------------------------------
case "$CHIP" in
  mediatek) fwdir=mediatek; fwpkg=firmware-mediatek ;;
  intel)    fwdir=intel;    fwpkg=firmware-iwlwifi ;;
  realtek)  fwdir=rtl_bt;   fwpkg=firmware-realtek ;;
  broadcom) fwdir=brcm;     fwpkg=firmware-brcm80211 ;;
  qualcomm) fwdir=qca;      fwpkg=firmware-atheros ;;
  *)        fwdir="";       fwpkg="" ;;
esac
need=""
for p in bluez python3-dbus python3-gi kmod; do
  dpkg -s "$p" >/dev/null 2>&1 || need="$need $p"
done
updated=""
if [ -n "$fwpkg" ] && [ ! -d "/lib/firmware/$fwdir" ]; then
  apt-get update -qq; updated=1
  if apt-cache show "$fwpkg" >/dev/null 2>&1; then need="$need $fwpkg"     # Debian, Kali
  else need="$need linux-firmware"; fi                                     # Ubuntu
fi
if [ -n "$need" ]; then
  echo ">> Installing:$need"
  [ -n "$updated" ] || apt-get update -qq
  # shellcheck disable=SC2086  # word splitting of the package list is intended
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $need >/dev/null
fi

# --- 2. BlueZ: present as a keyboard + mouse, never time out, no built-in input plugin -----------
# (bluetoothd's input plugin would grab the HID channels 0x11/0x13 that keybridge.py listens on)
conf=/etc/bluetooth/main.conf
[ -f "$conf" ] || printf '[General]\n' > "$conf"
set_conf() {   # set_conf <key> <value>   (in [General])
  if grep -qE "^#?[[:space:]]*$1[[:space:]]*=" "$conf"; then
    sed -i -E "s|^#?[[:space:]]*$1[[:space:]]*=.*|$1 = $2|" "$conf"
  else
    sed -i -E "/^\[General\]/a $1 = $2" "$conf"
  fi
}
set_conf Class 0x0025C0
set_conf DiscoverableTimeout 0
set_conf PairableTimeout 0
set_conf Name "$NAME"
btd=""
for p in /usr/libexec/bluetooth/bluetoothd /usr/lib/bluetooth/bluetoothd "$(command -v bluetoothd || true)"; do
  if [ -n "$p" ] && [ -x "$p" ]; then btd="$p"; break; fi
done
[ -n "$btd" ] || { echo "!! bluetoothd not found (is the bluez package installed?)"; exit 1; }
mkdir -p /etc/systemd/system/bluetooth.service.d
printf '[Service]\nExecStart=\nExecStart=%s -P input\n' "$btd" > /etc/systemd/system/bluetooth.service.d/keybridge.conf

# --- 3. Drivers ---------------------------------------------------------------------------------
# WSL's kernel ships btusb without MediaTek support (CONFIG_BT_HCIBTUSB_MTK off), so MediaTek chips need
# btusb/btmtk built for the running kernel (build-drivers.sh). Other chips use the stock drivers.
mtk_in_kernel=no
if [ -r /proc/config.gz ] && zcat /proc/config.gz | grep -q '^CONFIG_BT_HCIBTUSB_MTK=y'; then mtk_in_kernel=yes; fi
OURS="btintel btrtl btbcm btmtk btusb"
if lsmod | grep -q '^btusb ' && { [ "$CHIP" != mediatek ] || [ "$mtk_in_kernel" = yes ] || lsmod | grep -q '^btmtk '; }; then
  echo ">> Bluetooth USB driver already loaded"
elif [ -d "$MOD" ]; then
  echo ">> Loading the Bluetooth drivers built for $KV"
  # shellcheck disable=SC2086
  rmmod $OURS 2>/dev/null || true
  # Load the stock modules ours depend on first (each .ko's "depends"). In WSL even USB support
  # (usbcore) is a module, and on a freshly started WSL nothing has loaded it yet.
  for m in $OURS; do
    deps="$(modinfo -F depends "$MOD/$m.ko")"
    for dep in ${deps//,/ }; do
      case " $OURS " in *" $dep "*) ;; *) modprobe "$dep" ;; esac
    done
  done
  for m in $OURS; do insmod "$MOD/$m.ko"; done
elif [ "$CHIP" = mediatek ] && [ "$mtk_in_kernel" = no ]; then
  echo "!! This is a MediaTek Bluetooth adapter, and WSL's kernel ($KV) ships its USB Bluetooth"
  echo "!! driver without MediaTek support. A matching driver has to be built once: wsl/build-drivers.sh"
  exit 2
else
  modprobe btusb
fi

# --- 4. Firmware the chip loads at power-up ---------------------------------------------------------
# The WSL kernel looks for firmware in the VM, not in this distribution; /mnt/wsl is shared with the VM
# (and wiped when WSL restarts, so stage it every time).
mkdir -p /mnt/wsl/fw
for d in ${fwdir:-mediatek intel rtl_bt brcm qca}; do
  if [ -d "/lib/firmware/$d" ] && [ ! -d "/mnt/wsl/fw/$d" ]; then cp -r "/lib/firmware/$d" /mnt/wsl/fw/; fi
done
printf '%s' /mnt/wsl/fw > /sys/module/firmware_class/parameters/path

# --- 5. Stop a KeyBridge left running from an earlier window, and wait until it is really gone -------
# (it holds the Bluetooth HID channels and the touchpad port)
if pgrep -f 'python3 .*keybridge\.py' >/dev/null; then
  echo ">> Stopping KeyBridge from an earlier session"
  pkill -f 'python3 .*keybridge\.py' || true
  for _ in $(seq 25); do pgrep -f 'python3 .*keybridge\.py' >/dev/null || break; sleep 0.2; done
  pkill -9 -f 'python3 .*keybridge\.py' 2>/dev/null || true
fi

# --- 6. Pairings (link keys) ------------------------------------------------------------------------
# A paired host only accepts this keyboard with the SAME key, and if this laptop is its only keyboard,
# nobody can re-pair on the host. So, while bluetoothd is stopped: put back any pairing file that went
# missing (cp -n never overwrites), then back everything up (cp never deletes).
systemctl stop bluetooth 2>/dev/null || true
mkdir -p /root/keybridge-backup
cp -an /root/keybridge-backup/. /var/lib/bluetooth/ 2>/dev/null || true
cp -a /var/lib/bluetooth/. /root/keybridge-backup/ 2>/dev/null || true

# --- 7. Bluetooth service ---------------------------------------------------------------------------
systemctl daemon-reload
systemctl start bluetooth
echo ">> WSL side ready"
