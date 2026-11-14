---
name: Bug report
about: KeyBridge doesn't start, doesn't connect, or drops the connection
labels: bug
---

**What happened**
<!-- What you did, what you expected, what you saw. Paste the last lines of the KeyBridge window. -->

**Your setup**
- Windows version (`winver`):
- WSL version (`wsl --version`):
- Linux distribution (`wsl -l -v`):
- Bluetooth adapter (the line from `usbipd list`):
- Device you type into (e.g. Mac mini on its setup screen, iPad, Windows PC):

**Logs** (run in PowerShell; remove anything you consider private, such as Bluetooth addresses)
```
wsl -u root -e sh -c "dmesg | grep -iE 'bluetooth|hci|btusb|btmtk|vhci' | tail -n 40; journalctl -u bluetooth --no-pager -n 40"
```
