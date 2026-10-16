# WARDOGS Radio - plays "radio stations" (or Spotify) into your mic via SteelSeries Sonar Streamer mode.
#
# How it works:
#   Sonar Streamer mode has a "stream mix" that shows up as a recording device ("SteelSeries Sonar - Stream").
#   We put ONLY Mic + Media into that mix, point WARDOGS' mic at it, and play music on the Media channel.
#   Spotify can be flipped between Media (on air) and its normal channel (private).
#
# Run with: Launch WardogsRadio.cmd   (or: powershell -STA -ExecutionPolicy Bypass -File WardogsRadio.ps1)
# Test mode: . .\WardogsRadio.ps1 -NoGui   (loads functions only)
# -FollowGame: close automatically once WARDOGS has exited (used by WardogsRadioWatcher.ps1)

param([switch]$NoGui, [switch]$FollowGame)

$ErrorActionPreference = 'Stop'
$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Stations  = Join-Path $Root 'stations.json'
$StateFile = Join-Path $Root 'state.json'
$LogFile   = Join-Path $Root 'WardogsRadio.log'
$WardogsIni = Join-Path $env:LOCALAPPDATA 'Wardogs\Saved\Config\WindowsClient\GameUserSettings.ini'


$RadioFilter = 'highpass=f=220,lowpass=f=4800,acompressor=threshold=0.125:ratio=4:attack=5:release=120,volume=1.5'

function Write-Log($msg) {
    $line = '{0:HH:mm:ss} {1}' -f (Get-Date), $msg
    try { Add-Content -Path $LogFile -Value $line } catch {}
    if ($script:StatusLabel) { $script:StatusLabel.Text = $msg }
}

function Find-Exe($name) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $hit = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet" -Recurse -Filter "$name.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}
$FfplayExe = Find-Exe 'ffplay'
$YtdlpExe  = Find-Exe 'yt-dlp'

# ---------------- state ----------------
function Get-State {
    if (Test-Path $StateFile) { try { return Get-Content $StateFile -Raw | ConvertFrom-Json } catch {} }
    return [pscustomobject]@{}
}
function Save-State($st) { $st | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8 }
function Set-StateValue($name, $value) {
    $st = Get-State
    $st | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
    Save-State $st
}

# ---------------- Sonar API ----------------
if (-not ('WardogsRadioTrustAll' -as [type])) {
    Add-Type @'
using System.Net; using System.Security.Cryptography.X509Certificates;
public class WardogsRadioTrustAll : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint a, X509Certificate b, WebRequest c, int d) { return true; }
}
'@
}
[Net.ServicePointManager]::CertificatePolicy = New-Object WardogsRadioTrustAll
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'

$script:SonarBase = $null
function Get-SonarBase([switch]$Refresh) {
    if ($script:SonarBase -and -not $Refresh) { return $script:SonarBase }
    $props = Get-Content 'C:\ProgramData\SteelSeries\GG\coreProps.json' -Raw | ConvertFrom-Json
    $sub = Invoke-RestMethod "https://$($props.ggEncryptedAddress)/subApps" -TimeoutSec 5
    $addr = $sub.subApps.sonar.metadata.webServerAddress
    if (-not $addr) { throw 'Sonar is not running (open SteelSeries GG and enable Sonar).' }
    $script:SonarBase = $addr
    return $addr
}
function Invoke-Sonar([string]$Route, [string]$Method = 'Get') {
    try {
        $r = Invoke-RestMethod -Method $Method -Uri "$(Get-SonarBase)/$Route" -TimeoutSec 5
    } catch {
        # Sonar's port changes when it restarts - rediscover once
        $r = Invoke-RestMethod -Method $Method -Uri "$(Get-SonarBase -Refresh)/$Route" -TimeoutSec 5
    }
    $r  # emitting the variable unrolls JSON arrays (PS 5.1 returns them as one object)
}
function Esc([string]$s) { [Uri]::EscapeDataString($s) }
function B([bool]$v) { if ($v) { 'true' } else { 'false' } }

function Get-SonarMode { [string](Invoke-Sonar 'mode') }

function Get-RoleDeviceId([string]$role) {
    $r = Invoke-Sonar 'AudioDeviceRouting'
    ($r | Where-Object { $_.role -eq $role -and $_.dataFlow -eq 'render' } | Select-Object -First 1).deviceId
}

function Get-StreamCaptureDevice {
    Invoke-Sonar 'audioDevices' | Where-Object { $_.dataFlow -eq 'capture' -and $_.friendlyName -match 'Sonar - Stream' } | Select-Object -First 1
}

function Set-AppRole([int]$processId, [string]$role) {
    $dev = Get-RoleDeviceId $role
    if (-not $dev) { throw "No Sonar device for role '$role'" }
    Invoke-Sonar "AudioDeviceRouting/render/$(Esc $dev)/$processId" 'Put' | Out-Null
}

function Get-AppSessions([string]$processName) {
    # returns objects: pid, role of the Sonar channel the session is on
    $out = @()
    foreach ($d in (Invoke-Sonar 'AudioDeviceRouting')) {
        foreach ($s in $d.audioSessions) {
            if ($s.processName -eq $processName -and $s.processId -ne 0) {
                $out += [pscustomobject]@{ pid = [int]$s.processId; role = $d.role; state = $s.state; deviceId = $d.deviceId }
            }
        }
    }
    $out
}

function Initialize-Broadcast {
    $mode = Get-SonarMode
    if ($mode -eq 'classic') {
        # remember the classic outputs so the stream setup uses the same headphones / mic
        $cr = @(Invoke-Sonar 'classicRedirections')
        $hp  = ($cr | Where-Object id -eq 'game').deviceId
        $mic = ($cr | Where-Object id -eq 'mic').deviceId
        if ($hp)  { Set-StateValue 'headphones' $hp }
        if ($mic) { Set-StateValue 'mic' $mic }
        Write-Log 'Switching Sonar to Streamer mode...'
        Invoke-Sonar 'mode/stream' 'Put' | Out-Null
        Start-Sleep -Milliseconds 1500
    }
    $st = Get-State
    $hp = $st.headphones; $mic = $st.mic
    if (-not $hp -or -not $mic) {
        # already in Streamer mode on first run: reuse whatever Sonar is currently using
        $sr = @(Invoke-Sonar 'streamRedirections')
        if (-not $hp)  { $hp  = ($sr | Where-Object streamRedirectionId -eq 'monitoring').deviceId }
        if (-not $mic) { $mic = ($sr | Where-Object streamRedirectionId -eq 'mic').deviceId }
        if (-not $hp -or -not $mic) { throw 'Could not detect your headset/mic. Switch Sonar to Classic mode, then click Set up Sonar.' }
        Set-StateValue 'headphones' $hp; Set-StateValue 'mic' $mic
    }

    Invoke-Sonar "streamRedirections/monitoring/deviceId/$(Esc $hp)" 'Put' | Out-Null
    Invoke-Sonar "streamRedirections/mic/deviceId/$(Esc $mic)" 'Put' | Out-Null
    # The stream mix only runs once it has an output: Sonar's "Stream" render device, which loops back to the Stream mic.
    $streamOut = (@(Invoke-Sonar 'audioDevices') | Where-Object { $_.role -eq 'stream' -and $_.dataFlow -eq 'render' } | Select-Object -First 1).id
    if (-not $streamOut) { throw 'Sonar Stream device not found.' }
    Invoke-Sonar "streamRedirections/streaming/deviceId/$(Esc $streamOut)" 'Put' | Out-Null

    # Stream mix (what goes into the game mic): your voice + Media only.
    $streamMix = @{ chatCapture = $true; media = $true; game = $false; chatRender = $false; aux = [bool](Get-State).spotifyOnAir }
    foreach ($k in $streamMix.Keys) { Invoke-Sonar "streamRedirections/streaming/redirections/$k/isEnabled/$(B $streamMix[$k])" 'Put' | Out-Null }
    # Personal mix (your headphones): everything except your own mic.
    $personal = @{ chatCapture = $false; media = $true; game = $true; chatRender = $true; aux = $true }
    foreach ($k in $personal.Keys) { Invoke-Sonar "streamRedirections/monitoring/redirections/$k/isEnabled/$(B $personal[$k])" 'Put' | Out-Null }

    Write-Log 'Sonar ready: stream mix = mic + media.'
}

function Get-StreamerMediaVolumes {
    $v = Invoke-Sonar 'volumeSettings/streamer'
    [pscustomobject]@{
        OnAir      = [double]$v.devices.media.stream.streaming.volume
        OnAirMuted = [bool]$v.devices.media.stream.streaming.muted
        Mine       = [double]$v.devices.media.stream.monitoring.volume
        MineMuted  = [bool]$v.devices.media.stream.monitoring.muted
    }
}
function Set-StreamerVolume([string]$mix, [string]$channel, [double]$vol) {
    $s = $vol.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
    Invoke-Sonar "volumeSettings/streamer/$mix/$channel/volume/$s" 'Put' | Out-Null
}
function Set-StreamerMute([string]$mix, [string]$channel, [bool]$muted) {
    Invoke-Sonar "volumeSettings/streamer/$mix/$channel/isMuted/$(B $muted)" 'Put' | Out-Null
}

