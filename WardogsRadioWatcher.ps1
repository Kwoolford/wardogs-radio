# Background watcher: opens WARDOGS Radio when the game starts. The GUI closes itself when the game exits (-FollowGame).
# Started at logon by the "WardogsRadio Watcher" shortcut in the Startup folder. Checks every 5 s; negligible CPU.
# Opens the GUI once per game session - if you close it while playing, it stays closed until the next launch.

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Gui  = Join-Path $Root 'WardogsRadio.ps1'

$mutex = New-Object Threading.Mutex($false, 'Local\WardogsRadioWatcher')
if (-not $mutex.WaitOne(0)) { exit }   # already watching

$handledPid = 0
while ($true) {
    $game = Get-Process -Name 'WardogsClient*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($game -and $game.Id -ne $handledPid) {
        $handledPid = $game.Id
        $guiOpen = $false
        try { $m = [Threading.Mutex]::OpenExisting('Local\WardogsRadioGui'); $m.Dispose(); $guiOpen = $true } catch {}
        if (-not $guiOpen) {
            # hide only the console via powershell's own -WindowStyle; Start-Process -WindowStyle Hidden
            # would also hide the GUI's first window (Windows applies it to the first ShowWindow call)
            Start-Process powershell.exe -ArgumentList @(
                '-NoProfile', '-WindowStyle', 'Hidden', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$Gui`"", '-FollowGame')
        }
    }
    Start-Sleep -Seconds 5
}
