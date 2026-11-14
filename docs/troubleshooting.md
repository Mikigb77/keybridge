# Troubleshooting

Start with the last lines of the KeyBridge window: most problems print a `!!` line that says what to do.
Useful commands (PowerShell):

```powershell
usbipd list                                            # adapter state: Not shared / Shared / Attached
wsl -u root -e sh -c "ls /sys/class/bluetooth"          # adapters Linux sees (expect exactly: hci0)
wsl -u root -e sh -c "dmesg | grep -iE 'bluetooth|btusb|btmtk|vhci' | tail -n 30"
wsl -u root -e sh -c "journalctl -u bluetooth --no-pager -n 30"
```

## Starting

| Symptom | Cause and fix |
|---|---|
| "No USB Bluetooth adapter found" | `usbipd list` shows no device with "Bluetooth" in its name. Some laptops connect Bluetooth over UART/SDIO, which can't be passed to WSL; a USB Bluetooth dongle works. If the name just lacks the word, set `AdapterId` in `settings.ini`. |
| "WSL has no Linux distribution yet" | `wsl --install -d Ubuntu`, restart Windows, run KeyBridge again. |
| "needs a Debian/Ubuntu-based WSL distribution" | Your default distribution isn't Debian-based. Install Ubuntu and set `Distro = Ubuntu` in `settings.ini`. |
| "This adapter needs a one-time build of its driver" | MediaTek adapter: answer **Y** (about 20 minutes, 15 GB). Needed again after WSL updates its kernel. See [building-drivers.md](building-drivers.md). |
| `usbipd attach` fails / "Device busy" | Windows' Bluetooth driver still holds the adapter, or a driver change is pending. Restart Windows once, then run KeyBridge again. |
| "Linux still holds a broken Bluetooth adapter" | A ghost adapter from an earlier session (the adapter was unplugged while connected). Answer **Y**: WSL restarts (this also stops Docker and other Linux programs for a moment). |
| `insmod ... Unknown symbol in module` | Drivers built for a different kernel, or an old copy of KeyBridge. Update KeyBridge; if WSL updated its kernel, delete `wsl/modules/` and let KeyBridge rebuild. |
| "The Bluetooth adapter never became ready" | The adapter didn't come up in time. Close the window and start KeyBridge again; if it repeats, restart WSL (`wsl --shutdown`). |
| Double-clicking does nothing / a security warning appears | Files downloaded as ZIP are marked as coming from the internet. Right-click the ZIP → Properties → **Unblock** before extracting, or run `Get-ChildItem -Recurse \| Unblock-File` in the folder. |

## Connecting

| Symptom | Cause and fix |
|---|---|
| The other device never sees "KeyBridge" | Open its Bluetooth settings or keyboard setup assistant *while* KeyBridge runs. KeyBridge uses limited discoverable mode, like a keyboard in pairing mode. |
| It paired before, but doesn't reconnect | KeyBridge calls paired hosts every few seconds; wait ~10 s and look for "Reconnected to ...". The host's Bluetooth must be on. |
| The other device shows a code | Type it in the KeyBridge window and press Enter. |
| Connection drops ~90 s after every start | An old out-of-memory event in WSL makes systemd stop WSL's processes. `prepare.sh` fixes the setting; if it persists, run `wsl --shutdown` once. |
| Connection drops when you start KeyBridge a second time | Expected: a new start closes the old session first; the host reconnects within seconds. |

## Typing and the mouse

| Symptom | Cause and fix |
|---|---|
| Wrong symbols (e.g. `@` comes out as `"`) | The host's keyboard layout differs from `HostLayout`. Press Ctrl+L, or set it in `settings.ini`. |
| `[x?]` appears for a character | No key produces that character in the current layout. |
| Shortcuts (Cmd/Ctrl/Option + key) or F-keys don't work | Not supported yet (typing goes through the terminal). |
| Ctrl+G says the touchpad helper isn't connected | The helper failed to start (message printed before "Starting KeyBridge"), or WSL's localhost forwarding is off (`localhostForwarding=false` in `%USERPROFILE%\.wslconfig`). The keyboard still works. |
| Pointer too fast / slow on the other device | `MouseSpeed` in `settings.ini`. |
| The pointer races off uncontrollably | DPI mismatch in the hook; please open an issue with your display scaling. |
| A USB mouse works but a Bluetooth mouse doesn't | While KeyBridge runs, Windows has no Bluetooth: a Bluetooth mouse can't connect to the laptop. Pair it directly with the other device. |

## Recovering a lost pairing

If the host no longer accepts KeyBridge and you can't remove the pairing on the host (because KeyBridge
*is* its keyboard), restore the backup that every start makes:

```powershell
wsl -u root -e sh -c "systemctl stop bluetooth; cp -an /root/keybridge-backup/. /var/lib/bluetooth/; systemctl start bluetooth"
```

KeyBridge does this automatically for missing files on every start.
