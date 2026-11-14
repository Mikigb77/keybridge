# KeyBridge: helpers shared by Start-KeyBridge.ps1 and Stop-KeyBridge.ps1 (dot-sourced).
# Windows PowerShell 5.1 compatible.

$KB = @{
    Root    = Split-Path -Parent $PSScriptRoot             # repository root
    Windows = $PSScriptRoot                                 # ...\windows
    Usbipd  = Join-Path $(if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }) 'usbipd-win\usbipd.exe'
}

function Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Note([string]$Text) { Write-Host $Text -ForegroundColor Yellow }
function Fail([string]$Text) {
    Write-Host "!! $Text" -ForegroundColor Red
    Read-Host 'Press Enter to close' | Out-Null
    exit 1
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Re-open the calling script as administrator in a new window (one UAC prompt) and end this one.
function Restart-Elevated([string]$ScriptPath) {
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"")
    } catch { }   # "No" on the UAC prompt: just end quietly
    exit
}

# Settings from settings.ini in the main folder ("Key = value" lines; '#' starts a comment line).
function Read-Settings {
    $s = [ordered]@{ HostLayout = 'us'; DeviceName = 'KeyBridge'; MouseSpeed = '1.0'; MousePort = '47321'
                     Distro = ''; AdapterId = '' }
    $file = Join-Path $KB.Root 'settings.ini'
    if (Test-Path $file) {
        foreach ($line in Get-Content $file) {
            if ($line -match '^\s*([A-Za-z]+)\s*=\s*(.*?)\s*$' -and $s.Contains($Matches[1])) { $s[$Matches[1]] = $Matches[2] }
        }
    }
    $s
}

# The WSL distribution to use: the configured one, else the default one ('' if WSL isn't set up).
function Resolve-Distro([string]$Name) {
    if ($Name) { return $Name }
    $n = "$(wsl.exe -e sh -c 'printf %s "$WSL_DISTRO_NAME"' 2>$null)".Trim()
    if ($n -match '^[\w.\-]{1,64}$') { return $n }
    return ''
}

# The laptop's USB Bluetooth adapter as usbipd lists it: Id 'vvvv:pppp', Name, State, Vid, ProductId, Chip.
function Find-Adapter([string]$Id) {
    if (-not (Test-Path $KB.Usbipd)) { return $null }
    $rows = @(foreach ($l in (& $KB.Usbipd list 2>$null)) {
        if ($l -match '^\s*\S+\s+([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\s+(.+?)\s{2,}(Not shared|Shared|Attached)') {
            [pscustomobject]@{ Id = $Matches[1].ToLower(); Name = $Matches[2].Trim(); State = $Matches[3] }
        }
    })
    $pick = if ($Id) { @($rows | Where-Object { $_.Id -eq $Id.ToLower() }) } else { @($rows | Where-Object { $_.Name -match 'Bluetooth' }) }
    if ($pick.Count -eq 0) { return $null }
    if ($pick.Count -gt 1) {
        Note "Several Bluetooth adapters found; using $($pick[0].Id) ($($pick[0].Name)). Set AdapterId in settings.ini to pick another."
    }
    $a = $pick[0]
    $vid = $a.Id.Substring(0, 4)
    $chip = switch -Regex ("$($a.Name) vid:$vid") {
        'MediaTek|vid:0e8d'         { 'mediatek'; break }
        'Intel|vid:8087'            { 'intel'; break }
        'Realtek|vid:0bda'          { 'realtek'; break }
        'Broadcom|vid:0a5c'         { 'broadcom'; break }
        'Qualcomm|Atheros|vid:0cf3' { 'qualcomm'; break }
        default                     { 'unknown' }
    }
    $a | Add-Member -NotePropertyName Vid -NotePropertyValue $vid
    $a | Add-Member -NotePropertyName ProductId -NotePropertyValue $a.Id.Substring(5, 4)
    $a | Add-Member -NotePropertyName Chip -NotePropertyValue $chip
    $a
}

# usbipd's line for the adapter ('... Not shared' / '... Shared' / '... Attached'), as one string.
function Get-ChipState([string]$Id) {
    "$((& $KB.Usbipd list 2>$null) | Select-String -SimpleMatch $Id | Select-Object -First 1)"
}

# Windows' own Bluetooth interface of a composite adapter (USB interface 0). It keeps the adapter busy
# ("Device busy (exported)") unless it is disabled while WSL uses the adapter.
function Get-WindowsBtInterface($Adapter, [switch]$PresentOnly) {
    $prefix = "USB\VID_$($Adapter.Vid.ToUpper())&PID_$($Adapter.ProductId.ToUpper())&MI_00*"
    Get-PnpDevice -PresentOnly:$PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like $prefix }
}

# Console QuickEdit off: otherwise a click in the window starts a text selection and freezes the script.
function Disable-QuickEdit {
    try {
        Add-Type -Namespace KeyBridgeWin -Name Console -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int h);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
'@
        $h = [KeyBridgeWin.Console]::GetStdHandle(-10); $m = 0
        if ([KeyBridgeWin.Console]::GetConsoleMode($h, [ref]$m)) {
            [void][KeyBridgeWin.Console]::SetConsoleMode($h, ($m -band (-bnot 0x40)) -bor 0x80)
        }
    } catch { }
}