# ---------------- Spotify ----------------
# Spotify gets its own lane: the Aux channel. Aux is always in your headset (personal mix) and is added to
# the stream mix only while Spotify is ON AIR - independent of the radio's Media on-air / headset toggles.
function Set-SpotifyOnAir([bool]$onAir) {
    $sessions = @(Get-AppSessions 'Spotify')
    if (-not $sessions) { throw 'No Spotify audio session yet - press play in Spotify first.' }
    # Sonar keeps old sessions around; only these are sensible "home" channels for Spotify
    # ('stream' would feed the mic directly, 'none' is a raw device, 'media'/'aux' are on-air lanes)
    $homeRoles = @('game', 'chatRender')
    $st = Get-State
    $pids = @($sessions | Select-Object -ExpandProperty pid -Unique)
    if ($onAir) {
        $orig = ($sessions | Where-Object { $_.role -in $homeRoles } | Sort-Object { $_.state -ne 'active' } | Select-Object -First 1).role
        if ($orig) { Set-StateValue 'spotifyRole' $orig }
        foreach ($p in $pids) { Set-AppRole $p 'aux' }
        Invoke-Sonar 'streamRedirections/monitoring/redirections/aux/isEnabled/true' 'Put' | Out-Null
        Invoke-Sonar 'streamRedirections/streaming/redirections/aux/isEnabled/true' 'Put' | Out-Null
        Set-StreamerMute 'streaming' 'aux' $false
        Set-StreamerMute 'monitoring' 'aux' $false
        Set-StateValue 'spotifyOnAir' $true
        Write-Log 'Spotify is ON AIR (your headset + mic).'
    } else {
        Invoke-Sonar 'streamRedirections/streaming/redirections/aux/isEnabled/false' 'Put' | Out-Null
        $back = if ($st.spotifyRole -in $homeRoles) { $st.spotifyRole } else { 'game' }
        foreach ($p in $pids) { Set-AppRole $p $back }
        Set-StateValue 'spotifyOnAir' $false
        Write-Log "Spotify is private again ($back channel)."
    }
}

# Spotify can reopen its audio stream (new device, restart); keep it on Aux while it's on air
function Confirm-SpotifyRoute {
    $active = @(Get-AppSessions 'Spotify' | Where-Object state -eq 'active')
    foreach ($s in ($active | Where-Object role -ne 'aux')) { Set-AppRole $s.pid 'aux' }
}

# ---------------- WARDOGS mic (ini) ----------------
function Set-WardogsMic([string]$deviceId) {
    if (Get-Process | Where-Object { $_.Name -like 'Wardogs*' }) {
        throw 'WARDOGS is running - close it first (it rewrites the ini on exit), or pick the mic in its Audio menu.'
    }
    if (-not (Test-Path $WardogsIni)) { throw "Not found: $WardogsIni" }
    $text = [IO.File]::ReadAllText($WardogsIni)
    if ($text -notmatch '(?m)^AudioInputDevice="[^"]*"') { throw 'AudioInputDevice line not found in the ini.' }
    Copy-Item $WardogsIni ("$WardogsIni.bak-{0:yyyyMMdd-HHmmss}" -f (Get-Date))
    $new = [regex]::Replace($text, '(?m)^AudioInputDevice="[^"]*"', "AudioInputDevice=`"$deviceId`"")
    [IO.File]::WriteAllText($WardogsIni, $new, (New-Object Text.UTF8Encoding($false)))
    Write-Log "WARDOGS mic set to $deviceId"
}

# ---------------- player ----------------
$script:Player = $null; $script:Resolver = $null; $script:Want = $false
$script:Current = -1; $script:RouteTries = 0; $script:Restarts = 0
$script:StationList = @()

function Load-Stations { $json = Get-Content $Stations -Raw | ConvertFrom-Json; $script:StationList = @($json | ForEach-Object { $_ }) }

function Stop-Radio {
    $script:Want = $false
    foreach ($p in @($script:Player, $script:Resolver)) {
        if ($p -and -not $p.HasExited) { try { $p.Kill() } catch {} }
    }
    $script:Player = $null; $script:Resolver = $null
}

function Start-Ffplay([string]$url, [int]$offset) {
    if (-not $FfplayExe) { throw 'ffplay not found (winget install Gyan.FFmpeg).' }
    $a = @('-nodisp', '-hide_banner', '-loglevel', 'error', '-autoexit')
    if ($url -like 'http*') { $a += '-reconnect', '1', '-reconnect_streamed', '1', '-reconnect_delay_max', '5' }
    if ($offset -gt 0) { $a += '-ss', "$offset" }
    if ($script:FilterBox -and $script:FilterBox.Checked) { $a += '-af', "`"$RadioFilter`"" }
    $a += "`"$url`""
    $psi = New-Object Diagnostics.ProcessStartInfo $FfplayExe, ($a -join ' ')
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $script:Player = [Diagnostics.Process]::Start($psi)
    $script:RouteTries = 12
}

function Play-Station([int]$i) {
    Stop-Radio
    if ($script:StationList.Count -eq 0) { return }
    $i = (($i % $script:StationList.Count) + $script:StationList.Count) % $script:StationList.Count
    $script:Current = $i; $script:Want = $true; $script:Restarts = 0
    $st = $script:StationList[$i]
    if ($script:StationBox) { $script:StationBox.SelectedIndex = $i }
    if ($st.type -eq 'youtube') {
        if (-not $YtdlpExe) { throw 'yt-dlp not found (winget install yt-dlp.yt-dlp).' }
        Write-Log "Tuning in: $($st.name)..."
        $psi = New-Object Diagnostics.ProcessStartInfo $YtdlpExe, ("--no-warnings --no-playlist -f bestaudio --print duration --print urls `"{0}`"" -f $st.source)
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true
        $script:Resolver = [Diagnostics.Process]::Start($psi)
        $script:ResolverOut = $script:Resolver.StandardOutput.ReadToEndAsync()
    } else {
        Start-Ffplay $st.source 0
        Write-Log "Playing: $($st.name)"
    }
}

# Called once a second from the GUI timer
function Invoke-Tick {
    if ($script:Resolver -and $script:Resolver.HasExited) {
        $lines = @($script:ResolverOut.Result -split "`r?`n" | Where-Object { $_ })
        $script:Resolver = $null
        $dur = 0; [int]::TryParse(($lines | Select-Object -First 1), [ref]$dur) | Out-Null
        $url = $lines | Where-Object { $_ -like 'http*' } | Select-Object -First 1
        if (-not $url) { Write-Log "Couldn't find that station on YouTube."; $script:Want = $false; return }
        $offset = 0
        if ($script:RandomBox -and $script:RandomBox.Checked -and $dur -gt 1200) { $offset = Get-Random -Minimum 0 -Maximum ($dur - 600) }
        Start-Ffplay $url $offset
        $mm = [int]($offset / 60)
        Write-Log ("Playing: {0}{1}" -f $script:StationList[$script:Current].name, $(if ($offset) { " (joined at ${mm}m)" } else { '' }))
    }
    # route the player to Media once its audio session exists
    if ($script:Player -and $script:RouteTries -gt 0 -and -not $script:Player.HasExited) {
        $script:RouteTries--
        try {
            $sess = @(Get-AppSessions 'ffplay' | Where-Object { $_.pid -eq $script:Player.Id -and $_.state -eq 'active' })
            if ($sess) {
                if ($sess | Where-Object role -eq 'media') { $script:RouteTries = 0 }
                else { Set-AppRole $script:Player.Id 'media' }
            }
        } catch {}
    }
    # station ended or dropped: keep the radio going
    if ($script:Want -and $script:Player -and $script:Player.HasExited) {
        $script:Player = $null
        if ($script:Restarts -lt 5) { $script:Restarts++; $keep = $script:Restarts; Play-Station $script:Current; $script:Restarts = $keep }
        else { $script:Want = $false; Write-Log 'Station keeps dropping - stopped.' }
    }
}

if ($NoGui) { Load-Stations; return }

# ================= GUI =================
# one window at a time (the watcher checks this mutex too)
$script:GuiMutex = New-Object Threading.Mutex($false, 'Local\WardogsRadioGui')
if (-not $script:GuiMutex.WaitOne(0)) { exit }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

# K = toggle proximity push-to-talk, only while the WARDOGS window is in front.
# A low-level keyboard hook swallows your physical K and holds a synthetic K down until the next tap.
if (-not ('WardogsKToggle' -as [type])) {
    Add-Type @'
using System; using System.Runtime.InteropServices; using System.Threading.Tasks;
public static class WardogsKToggle {
    delegate IntPtr HookProc(int n, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] struct KBD { public uint vk, scan, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Explicit, Size = 40)] struct INPUT {
        [FieldOffset(0)] public uint type; [FieldOffset(8)] public ushort wVk; [FieldOffset(10)] public ushort wScan;
        [FieldOffset(12)] public uint dwFlags; [FieldOffset(16)] public uint time; [FieldOffset(24)] public IntPtr extra; }
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, HookProc p, IntPtr mod, uint tid);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int n, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);

    const uint VK_K = 0x4B; const ushort SC_K = 0x25; const uint LLKHF_INJECTED = 0x10;
    static readonly HookProc proc = Hook;   // kept referenced so the GC can't collect it
    static IntPtr hook = IntPtr.Zero;
    static bool physDown, wasForeground;
    public static bool Enabled = true;
    public static int GamePid;
    public static volatile bool Latched;
    public static int Version;

    public static void Install() { if (hook == IntPtr.Zero) hook = SetWindowsHookEx(13, proc, GetModuleHandle(null), 0); }
    public static void Uninstall() { Set(false); if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; } }

    static bool GameForeground() {
        if (GamePid == 0) return false;
        uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        return pid == (uint)GamePid;
    }
    static void Send(bool down) {
        var i = new INPUT { type = 1, wScan = SC_K, dwFlags = 0x0008u | (down ? 0u : 0x0002u) };
        SendInput(1, new[] { i }, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void Set(bool on) {
        if (Latched == on) return;
        Latched = on; Send(on); Version++;
        Task.Run(() => { try { Console.Beep(on ? 1200 : 600, 70); } catch { } });
    }
    // called once a second: release when the game/feature goes away, re-press after alt-tabbing back
    public static void Tick() {
        if ((!Enabled || GamePid == 0) && Latched) Set(false);
        bool fg = GameForeground();
        if (Latched && fg && !wasForeground) Send(true);
        wasForeground = fg;
    }
    static IntPtr Hook(int n, IntPtr w, IntPtr l) {
        if (n >= 0 && Enabled) {
            var k = (KBD)Marshal.PtrToStructure(l, typeof(KBD));
            if (k.vk == VK_K && (k.flags & LLKHF_INJECTED) == 0 && GameForeground()) {
                int msg = (int)w;
                if (msg == 0x100 || msg == 0x104) { if (!physDown) { physDown = true; Set(!Latched); } }
                else physDown = false;
                return (IntPtr)1;   // swallow the physical key; the game only sees our held K
            }
        }
        return CallNextHookEx(hook, n, w, l);
    }
}
'@
}

if (-not ('WardogsRadioHotkeys' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms @'
using System; using System.Runtime.InteropServices; using System.Windows.Forms;
public class WardogsRadioHotkeys : NativeWindow, IDisposable {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    public Action<int> OnHotkey;
    int count = 0;
    public WardogsRadioHotkeys() { CreateHandle(new CreateParams()); }
    public bool Add(int id, Keys key) { count = Math.Max(count, id); return RegisterHotKey(Handle, id, 0x1 | 0x2 | 0x4000, (uint)key); }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && OnHotkey != null) OnHotkey(m.WParam.ToInt32());
        base.WndProc(ref m);
    }
    public void Dispose() { for (int i = 1; i <= count; i++) UnregisterHotKey(Handle, i); DestroyHandle(); }
}
'@
}

# Midnight purple theme
$bg     = [Drawing.Color]::FromArgb(20, 14, 38)     # deep midnight
$panel  = [Drawing.Color]::FromArgb(38, 26, 70)     # raised surfaces
$border = [Drawing.Color]::FromArgb(88, 62, 150)
$hover  = [Drawing.Color]::FromArgb(58, 40, 104)
$fg     = [Drawing.Color]::FromArgb(236, 228, 255)
$muted  = [Drawing.Color]::FromArgb(160, 146, 196)
$accent = [Drawing.Color]::FromArgb(196, 140, 255)  # lavender
$select = [Drawing.Color]::FromArgb(110, 66, 190)
$font = New-Object Drawing.Font('Segoe UI', 9.5)
$bold = New-Object Drawing.Font('Segoe UI Semibold', 9.5)

$W = 360; $M = 14   # content width, margin
$form = New-Object Windows.Forms.Form
$form.Text = 'WARDOGS Radio'; $form.TopMost = $true; $form.FormBorderStyle = 'FixedToolWindow'
$form.BackColor = $bg; $form.ForeColor = $fg; $form.Font = $font
$form.StartPosition = 'Manual'; $form.Location = New-Object Drawing.Point(40, 120)

function New-Btn($text, $x, $y, $w, $h = 30) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.SetBounds($x, $y, $w, $h); $b.FlatStyle = 'Flat'; $b.BackColor = $panel; $b.ForeColor = $fg
    $b.FlatAppearance.BorderColor = $border; $b.FlatAppearance.MouseOverBackColor = $hover
    $b.FlatAppearance.MouseDownBackColor = $select; $b.Cursor = 'Hand'; $form.Controls.Add($b); $b
}
function New-Lbl($text, $x, $y, $w, $h = 20) {
    $l = New-Object Windows.Forms.Label; $l.Text = $text; $l.SetBounds($x, $y, $w, $h); $l.ForeColor = $muted; $form.Controls.Add($l); $l
}
function New-Chk($text, $x, $y, $w) {
    $c = New-Object Windows.Forms.CheckBox; $c.Text = $text; $c.SetBounds($x, $y, $w, 24); $c.ForeColor = $fg; $form.Controls.Add($c); $c
}
function New-Slider($x, $y, $w) {
    # TrackBar enforces ~45 px height; the layout below reserves that much
    $t = New-Object Windows.Forms.TrackBar; $t.Minimum = 0; $t.Maximum = 100; $t.TickFrequency = 10; $t.SetBounds($x, $y, $w, 45)
    $t.BackColor = $bg; $form.Controls.Add($t); $t
}
function New-Rule($y) {
    $r = New-Object Windows.Forms.Label; $r.SetBounds($M, $y, $W, 1); $r.BackColor = $border; $form.Controls.Add($r)
}
function Try-Do([scriptblock]$sb) { try { & $sb } catch { Write-Log "Error: $($_.Exception.Message)" } }

$y = 12
$modeLbl = New-Lbl 'Sonar: ...' $M ($y + 5) 230
$modeLbl.ForeColor = $accent; $modeLbl.Font = $bold
$btnSetup = New-Btn 'Set up Sonar' ($M + $W - 120) $y 120
$y += 42

New-Lbl 'STATIONS' $M $y 200 | Out-Null; $y += 22
$script:StationBox = New-Object Windows.Forms.ListBox
$script:StationBox.SetBounds($M, $y, $W, 150); $script:StationBox.BackColor = $panel; $script:StationBox.ForeColor = $fg
$script:StationBox.BorderStyle = 'FixedSingle'; $script:StationBox.DrawMode = 'OwnerDrawFixed'; $script:StationBox.ItemHeight = 24
$script:StationBox.Add_DrawItem({
    param($s, $e)
    if ($e.Index -lt 0) { return }
    $sel = ($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0
    $brush = New-Object Drawing.SolidBrush $(if ($sel) { $select } else { $panel })
    $e.Graphics.FillRectangle($brush, $e.Bounds); $brush.Dispose()
    $playing = ($e.Index -eq $script:Current -and $script:Want)
    $text = $(if ($playing) { '> ' } else { '   ' }) + $s.Items[$e.Index]
    [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $text, $(if ($playing) { $bold } else { $font }),
        (New-Object Drawing.Point(($e.Bounds.X + 6), ($e.Bounds.Y + 3))), $(if ($playing) { $accent } else { $fg }))
})
$form.Controls.Add($script:StationBox)
$y += 158

$bw = [int](($W - 18) / 4)
$btnPlay = New-Btn 'Play' $M $y $bw
$btnStop = New-Btn 'Stop' ($M + ($bw + 6)) $y $bw
$btnNext = New-Btn 'Next' ($M + 2 * ($bw + 6)) $y $bw
$btnEdit = New-Btn 'Edit list' ($M + 3 * ($bw + 6)) $y $bw
$y += 40

$script:FilterBox = New-Chk 'Car-radio sound' $M $y 140
$script:RandomBox = New-Chk 'Join mid-broadcast (GTA style)' ($M + 145) $y ($W - 145)
$script:FilterBox.Checked = $true; $script:RandomBox.Checked = $true
$y += 34; New-Rule $y; $y += 12

$chkOnAir = New-Chk 'Music ON AIR (into my mic)' $M $y $W
$chkOnAir.Checked = $true; $chkOnAir.ForeColor = $accent; $chkOnAir.Font = $bold
$y += 28
New-Lbl 'On-air volume (what others hear)' $M $y $W | Out-Null; $y += 20
$sOnAir = New-Slider $M $y $W; $y += 50

$chkHear = New-Chk 'Hear radio in my headset' $M $y $W
$chkHear.Checked = $true; $chkHear.ForeColor = $accent; $chkHear.Font = $bold
$y += 28
New-Lbl 'My volume (what I hear)' $M $y $W | Out-Null; $y += 20
$sMine = New-Slider $M $y $W; $y += 50

$chkSpotify = New-Chk 'Spotify ON AIR (song requests)' $M $y $W
$chkSpotify.ForeColor = $accent; $chkSpotify.Font = $bold
$y += 28
$chkVoice = New-Chk 'My voice in game (off = game gets music only)' $M $y $W
$chkVoice.Checked = $true; $chkVoice.ForeColor = $accent; $chkVoice.Font = $bold
$y += 28
$chkK = New-Chk 'K toggles proximity mic' $M $y 260
$chkK.Checked = $true; $chkK.ForeColor = $accent; $chkK.Font = $bold
$micLbl = New-Lbl 'MIC: off' ($M + 265) ($y + 2) ($W - 265)
$micLbl.TextAlign = 'MiddleRight'; $micLbl.Font = $bold
$y += 34; New-Rule $y; $y += 12

New-Lbl 'WARDOGS mic (game must be closed)' $M $y $W | Out-Null; $y += 22
$hw = [int](($W - 8) / 2)
$btnMicStream = New-Btn 'Use Sonar Stream' $M $y $hw
$btnMicDirect = New-Btn 'Use headset mic direct' ($M + $hw + 8) $y $hw
$y += 38
$btnClassic = New-Btn 'Sonar back to Classic' $M $y $hw
$y += 40
$hk = New-Lbl "Hotkeys (Ctrl+Alt):  R music on-air   H headset   V voice`nN next station   X play/stop   S Spotify   |   K = mic toggle in game" $M $y $W 36
$hk.Font = New-Object Drawing.Font('Segoe UI', 8)
$y += 40; New-Rule $y; $y += 8

$script:StatusLabel = New-Lbl 'Ready.' $M $y $W 36
$script:StatusLabel.ForeColor = $fg
$y += 40
$form.ClientSize = New-Object Drawing.Size(($W + 2 * $M), $y)

function Refresh-Stations {
    Load-Stations
    $script:StationBox.Items.Clear()
    foreach ($s in $script:StationList) { [void]$script:StationBox.Items.Add($s.name) }
    if ($script:StationBox.Items.Count) { $script:StationBox.SelectedIndex = [Math]::Max(0, $script:Current) }
}

$script:Loading = $false
function Refresh-Sonar {
    try {
        $mode = Get-SonarMode
        if ($mode -eq 'stream') {
            $dev = Get-StreamCaptureDevice
            $modeLbl.Text = 'Sonar: Streamer mode' + $(if ($dev) { '' } else { ' (no Stream mic?)' })
            $v = Get-StreamerMediaVolumes
            $script:Loading = $true
            $sOnAir.Value = [Math]::Round($v.OnAir * 100); $sMine.Value = [Math]::Round($v.Mine * 100)
            $chkOnAir.Checked = -not $v.OnAirMuted
            $chkHear.Checked = -not $v.MineMuted
            $sm = @(Invoke-Sonar 'streamRedirections') | Where-Object streamRedirectionId -eq 'streaming'
            $chkVoice.Checked = [bool](($sm.status | Where-Object role -eq 'chatCapture').isEnabled)
            $script:Loading = $false
        } else {
            $modeLbl.Text = 'Sonar: Classic - click Set up'
        }
        $script:Loading = $true
        $chkSpotify.Checked = [bool](Get-State).spotifyOnAir
        if ($chkSpotify.Checked) {
            # re-apply on startup; if Spotify isn't playing yet, start off-air
            try { Set-SpotifyOnAir $true } catch {
                $chkSpotify.Checked = $false; Set-StateValue 'spotifyOnAir' $false
                Invoke-Sonar 'streamRedirections/streaming/redirections/aux/isEnabled/false' 'Put' | Out-Null
            }
        }
        $script:Loading = $false
    } catch {
        $modeLbl.Text = 'Sonar: not reachable'
        Write-Log $_.Exception.Message
    }
}

$btnSetup.Add_Click({ Try-Do { Initialize-Broadcast; Set-StreamerVolume 'streaming' 'media' 0.35; Refresh-Sonar } })
$btnPlay.Add_Click({ Try-Do { Play-Station $script:StationBox.SelectedIndex } })
$script:StationBox.Add_DoubleClick({ Try-Do { Play-Station $script:StationBox.SelectedIndex } })
$btnStop.Add_Click({ Stop-Radio; Write-Log 'Radio stopped.' })
$btnNext.Add_Click({ Try-Do { Play-Station ($script:Current + 1) } })
$btnEdit.Add_Click({ Start-Process notepad.exe $Stations -Wait; Try-Do { Refresh-Stations; Write-Log 'Station list reloaded.' } })
$chkOnAir.Add_CheckedChanged({ if (-not $script:Loading) { Try-Do { Set-StreamerMute 'streaming' 'media' (-not $chkOnAir.Checked); Write-Log $(if ($chkOnAir.Checked) { 'Music ON AIR.' } else { 'Music off air (only you hear it).' }) } } })
$chkVoice.Add_CheckedChanged({ if (-not $script:Loading) { Try-Do {
    Invoke-Sonar "streamRedirections/streaming/redirections/chatCapture/isEnabled/$(B $chkVoice.Checked)" 'Put' | Out-Null
    Write-Log $(if ($chkVoice.Checked) { 'Your voice is in the game mic.' } else { 'Game mic = music only (voice stays in Discord).' }) } } })
$chkHear.Add_CheckedChanged({ if (-not $script:Loading) { Try-Do { Set-StreamerMute 'monitoring' 'media' (-not $chkHear.Checked); Write-Log $(if ($chkHear.Checked) { 'Radio in your headset.' } else { 'Radio muted for you (still on air for others).' }) } } })
# the on-air slider sets both lanes: radio (Media) and Spotify (Aux)
$sOnAir.Add_MouseUp({ Try-Do { Set-StreamerVolume 'streaming' 'media' ($sOnAir.Value / 100); Set-StreamerVolume 'streaming' 'aux' ($sOnAir.Value / 100) } })
$sOnAir.Add_KeyUp({ Try-Do { Set-StreamerVolume 'streaming' 'media' ($sOnAir.Value / 100); Set-StreamerVolume 'streaming' 'aux' ($sOnAir.Value / 100) } })
$sMine.Add_MouseUp({ Try-Do { Set-StreamerVolume 'monitoring' 'media' ($sMine.Value / 100) } })
$sMine.Add_KeyUp({ Try-Do { Set-StreamerVolume 'monitoring' 'media' ($sMine.Value / 100) } })
$chkSpotify.Add_CheckedChanged({
    if ($script:Loading) { return }
    try { Set-SpotifyOnAir $chkSpotify.Checked }
    catch { Write-Log "Error: $($_.Exception.Message)"; $script:Loading = $true; $chkSpotify.Checked = -not $chkSpotify.Checked; $script:Loading = $false }
})
$btnMicStream.Add_Click({ Try-Do {
    $dev = Get-StreamCaptureDevice
    if (-not $dev) { throw 'Sonar Stream device not found - click Set up Sonar first.' }
    Set-WardogsMic $dev.id } })
$btnMicDirect.Add_Click({ Try-Do { $st = Get-State; if (-not $st.mic) { throw 'Headset mic unknown - click Set up Sonar first.' }; Set-WardogsMic $st.mic } })
$btnClassic.Add_Click({ Try-Do {
    Stop-Radio
    if ($chkSpotify.Checked) { Set-SpotifyOnAir $false }
    Invoke-Sonar 'mode/classic' 'Put' | Out-Null
    Write-Log 'Sonar back in Classic mode. (WARDOGS mic must be on your headset mic directly, or it hears nothing.)'
    Refresh-Sonar } })

# hotkeys: 1=R on-air, 2=N next, 3=X play/stop, 4=S spotify, 5=H headset
$hot = New-Object WardogsRadioHotkeys
$ok = @($hot.Add(1, 'R'), $hot.Add(2, 'N'), $hot.Add(3, 'X'), $hot.Add(4, 'S'), $hot.Add(5, 'H'), $hot.Add(6, 'V'))
if ($ok -contains $false) { Write-Log 'Some Ctrl+Alt hotkeys are taken by another app.' }
$hot.OnHotkey = [Action[int]] {
    param($id)
    switch ($id) {
        1 { $chkOnAir.Checked = -not $chkOnAir.Checked }
        2 { Try-Do { Play-Station ($script:Current + 1) } }
        3 { if ($script:Want) { Stop-Radio; Write-Log 'Radio stopped.' } else { Try-Do { Play-Station ([Math]::Max(0, $script:StationBox.SelectedIndex)) } } }
        4 { $chkSpotify.Checked = -not $chkSpotify.Checked }
        5 { $chkHear.Checked = -not $chkHear.Checked }
        6 { $chkVoice.Checked = -not $chkVoice.Checked }
    }
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1000
$chkK.Add_CheckedChanged({ [WardogsKToggle]::Enabled = $chkK.Checked; Write-Log $(if ($chkK.Checked) { 'K toggles your proximity mic in WARDOGS.' } else { 'K is back to hold-to-talk.' }) })
$script:MicVersion = -1
$script:MicTicks = 0
$micTimer = New-Object Windows.Forms.Timer
$micTimer.Interval = 200   # fast, so the LIVE light follows K immediately
$micTimer.Add_Tick({ try { Update-MicIndicator } catch {} })
function Update-MicIndicator {
    if (((++$script:MicTicks) % 5) -eq 1) {   # once a second: track the game and keep K held correctly
        $g = Get-Process -Name 'WardogsClient*' -ErrorAction SilentlyContinue | Select-Object -First 1
        [WardogsKToggle]::GamePid = $(if ($g) { $g.Id } else { 0 })
        [WardogsKToggle]::Tick()
    }
    if ([WardogsKToggle]::Version -ne $script:MicVersion) {
        $script:MicVersion = [WardogsKToggle]::Version
        if ([WardogsKToggle]::Latched) { $micLbl.Text = 'MIC: LIVE'; $micLbl.ForeColor = [Drawing.Color]::FromArgb(255, 92, 140) }
        else { $micLbl.Text = 'MIC: off'; $micLbl.ForeColor = $muted }
    }
}

$script:Ticks = 0; $script:GoneFor = 0
$timer.Add_Tick({
    try { Invoke-Tick } catch { Write-Log "Error: $($_.Exception.Message)" }
    $script:StationBox.Invalidate()   # keeps the "now playing" marker current
    # WARDOGS voice chat ignores its own mic setting and opens the Windows default mic,
    # so route the game's mic input to the Sonar Stream device (once per game launch)
    if (((++$script:RouteTick) % 5) -eq 1) {
        $g = Get-Process -Name 'WardogsClient*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($g -and $g.Id -ne $script:RoutedGame) {
            try {
                $dev = Get-StreamCaptureDevice
                if ($dev) {
                    Invoke-Sonar "AudioDeviceRouting/capture/$(Esc $dev.id)/$($g.Id)" 'Put' | Out-Null
                    $script:RoutedGame = $g.Id
                    Write-Log 'WARDOGS mic routed to Sonar Stream.'
                }
            } catch {}
        }
    }
    if ($chkSpotify.Checked -and ($script:RouteTick % 5) -eq 3) { try { Confirm-SpotifyRoute } catch {} }
    # follow the game: check every 5 s, close after ~15 s without it (survives a quick restart)
    if ($FollowGame -and ((++$script:Ticks) % 5 -eq 0)) {
        if (Get-Process -Name 'Wardogs*' -ErrorAction SilentlyContinue) { $script:GoneFor = 0 }
        elseif ((++$script:GoneFor) -ge 3) { Write-Log 'WARDOGS closed - shutting down radio.'; $form.Close() }
    }
})

$form.Add_Shown({ Refresh-Stations; Refresh-Sonar; $timer.Start()
    [WardogsKToggle]::Install(); $micTimer.Start()
    if (-not $FfplayExe) { Write-Log 'ffplay not found - install with: winget install Gyan.FFmpeg' }
    elseif (-not $YtdlpExe) { Write-Log 'yt-dlp not found - YouTube stations disabled.' } })
$form.Add_FormClosing({
    $timer.Stop(); $micTimer.Stop()
    [WardogsKToggle]::Uninstall()   # releases K if it was latched
    Stop-Radio
    if ($chkSpotify.Checked) { try { Set-SpotifyOnAir $false } catch {} }
    $hot.Dispose()
    try { $script:GuiMutex.ReleaseMutex() } catch {}
})

[void]$form.ShowDialog()
