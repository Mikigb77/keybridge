# KeyBridge: gives the Bluetooth adapter back to Windows.
# Start-KeyBridge offers this when you quit; run Stop-KeyBridge.cmd if you closed the window instead.
param([switch]$NoPause)
trap { Write-Host "!! Unexpected error: $_" -ForegroundColor Red; Read-Host 'Press Enter to close' | Out-Null; exit 1 }
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not (Test-Admin)) { Restart-Elevated $MyInvocation.MyCommand.Path }

$Settings = Read-Settings
$Adapter = Find-Adapter $Settings.AdapterId
if (-not $Adapter) { Fail 'No USB Bluetooth adapter found (see: usbipd list); nothing to give back.' }

if ((Get-ChipState $Adapter.Id) -match 'Attached') {
    # Shut Linux's side down first: unplugging the adapter while a host is still connected leaves a
    # "ghost" adapter in the Linux kernel that only a WSL restart clears.
    $Distro = Resolve-Distro $Settings.Distro
    if ($Distro) {
        Step 'Switching Bluetooth off in Linux'
        wsl.exe -d $Distro -u root -e sh -c 'pkill -f "python3 .*keybridge\.py"; for i in /sys/class/bluetooth/hci*; do [ -e "$i" ] || continue; n=${i##*/hci}; case $n in *:*) continue;; esac; timeout 5 btmgmt --index $n power off >/dev/null 2>&1; done; timeout 10 systemctl stop bluetooth; sleep 1' 2>$null
    }
    Step 'Detaching the adapter from WSL'
    & $KB.Usbipd detach --hardware-id $Adapter.Id 2>$null
}

Step 'Removing the WSL share'
& $KB.Usbipd unbind --hardware-id $Adapter.Id

Step "Re-enabling Windows' Bluetooth driver"
Get-WindowsBtInterface $Adapter | ForEach-Object {
    Enable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
}
pnputil /scan-devices | Out-Null

Note "`nDone. If Bluetooth doesn't show up in Windows within a minute, restart Windows once."
if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }
