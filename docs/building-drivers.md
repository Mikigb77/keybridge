# Building the MediaTek Bluetooth driver for WSL

Only needed for **MediaTek** adapters (e.g. MT7921 / MT7922 Wi-Fi + Bluetooth combo cards). KeyBridge
detects this and offers to run `wsl/build-drivers.sh`; you can also run it yourself:

```powershell
wsl -u root -e bash wsl/build-drivers.sh        # from the KeyBridge folder; ~20 min, ~15 GB
```

The result goes to `wsl/modules/<kernel version>/` and is loaded by `prepare.sh` on every start.
When WSL updates its kernel, KeyBridge notices that no drivers exist for the new version and offers to
build them again. The build directory (`/root/keybridge-kbuild`) can be deleted afterwards.

## Why it's needed

WSL's kernel is built with `CONFIG_BT_HCIBTUSB_MTK` disabled. Its `btusb` module therefore has no
MediaTek support and no `btmtk` helper module exists, so the adapter never comes up in Linux.

## Why it isn't a plain module build

A module only loads into a kernel if it agrees with it on three things:

1. **Struct layouts.** A module built with a slightly different configuration has a different
   `struct module` size and is rejected (`.gnu.linkonce.this_module section size must match`).
   The build therefore uses the **exact** running configuration from `/proc/config.gz`, plus only
   `CONFIG_BT_HCIBTUSB_MTK=y`.
2. **Symbol versions** (`CONFIG_MODVERSIONS`). Every imported symbol carries a CRC that must match
   the running kernel's (`disagrees about version of symbol ...`). A local build can produce
   different CRCs than Microsoft's, so `build-drivers.sh` rewrites `Module.symvers` with the CRCs
   found in the **stock** WSL modules:
   - exported symbols: read from each stock module's `__kcrctab` section, matched to names through the
     relocations of its `__ksymtab` section ([`kcrc.py`](../wsl/kcrc.py));
   - kernel (vmlinux) symbols: from the import lists of the stock modules
     (`modprobe --dump-modversions`);
   - anything else: from a full local build (pass 1).
3. **BTF.** Module BTF generation needs a `vmlinux` with matching BTF; WSL kernels set
   `MODULE_ALLOW_BTF_MISMATCH=y`, so the build simply skips module BTF.

All five Bluetooth modules (`btintel`, `btrtl`, `btbcm`, `btmtk`, `btusb`) are built and loaded
together, because `btusb` references the helpers by symbol version too.

## The two passes

| Pass | Config | Purpose | Time |
|---|---|---|---|
| 1 | running config, debug info off | full kernel build, only to get a complete `Module.symvers` | ~15 min |
| 2 | **exact** running config + MTK | `modules_prepare`, CRC fix-up, `make M=drivers/bluetooth` | ~2 min |

Source: `github.com/microsoft/WSL2-Linux-Kernel`, tag `linux-msft-wsl-<kernel version>`.

## Licensing

The kernel modules are built **on your machine** from Microsoft's GPL-2.0 kernel source. KeyBridge
does not distribute any kernel binaries; its own code is MIT-licensed.
