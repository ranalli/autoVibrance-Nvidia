#Requires -Version 5.1
<#
  NVVibranceMonitor.ps1
  System tray app: while any monitored .exe is running, sets NVIDIA Digital Vibrance
  to 100%. When they all close, restores the driver's stock (default) level.

  - Only touches displays that are driven by an NVIDIA GPU (the AMD iGPU is ignored).
  - Tray icon: double-click (or right-click > Open) to manage the list.
  - Config + log: %LOCALAPPDATA%\NVVibrance\ (config.json, vibrance_log.txt)
  - Optional custom icon: put vibrance.png (or vibrance.ico) next to this script or in %LOCALAPPDATA%\NVVibrance\.
#>

# ---------- Single instance ----------
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\NVVibranceMonitor_SingleInstance')
if (-not $script:Mutex.WaitOne(0)) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show('NV Vibrance Monitor is already running (check the system tray).', 'NV Vibrance Monitor')
    exit
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------- Native helpers (NvAPI + console hiding) ----------
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class Win32Console
{
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]   static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    public static void Hide() { IntPtr h = GetConsoleWindow(); if (h != IntPtr.Zero) ShowWindow(h, 0); }
}

public static class NvVibrance
{
    [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr QueryInterface(uint id);

    [StructLayout(LayoutKind.Sequential)]
    public struct DvcInfoEx
    {
        public uint version;
        public int currentLevel;
        public int minLevel;
        public int maxLevel;
        public int defaultLevel;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DvcInfo
    {
        public uint version;
        public int currentLevel;
        public int minLevel;
        public int maxLevel;
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int InitializeD();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int GetErrorMessageD(int nr, StringBuilder desc);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int EnumPhysicalGpusD([In, Out] IntPtr[] gpus, ref uint count);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int GpuFullNameD(IntPtr gpu, StringBuilder name);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int EnumDisplayD(uint index, ref IntPtr handle);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int GpusFromDisplayD(IntPtr display, [In, Out] IntPtr[] gpus, ref uint count);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int GetOutputIdD(IntPtr handle, ref uint outputId);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int GetDvcExD(IntPtr handle, uint outputId, ref DvcInfoEx info);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int SetDvcExD(IntPtr handle, uint outputId, ref DvcInfoEx info);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int GetDvcD(IntPtr handle, uint outputId, ref DvcInfo info);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int SetDvcD(IntPtr handle, uint outputId, int level);

    static InitializeD _init;
    static GetErrorMessageD _errMsg;
    static EnumPhysicalGpusD _enumGpus;
    static GpuFullNameD _gpuName;
    static EnumDisplayD _enumDisp;
    static GpusFromDisplayD _gpusFromDisp;
    static GetOutputIdD _outId;
    static GetDvcExD _getEx;
    static SetDvcExD _setEx;
    static GetDvcD _getLegacy;
    static SetDvcD _setLegacy;
    static bool _ready;

    static T Load<T>(uint id) where T : class
    {
        IntPtr p = QueryInterface(id);
        if (p == IntPtr.Zero) return null;
        return Marshal.GetDelegateForFunctionPointer(p, typeof(T)) as T;
    }

    static string ErrStr(int code)
    {
        if (_errMsg != null)
        {
            StringBuilder sb = new StringBuilder(64);
            if (_errMsg(code, sb) == 0 && sb.Length > 0)
                return code + " - " + sb.ToString();
        }
        return code.ToString();
    }

    static string EnsureInit()
    {
        if (_ready) return null;
        try
        {
            _init         = Load<InitializeD>(0x0150E828);
            _errMsg       = Load<GetErrorMessageD>(0x6C2D048C);
            _enumGpus     = Load<EnumPhysicalGpusD>(0xE5AC921F);
            _gpuName      = Load<GpuFullNameD>(0xCEEE8E9F);
            _enumDisp     = Load<EnumDisplayD>(0x9ABDD40D);
            _gpusFromDisp = Load<GpusFromDisplayD>(0x34EF9506);
            _outId        = Load<GetOutputIdD>(0xD995937E);
            _getEx        = Load<GetDvcExD>(0x0E45002D);
            _setEx        = Load<SetDvcExD>(0x4A82C2B1);
            _getLegacy    = Load<GetDvcD>(0x4085DE45);
            _setLegacy    = Load<SetDvcD>(0x172409B4);

            if (_init == null || _enumGpus == null || _gpuName == null || _enumDisp == null ||
                _gpusFromDisp == null || _outId == null || (_getEx == null && _getLegacy == null))
                return "NvAPI functions not found";

            int r = _init();
            if (r != 0) return "NvAPI_Initialize failed (" + ErrStr(r) + ")";
            _ready = true;
            return null;
        }
        catch (Exception ex) { return "NvAPI unavailable: " + ex.Message; }
    }

    static string GpuName(IntPtr gpu)
    {
        StringBuilder sb = new StringBuilder(64);
        if (_gpuName(gpu, sb) == 0) return sb.ToString();
        return "NVIDIA GPU";
    }

    // percent = target level (0-100). stock = restore the driver's default level instead.
    // Only displays attached to an NVIDIA GPU are touched; anything on another GPU (e.g. AMD iGPU) is skipped.
    public static string Apply(int percent, bool stock)
    {
        string err = EnsureInit();
        if (err != null) return err;

        // 1) Make sure an NVIDIA GPU is actually present and list it
        IntPtr[] gpus = new IntPtr[64];
        uint gpuCount = 0;
        int r = _enumGpus(gpus, ref gpuCount);
        if (r != 0 || gpuCount == 0) return "No NVIDIA GPU found (" + ErrStr(r) + ")";

        StringBuilder sb = new StringBuilder();
        sb.Append("GPU: ");
        for (uint g = 0; g < gpuCount; g++) { if (g > 0) sb.Append(", "); sb.Append(GpuName(gpus[g])); }
        sb.Append(" | ");

        // 2) Walk NVIDIA display handles, keeping only those driven by an NVIDIA GPU
        int applied = 0;
        for (uint i = 0; i < 16; i++)
        {
            IntPtr h = IntPtr.Zero;
            r = _enumDisp(i, ref h);
            if (r != 0) break; // end of enumeration (or error)

            IntPtr[] owners = new IntPtr[64];
            uint ownerCount = 0;
            r = _gpusFromDisp(h, owners, ref ownerCount);
            if (r != 0 || ownerCount == 0) { sb.Append("display " + i + ": not on NVIDIA GPU, skipped; "); continue; }

            uint outId = 0;
            r = _outId(h, ref outId);
            if (r != 0) { sb.Append("display " + i + ": outputId failed (" + ErrStr(r) + "); "); continue; }

            // Try Extended DVC API first
            if (_getEx != null && _setEx != null)
            {
                DvcInfoEx info = new DvcInfoEx();
                info.version = (uint)(Marshal.SizeOf(typeof(DvcInfoEx)) | (1 << 16));
                r = _getEx(h, outId, ref info);
                if (r == 0)
                {
                    int level = stock ? info.defaultLevel : Math.Max(info.minLevel, Math.Min(info.maxLevel, percent));
                    info.currentLevel = level;
                    r = _setEx(h, outId, ref info);
                    if (r == 0)
                    {
                        sb.Append("display " + i + " (" + GpuName(owners[0]) + ") -> " + level + "; ");
                        applied++;
                        continue;
                    }
                }
            }

            // Fallback to Legacy DVC API
            if (_getLegacy != null && _setLegacy != null)
            {
                DvcInfo info = new DvcInfo();
                info.version = (uint)(Marshal.SizeOf(typeof(DvcInfo)) | (1 << 16));
                int rLeg = _getLegacy(h, outId, ref info);
                if (rLeg == 0)
                {
                    int defaultLvl = (info.minLevel + info.maxLevel) / 2;
                    int level = stock ? defaultLvl : Math.Max(info.minLevel, Math.Min(info.maxLevel, percent));
                    rLeg = _setLegacy(h, outId, level);
                    if (rLeg == 0)
                    {
                        sb.Append("display " + i + " (" + GpuName(owners[0]) + ") -> " + level + " [legacy]; ");
                        applied++;
                        continue;
                    }
                    sb.Append("display " + i + ": set failed (" + ErrStr(rLeg) + "); ");
                    continue;
                }
                sb.Append("display " + i + ": get failed (" + ErrStr(rLeg) + "); ");
            }
            else
            {
                sb.Append("display " + i + ": get failed (" + ErrStr(r) + "); ");
            }
        }
        if (applied == 0) sb.Append("no NVIDIA-driven display was updated");
        return sb.ToString().Trim();
    }
}
'@

# Hide the console window this script runs in (so only the tray icon shows)
[Win32Console]::Hide()

# ---------- Paths / config ----------
$script:RepoUrl    = 'https://raw.githubusercontent.com/ranalli/autoVibrance-Nvidia/main/NVVibranceMonitor.ps1'
$script:IconUrl    = 'https://raw.githubusercontent.com/ranalli/autoVibrance-Nvidia/refs/heads/main/vibrance.ico'
$script:AppDir     = Join-Path $env:LOCALAPPDATA 'NVVibrance'
$script:LocalPs1   = Join-Path $script:AppDir 'NVVibranceMonitor.ps1'
$script:ConfigPath = Join-Path $script:AppDir 'config.json'
$script:LogPath    = Join-Path $script:AppDir 'vibrance_log.txt'
$script:StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'NVVibranceMonitor.lnk'
$script:PollMs     = 2000

$baseDir = if ($PSCommandPath) { Split-Path $PSCommandPath } else { $script:AppDir }
$script:LocalIconPng   = Join-Path $baseDir 'vibrance.png'
$script:LocalIconIco   = Join-Path $baseDir 'vibrance.ico'
$script:AppDataIconPng = Join-Path $script:AppDir 'vibrance.png'
$script:AppDataIconIco = Join-Path $script:AppDir 'vibrance.ico'

# Built-in 32x32 PNG tray icon fallback (Base64 encoded)
$script:EmbeddedIconBase64 = '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'

if (-not (Test-Path $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }

function Write-Log([string]$Message) {
    try {
        if ((Test-Path $script:LogPath) -and (Get-Item $script:LogPath).Length -gt 1MB) { Remove-Item $script:LogPath -Force }
        Add-Content -Path $script:LogPath -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    } catch { }
}

function Load-Config {
    $cfg = [pscustomobject]@{ TargetLevel = 100; Apps = @() }
    if (Test-Path $script:ConfigPath) {
        try {
            $raw = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            if ($null -ne $raw.TargetLevel) { $cfg.TargetLevel = [int]$raw.TargetLevel }
            $cfg.Apps = @($raw.Apps | Where-Object { $_ -and $_.Name })
        } catch { Write-Log "Config load failed: $($_.Exception.Message)" }
    }
    return $cfg
}

function Save-Config {
    try { $script:Config | ConvertTo-Json -Depth 5 | Set-Content -Path $script:ConfigPath -Encoding UTF8 }
    catch { Write-Log "Config save failed: $($_.Exception.Message)" }
}

$script:Config = Load-Config
$script:Active = $false
$script:Exiting = $false

# ---------- Startup shortcut (Launch at Startup) ----------
function Test-Startup { Test-Path $script:StartupLnk }

function Set-Startup([bool]$Enable) {
    if ($Enable) {
        if (-not (Test-Path $script:AppDir)) {
            New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        }

        if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
            if ($PSCommandPath -ne $script:LocalPs1) {
                Copy-Item -Path $PSCommandPath -Destination $script:LocalPs1 -Force
            }
        } else {
            Invoke-WebRequest -Uri $script:RepoUrl -OutFile $script:LocalPs1 -UseBasicParsing
        }

        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($script:StartupLnk)
        $lnk.TargetPath = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
        $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $script:LocalPs1
        $lnk.WorkingDirectory = $script:AppDir
        $lnk.WindowStyle = 7
        $lnk.Save()
    } elseif (Test-Path $script:StartupLnk) {
        Remove-Item $script:StartupLnk -Force
    }
}

# ---------- Vibrance control ----------
function Set-Vibrance([bool]$High) {
    $result = [NvVibrance]::Apply([int]$script:Config.TargetLevel, (-not $High))
    $label = if ($High) { "HIGH ($($script:Config.TargetLevel)%)" } else { 'STOCK' }
    Write-Log "Vibrance $label : $result"
    if ($result -notmatch '->') {
        $script:Tray.ShowBalloonTip(4000, 'NV Vibrance Monitor', $result, [System.Windows.Forms.ToolTipIcon]::Warning)
    }
}

function Update-Tooltip {
    $state = if ($script:Active) { "Active ($($script:Config.TargetLevel)%)" } else { 'Stock' }
    $text = "NV Vibrance - $state"
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    $script:Tray.Text = $text
    if ($script:StatusLabel) { $script:StatusLabel.Text = "Status: $state   |   Watching $(@($script:Config.Apps).Count) app(s)" }
}

function Test-AnyRunning {
    $apps = @($script:Config.Apps)
    if ($apps.Count -eq 0) { return $false }
    $running = @{}
    foreach ($p in [System.Diagnostics.Process]::GetProcesses()) {
        try { $running[$p.ProcessName.ToLowerInvariant()] = $true } catch { } finally { $p.Dispose() }
    }
    foreach ($a in $apps) {
        if ($running.ContainsKey(([string]$a.Name).ToLowerInvariant())) { return $true }
    }
    return $false
}

function Check-Apps {
    $any = Test-AnyRunning
    if ($any -and -not $script:Active) {
        $script:Active = $true
        Set-Vibrance $true
        Update-Tooltip
    } elseif (-not $any -and $script:Active) {
        $script:Active = $false
        Set-Vibrance $false
        Update-Tooltip
    }
}

# ---------- Tray icon (created first so the window can reuse it) ----------
function Convert-BitmapToIcon([System.Drawing.Bitmap]$SourceBmp) {
    $bmp = New-Object System.Drawing.Bitmap(32, 32)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.SmoothingMode = 'HighQuality'
    $g.DrawImage($SourceBmp, 0, 0, 32, 32)
    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = [System.Drawing.SystemIcons]::Application

# If no local or AppData icon exists, download vibrance.png into %LOCALAPPDATA%\NVVibrance\
$hasAnyIcon = (Test-Path $script:LocalIconPng) -or (Test-Path $script:LocalIconIco) -or
              (Test-Path $script:AppDataIconPng) -or (Test-Path $script:AppDataIconIco)

if (-not $hasAnyIcon) {
    try {
        Invoke-WebRequest -Uri $script:IconUrl -OutFile $script:AppDataIconPng -UseBasicParsing -ErrorAction Stop
        Write-Log "Downloaded icon to $($script:AppDataIconPng)"
    } catch {
        Write-Log "Icon download failed (falling back to embedded icon): $($_.Exception.Message)"
    }
}

$iconLoaded = $false
foreach ($pngPath in @($script:LocalIconPng, $script:AppDataIconPng)) {
    if (-not $iconLoaded -and (Test-Path $pngPath)) {
        try {
            $src = New-Object System.Drawing.Bitmap($pngPath)
            $script:Tray.Icon = Convert-BitmapToIcon $src
            $src.Dispose()
            $iconLoaded = $true
        } catch { Write-Log "PNG icon load failed ($pngPath): $($_.Exception.Message)" }
    }
}

if (-not $iconLoaded) {
    foreach ($icoPath in @($script:LocalIconIco, $script:AppDataIconIco)) {
        if (-not $iconLoaded -and (Test-Path $icoPath)) {
            try {
                $script:Tray.Icon = New-Object System.Drawing.Icon($icoPath)
                $iconLoaded = $true
            } catch { Write-Log "ICO icon load failed ($icoPath): $($_.Exception.Message)" }
        }
    }
}

if (-not $iconLoaded -and $script:EmbeddedIconBase64) {
    try {
        $bytes = [Convert]::FromBase64String($script:EmbeddedIconBase64)
        $ms = New-Object System.IO.MemoryStream(, $bytes)
        $src = New-Object System.Drawing.Bitmap($ms)
        $script:Tray.Icon = Convert-BitmapToIcon $src
        $src.Dispose()
        $ms.Dispose()
    } catch { Write-Log "Embedded icon load failed: $($_.Exception.Message)" }
}
$script:Tray.Visible = $true

# ---------- Manager window ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'NV Vibrance Monitor'
$form.Size = New-Object System.Drawing.Size(640, 440)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(480, 300)
$form.ShowInTaskbar = $true
$form.Icon = $script:Tray.Icon

$list = New-Object System.Windows.Forms.ListView
$list.View = 'Details'
$list.FullRowSelect = $true
$list.MultiSelect = $true
$list.GridLines = $true
$list.HideSelection = $false
[void]$list.Columns.Add('Process', 170)
[void]$list.Columns.Add('Path', 420)
$list.Location = New-Object System.Drawing.Point(12, 12)
$list.Size = New-Object System.Drawing.Size(600, 310)
$list.Anchor = 'Top,Bottom,Left,Right'

$btnAdd = New-Object System.Windows.Forms.Button
$btnAdd.Text = 'Add...'
$btnAdd.Size = New-Object System.Drawing.Size(100, 30)
$btnAdd.Location = New-Object System.Drawing.Point(12, 332)
$btnAdd.Anchor = 'Bottom,Left'

$btnRemove = New-Object System.Windows.Forms.Button
$btnRemove.Text = 'Remove'
$btnRemove.Size = New-Object System.Drawing.Size(100, 30)
$btnRemove.Location = New-Object System.Drawing.Point(120, 332)
$btnRemove.Anchor = 'Bottom,Left'

$script:StatusLabel = New-Object System.Windows.Forms.Label
$script:StatusLabel.AutoSize = $false
$script:StatusLabel.Size = New-Object System.Drawing.Size(600, 20)
$script:StatusLabel.Location = New-Object System.Drawing.Point(12, 372)
$script:StatusLabel.Anchor = 'Bottom,Left,Right'

$form.Controls.AddRange(@($list, $btnAdd, $btnRemove, $script:StatusLabel))

function Refresh-List {
    $list.BeginUpdate()
    $list.Items.Clear()
    foreach ($a in @($script:Config.Apps)) {
        $item = New-Object System.Windows.Forms.ListViewItem(([string]$a.Name + '.exe'))
        [void]$item.SubItems.Add([string]$a.Path)
        $item.Tag = [string]$a.Name
        [void]$list.Items.Add($item)
    }
    $list.EndUpdate()
    Update-Tooltip
}

$btnAdd.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Select application(s) to monitor'
    $dlg.Filter = 'Applications (*.exe)|*.exe'
    $dlg.Multiselect = $true
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $apps = New-Object System.Collections.ArrayList
        foreach ($a in @($script:Config.Apps)) { [void]$apps.Add($a) }
        foreach ($file in $dlg.FileNames) {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($file)
            $exists = $false
            foreach ($a in $apps) { if (([string]$a.Name) -ieq $name) { $exists = $true; break } }
            if (-not $exists) { [void]$apps.Add([pscustomobject]@{ Name = $name; Path = $file }) }
        }
        $script:Config.Apps = @($apps)
        Save-Config
        Refresh-List
        Check-Apps
    }
    $dlg.Dispose()
})

$removeAction = {
    if ($list.SelectedItems.Count -gt 0) {
        $names = @($list.SelectedItems | ForEach-Object { [string]$_.Tag })
        $script:Config.Apps = @(@($script:Config.Apps) | Where-Object { $names -notcontains ([string]$_.Name) })
        Save-Config
        Refresh-List
        Check-Apps
    }
}
$btnRemove.Add_Click($removeAction)
$list.Add_KeyDown({ if ($_.KeyCode -eq 'Delete') { & $removeAction } })

# Closing the window just hides it; the app lives in the tray
$form.Add_FormClosing({
    if (-not $script:Exiting) { $_.Cancel = $true; $form.Hide() }
})

# ---------- Tray menu ----------
$showManager = {
    Refresh-List
    $form.Show()
    $form.WindowState = 'Normal'
    $form.Activate()
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('Open / Manage list')
$miOpen.Font = New-Object System.Drawing.Font($miOpen.Font, [System.Drawing.FontStyle]::Bold)
$miStartup = New-Object System.Windows.Forms.ToolStripMenuItem('Launch at Startup')
$miStartup.CheckOnClick = $true
$miStartup.Checked = Test-Startup
[void]$menu.Items.Add($miStartup)
[void]$menu.Items.Add('-')
$miExit = $menu.Items.Add('Exit')
$script:Tray.ContextMenuStrip = $menu

$miOpen.Add_Click($showManager)
$script:Tray.Add_DoubleClick($showManager)
$miStartup.Add_Click({
    try { Set-Startup $miStartup.Checked }
    catch {
        $miStartup.Checked = Test-Startup
        Write-Log "Startup toggle failed: $($_.Exception.Message)"
        [void][System.Windows.Forms.MessageBox]::Show("Failed to update startup setting: $($_.Exception.Message)", 'NV Vibrance Monitor')
    }
})
$miExit.Add_Click({
    $script:Exiting = $true
    $script:Timer.Stop()
    if ($script:Active) { Set-Vibrance $false; $script:Active = $false }
    $script:Tray.Visible = $false
    $script:Tray.Dispose()
    $form.Close()
    [System.Windows.Forms.Application]::Exit()
})

# ---------- Monitor loop ----------
$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = $script:PollMs
$script:Timer.Add_Tick({ try { Check-Apps } catch { Write-Log "Tick error: $($_.Exception.Message)" } })

Refresh-List
Write-Log "Started. Watching $(@($script:Config.Apps).Count) app(s)."
Check-Apps
$script:Timer.Start()

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    if ($script:Active) { Set-Vibrance $false }   # safety net (e.g. logoff)
    try { $script:Mutex.ReleaseMutex() } catch { }
    Write-Log 'Exited.'
}
