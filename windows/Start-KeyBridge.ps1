# KeyBridge - use this Windows laptop as a Bluetooth keyboard + mouse for another device.
#
# Hands the laptop's USB Bluetooth adapter to WSL2 (usbipd-win), where BlueZ presents it as a Bluetooth
# HID keyboard + mouse (wsl/keybridge.py). The touchpad is captured here on Windows (MouseBridge.cs) and
# passed over localhost. Windows can't use its own Bluetooth meanwhile; Stop-KeyBridge gives it back.
#
# Settings: ..\settings.ini      How it works: ..\docs\how-it-works.md
trap { Write-Host "!! Unexpected error: $_" -ForegroundColor Red; Read-Host 'Press Enter to close' | Out-Null; exit 1 }
. (Join-Path $PSScriptRoot 'Common.ps1')
$Self = $MyInvocation.MyCommand.Path
$Settings = Read-Settings

# --- Keep a "KeyBridge" shortcut in the main folder. Shortcuts need full paths, so this repairs it when
#     the folder was moved. It points at Windows' own PowerShell rather than a custom .exe on purpose:
#     antivirus software tends to block unknown unsigned executables that start PowerShell.
try {
    $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $want = "-NoProfile -ExecutionPolicy Bypass -File `"$Self`""
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $KB.Root 'KeyBridge.lnk'))
    if ($lnk.Arguments -ne $want -or $lnk.TargetPath -ne $psExe) {
        $lnk.TargetPath = $psExe; $lnk.Arguments = $want; $lnk.WorkingDirectory = $KB.Windows
        $lnk.WindowStyle = 7       # minimized: this first PowerShell only re-opens itself as admin
        $lnk.IconLocation = (Join-Path $KB.Windows 'assets\keybridge.ico') + ',0'
        $lnk.Description = 'Use this laptop as a Bluetooth keyboard + mouse'
        $lnk.Save()
    }
} catch { }

if (-not (Test-Admin)) { Restart-Elevated $Self }     # binding USB devices needs admin
$Host.UI.RawUI.WindowTitle = 'KeyBridge'
Disable-QuickEdit

# --- 0. Close any earlier KeyBridge session, so every start begins from the same clean state.
#        An old window would fight this one over the touchpad link, and its "Give Bluetooth back?"
#        question would pull Bluetooth away from this session. Never touches this window or whatever
#        opened it. Closing a session never unpairs anything (pairings live in WSL).
Step 'Closing any earlier KeyBridge session'
$procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
$byId = @{}; foreach ($p in $procs) { $byId[[int]$p.ProcessId] = $p }
$keep = @{}; $id = [int]$PID                                 # this process and its parents
for ($i = 0; $i -lt 32 -and $id -and -not $keep.ContainsKey($id); $i++) {
    $keep[$id] = $true
    $id = if ($byId.ContainsKey($id)) { [int]$byId[$id].ParentProcessId } else { 0 }
}
$old = @($procs | Where-Object {
    -not $keep.ContainsKey([int]$_.ProcessId) -and $_.Name -match '^(powershell|pwsh|wsl|cmd)\.exe$' -and
    "$($_.CommandLine)" -match 'Start-KeyBridge\.(ps1|cmd)|Stop-KeyBridge\.(ps1|cmd)|keybridge\.py' })
foreach ($p in $old) {
    Write-Host "Closing $($p.Name) (pid $($p.ProcessId)) from an earlier session"
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
}
if ($old.Count) { Start-Sleep -Milliseconds 800 } else { Write-Host 'None was running.' }

# --- 1. Prerequisites: usbipd-win, WSL, a USB Bluetooth adapter
Step 'Checking usbipd-win'
if (-not (Test-Path $KB.Usbipd)) {
    Write-Host 'Installing usbipd-win (shares USB devices with WSL)...'
    winget install --id dorssel.usbipd-win -e --accept-source-agreements --accept-package-agreements --disable-interactivity
    if (-not (Test-Path $KB.Usbipd)) { Fail 'usbipd-win did not install. Install it from https://github.com/dorssel/usbipd-win/releases and run KeyBridge again.' }
}

Step 'Checking WSL'
$Distro = Resolve-Distro $Settings.Distro
if (-not $Distro) {
    Fail 'WSL has no Linux distribution yet. Install one with:  wsl --install -d Ubuntu  then restart Windows and run KeyBridge again.'
}
Write-Host "Linux distribution: $Distro"
$wslDir = "$(wsl.exe -d $Distro -u root -e wslpath -a ($KB.Root.Replace([char]92, [char]47)))".Trim() + '/wsl'

Step 'Finding the Bluetooth adapter'
$Adapter = Find-Adapter $Settings.AdapterId
if (-not $Adapter) {
    Fail ('No USB Bluetooth adapter found (see: usbipd list). KeyBridge needs a Bluetooth adapter connected ' +
          'over USB: most laptop adapters are, and a USB Bluetooth dongle works too.')
}
Write-Host "$($Adapter.Name)  [$($Adapter.Id), $($Adapter.Chip)]"

# Number of Bluetooth adapters the Linux kernel holds (hci0, hci1, ...)
function Get-LinuxAdapterCount {
    [int]("$(wsl.exe -d $Distro -u root -e sh -c 'ls /sys/class/bluetooth 2>/dev/null | grep -c "^hci[0-9][0-9]*$"')".Trim())
}

# An adapter unplugged while still connected leaves a "ghost" in the Linux kernel that never goes away
# and keeps its hciN name. Only restarting WSL's VM clears it; ask first (it also stops Docker etc.).
function Repair-StuckBluetooth {
    Step 'Repairing Linux Bluetooth'
    Note 'Linux still holds a broken Bluetooth adapter from an earlier session.'
    Note 'The fix is restarting WSL. That also stops Docker and any other Linux programs for a moment.'
    if ((Read-Host 'Restart WSL now? [Y/n]') -match '^(n|no)$') {
        Fail 'Not restarted. KeyBridge cannot start until WSL is restarted (run: wsl --shutdown).'
    }
    wsl.exe --shutdown
    Start-Sleep -Seconds 3
}

# Runs wsl/prepare.sh and handles what it asks for (see the exit codes at the top of prepare.sh).
function Invoke-Prepare {
    for ($try = 1; $try -le 4; $try++) {
        wsl.exe -d $Distro -u root -e bash "$wslDir/prepare.sh" --chip $Adapter.Chip --name $Settings.DeviceName
        switch ($LASTEXITCODE) {
            0 { return }
            2 {
                Note 'This adapter needs a one-time build of its driver for WSL (about 20 minutes and 15 GB of disk).'
                if ((Read-Host 'Build it now? [Y/n]') -match '^(n|no)$') { Fail 'Not built. Run KeyBridge again when you want to build it.' }
                wsl.exe -d $Distro -u root -e bash "$wslDir/build-drivers.sh"
                if ($LASTEXITCODE -ne 0) { Fail 'Building the driver failed (see above). docs/building-drivers.md has details.' }
            }
            { $_ -eq 3 -or $_ -eq 4 } {
                Note 'Restarting the Linux distribution once...'
                wsl.exe --terminate $Distro | Out-Null
                Start-Sleep -Seconds 2
            }
            default { Fail 'Preparing Linux failed (see the message above).' }
        }
    }
    Fail 'Preparing Linux did not settle (see the messages above).'
}

# Steps 2-5 run at most twice: if Linux Bluetooth turns out to be stuck, WSL is restarted (with your OK)
# and they run again. The adapter is NOT reset between sessions: unplugging it while a host is connected
# is exactly what leaves a stuck "ghost" adapter. One still attached from an earlier session is reused.
for ($attempt = 1; ; $attempt++) {

    # --- 2. Linux must not hold more Bluetooth adapters than ours accounts for
    $expected = if ((Get-ChipState $Adapter.Id) -match 'Attached') { 1 } else { 0 }
    if ((Get-LinuxAdapterCount) -gt $expected) { Repair-StuckBluetooth }

    # --- 3. Linux side: packages, BlueZ config, drivers, firmware, pairing backup, bluetoothd
    Step "Preparing Linux ($Distro)"
    Invoke-Prepare

    # --- 4. Hand the adapter from Windows to WSL
    Step 'Handing the Bluetooth adapter to WSL'
    if ((Get-ChipState $Adapter.Id) -match 'Not shared') {
        & $KB.Usbipd bind --hardware-id $Adapter.Id --force
    }
    Get-WindowsBtInterface $Adapter -PresentOnly | Where-Object { $_.Status -eq 'OK' } | ForEach-Object {
        Write-Host "Disabling Windows Bluetooth: $($_.FriendlyName)"
        Disable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false
    }
    if ((Get-ChipState $Adapter.Id) -notmatch 'Attached') {
        & $KB.Usbipd attach --wsl --hardware-id $Adapter.Id
        if ($LASTEXITCODE -ne 0) {
            Fail 'Could not attach the adapter to WSL. Restart Windows once (a pending driver change needs it), then run KeyBridge again.'
        }
    }

    # --- 5. Wait for Linux to bring the adapter up: exactly one adapter must exist
    Step 'Waiting for the adapter in Linux'
    wsl.exe -d $Distro -u root -e sh -c 'for i in $(seq 30); do ls /sys/class/bluetooth 2>/dev/null | grep -q "^hci[0-9][0-9]*$" && exit 0; sleep 1; done; exit 1'
    if ($LASTEXITCODE -ne 0) { Fail "The adapter did not appear in Linux (check: wsl -d $Distro -u root dmesg | tail)." }
    Start-Sleep -Seconds 2
    if ((Get-LinuxAdapterCount) -eq 1) { break }
    if ($attempt -ge 2) { Fail 'Linux Bluetooth is still not right after restarting WSL. Restart Windows, then try again.' }
    Repair-StuckBluetooth
}

# --- 6. Touchpad helper (sends the laptop's pointer to the other device while Ctrl+G is on)
Step 'Starting the touchpad helper'
try {
    Add-Type -Path (Join-Path $KB.Windows 'MouseBridge.cs')
    [KeyBridge.MouseBridge]::Start([int]$Settings.MousePort)
    if (-not [KeyBridge.MouseBridge]::HookInstalled) { Note 'Could not capture the touchpad; the keyboard still works.' }
} catch {
    Note "Touchpad helper failed ($($_.Exception.Message)); the keyboard still works."
}

# --- 7. Keyboard (runs in this window until Ctrl+Q)
Step 'Starting KeyBridge (Ctrl+Q to quit)'
wsl.exe -d $Distro -u root -e python3 "$wslDir/keybridge.py" "--layout=$($Settings.HostLayout)" `
    "--name=$($Settings.DeviceName)" "--mouse-port=$($Settings.MousePort)" "--mouse-speed=$($Settings.MouseSpeed)"
try { [KeyBridge.MouseBridge]::Stop() } catch { }

Write-Host "`nKeyBridge stopped." -ForegroundColor Yellow
if ((Read-Host 'Give Bluetooth back to Windows now? [Y/n]') -notmatch '^(n|no)$') {
    & (Join-Path $KB.Windows 'Stop-KeyBridge.ps1') -NoPause
} else {
    Note 'Bluetooth stays with WSL. To give it back later, run Stop-KeyBridge.cmd (or start KeyBridge and quit with Ctrl+Q).'
}
Read-Host 'Press Enter to close' | Out-Null
