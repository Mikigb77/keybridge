# Contributing

Thanks for helping! KeyBridge talks to real hardware, so reports from machines other than the
author's are the most valuable contribution of all.

## Reports that help most

- **"It works on my X"**: open an issue with your Bluetooth adapter (`usbipd list`), Windows / WSL
  versions and the device you typed into. The compatibility table in the README is built from these.
- **Something broke**: use the bug report template; the log commands in it show what the kernel and
  BlueZ saw.

## Code

| Area | Files | Notes |
|---|---|---|
| Windows launcher | `windows/*.ps1` | Must run on **Windows PowerShell 5.1** (no `??`, ternaries, etc.). |
| Touchpad capture | `windows/MouseBridge.cs` | Compiled at runtime by `Add-Type` on PowerShell 5.1: **C# 5** syntax only. |
| Linux setup | `wsl/prepare.sh` | Idempotent, `set -e`, must pass `shellcheck --severity=warning`. |
| HID device | `wsl/keybridge.py` | Standard library + `python3-dbus` + `python3-gi` only. |
| Driver build | `wsl/build-drivers.sh`, `wsl/kcrc.py` | See `docs/building-drivers.md`. |

CI runs ShellCheck, pyflakes, a HID report descriptor check, a PowerShell 5.1 parse of every script
and a compile of `MouseBridge.cs`. Please keep it green.

### Adding a keyboard layout

Layouts live in `wsl/keybridge.py` (`layout_us`, `layout_es_mac`). A layout maps each character to the
HID key presses that produce it **on the host**, under the layout configured on the host. Add a
`layout_xx()` function, register it in `LAYOUTS`, and mention it in `settings.ini` and the README.

## Safety rules (learned the hard way)

- **Never remove a pairing** on the laptop side automatically. The host keeps its half and waits for
  the same key; if this laptop is its only keyboard, nobody can click "Forget" on the host.
- **Don't unplug the adapter from WSL while a host is connected**: it leaves a ghost adapter in the
  kernel. Stop BlueZ first (see `Stop-KeyBridge.ps1`).
- Avoid memory-hungry commands inside WSL: an out-of-memory kill makes systemd stop WSL's own
  processes 90 s after every boot (`prepare.sh` now prevents this, but don't rely on it).

More background in [docs/how-it-works.md](docs/how-it-works.md).
