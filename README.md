# NV Vibrance Monitor (`autoVibrance-Nvidia`)

A lightweight Windows system tray utility that automatically boosts **NVIDIA Digital Vibrance** to `100%` whenever specified games or applications are running, and restores your driver's stock (default) vibrance level as soon as they close.

---

## Features

- **Automatic Vibrance Switching:** Polls running processes every 2 seconds and switches Digital Vibrance between your target level (`100%` by default) and stock.
- **NVIDIA-Only Display Filtering:** Only adjusts displays driven by an NVIDIA GPU via `nvapi64.dll`. Displays connected to integrated graphics (AMD/Intel iGPUs) are untouched.
- **System Tray Manager:** Double-click the tray icon (or right-click -> **Open / Manage list**) to add or remove `.exe` files from your watch list.
- **Self-Installing Autostart:** Toggle **Launch at Startup** from the tray menu to save a local copy to `%LOCALAPPDATA%\NVVibrance` and register a Windows Startup shortcut automatically.
- **Built-In Procedural Icon:** Renders a clean custom tray icon directly in memory—no external image files required (optional `vibrance.png` or `vibrance.ico` overrides are still supported).
- **Safe Restoration:** Automatically restores your stock vibrance level when exiting the tray app or logging off Windows.

---

## Quick Start

### Option 1: Run from PowerShell (Recommended)

Open **PowerShell** (or **Windows Terminal**) and run:

```powershell
irm "https://raw.githubusercontent.com/ranalli/autoVibrance-Nvidia/refs/heads/main/NVVibranceMonitor.ps1" | iex
```

> **Note:** Avoid running `irm | iex` from the `Win + R` Run dialog. Launching PowerShell commands directly from Windows Explorer (`Win + R`) triggers strict behavioral heuristics in antivirus tools like ESET (`PowerShell/Runner.E`). Running from an open PowerShell terminal avoids this.

### Option 2: Download and Run Locally (Antivirus-Friendly Fallback)

If your security software blocks in-memory `irm | iex` execution on new repositories, download the script to `%LOCALAPPDATA%\NVVibrance` first and launch it normally:

```powershell
mkdir "$env:LOCALAPPDATA\NVVibrance" -Force | Out-Null
irm "https://raw.githubusercontent.com/ranalli/autoVibrance-Nvidia/refs/heads/main/NVVibranceMonitor.ps1" -OutFile "$env:LOCALAPPDATA\NVVibrance\NVVibranceMonitor.ps1"
Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%LOCALAPPDATA%\NVVibrance\NVVibranceMonitor.ps1"'
```

---

## Usage

1. Once launched, look for the **NV Vibrance Monitor** icon in your Windows system tray (near the clock).
2. **Double-click** the tray icon (or right-click and choose **Open / Manage list**) to open the manager window.
3. Click **Add...** and select any `.exe` files you want to trigger Digital Vibrance (for example, `cs2.exe`, `VALORANT-Win64-Shipping.exe`, or `javaw.exe`).
4. Right-click the tray icon and check **Launch at Startup** if you want the monitor to start automatically with Windows.

---

## Configuration & Logs

All configuration and diagnostic logs are stored in `%LOCALAPPDATA%\NVVibrance\`:

- **`config.json`**: Stores your watched applications list and target vibrance percentage (`TargetLevel`, default `100`). You can edit `TargetLevel` (0–100) in any text editor and restart the app to use a custom level.
- **`vibrance_log.txt`**: Logs GPU detection, display updates, and any NvAPI errors (automatically rotated at 1 MB).
- **`NVVibranceMonitor.ps1`**: Local copy saved automatically when **Launch at Startup** is enabled.

---

## Requirements

- **OS:** Windows 10 or Windows 11 (64-bit)
- **PowerShell:** Windows PowerShell 5.1 or newer (built into Windows)
- **Hardware:** NVIDIA GPU with NVIDIA display drivers installed (`nvapi64.dll`)
