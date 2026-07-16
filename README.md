# dygmate

Battery status for Dygma wireless keyboards — the [Defy](https://dygma.com/pages/defy), the Raise 2, and the
Sonsei — right in your system tray, over RF and Bluetooth, on Windows and Linux. Right-click for the menu, and get an optional on-screen overlay when you
switch layers.

<p align="center">
  <img src="docs/notification.png" alt="Dygmate battery notification" height="160">
  <img src="docs/context-menu.png" alt="Dygmate context menu" height="160">
</p>

<p align="center">
  <img src="docs/dygmate-overlay.gif" alt="Dygmate layer overlay" width="426">
</p>

## Install

### Windows

Until dygmate is on winget, paste this in PowerShell — it downloads the latest
release, verifies it against `SHA256SUMS.txt`, and installs to
`%LOCALAPPDATA%\Programs\dygmate`.

Download, verify, and extract:

```powershell
$d="$env:LOCALAPPDATA\Programs\dygmate"; New-Item -Force -ItemType Directory $d | Out-Null
$rel=curl.exe -s https://api.github.com/repos/dlnilsson/dygmate/releases/latest | ConvertFrom-Json
curl.exe -sL -o "$env:TEMP\dygmate.zip" $rel.assets.Where({$_.name -like '*windows-x86_64.zip'}).browser_download_url
$sums=curl.exe -sL $rel.assets.Where({$_.name -eq 'SHA256SUMS.txt'}).browser_download_url
if ((Get-FileHash "$env:TEMP\dygmate.zip").Hash -notin ($sums -split '\s+')) { throw 'SHA256 mismatch' }
tar.exe -xf "$env:TEMP\dygmate.zip" -C $d
```

To update to the latest release later, just re-run this block.

Add it to your user `PATH`:

```powershell
if (([Environment]::GetEnvironmentVariable('Path','User') -split ';') -notcontains $d) { [Environment]::SetEnvironmentVariable('Path', "$([Environment]::GetEnvironmentVariable('Path','User'));$d", 'User') }
```

Create a Startup shortcut and launch the tray:

```powershell
$s=(New-Object -ComObject WScript.Shell).CreateShortcut("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\dygmate-tray.lnk"); $s.TargetPath="$d\dygmate-tray.exe"; $s.Save()
Start-Process "$d\dygmate-tray.exe"
```

### Linux

#### AUR

```sh
yay -S dygmate-bin
```

The package installs the udev rule and the `dygmate-tray` user service, so you
can skip the manual steps under [Linux setup](#linux-setup) — just replug the
keyboard and enable the service:

```sh
systemctl --user enable --now dygmate-tray.service
```

## Build

Requires [Zig 0.16.0](https://ziglang.org/download/).

Build for the host (produces the CLI `dygmate` and the tray `dygmate-tray`):

```sh
zig build -Doptimize=ReleaseSmall
```

Cross-build both platforms at once into `zig-out/{windows,linux}/`:

```sh
zig build release
```

Run the tray directly:

```sh
zig build run-tray-linux   # Linux
zig build run-tray         # Windows
```

## Linux setup

Start `dygmate-tray` from your compositor's autostart, or enable the packaged
user service:

```sh
systemctl --user enable --now dygmate-tray.service
```

The service uses the user manager's session D-Bus and device permissions. If
you want the optional layer-shell OSD on Wayland, make sure the user manager
also receives the Wayland environment. Run this from your compositor's
autostart (or once in a terminal inside the Wayland session), then restart the
service:

```sh
systemctl --user import-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR
systemctl --user restart dygmate-tray.service
```

### Serial port permissions

The keyboard shows up as a CDC-ACM serial device (`/dev/ttyACM0`). By default
it's owned by `root` and a serial group, so a normal user can't open it and
dygmate reports:

```
failed to open /dev/ttyACM0 (AccessDenied) ...
```

Fix it in one of two ways.

**Add your user to the serial group** (simplest). Check the device's group
first:

```sh
ls -l /dev/ttyACM0     # e.g. crw-rw---- root uucp ...
```

Then join that group — `uucp` on Arch, `dialout` on Debian/Ubuntu:

```sh
sudo usermod -aG uucp "$USER"     # or: dialout
```

Log out and back in (or run `newgrp uucp`) for it to take effect.

**Or install a udev rule** (targeted to the Dygma, no group change, survives
replug). The AUR package already ships this rule — replug the keyboard and
skip this step. Manual install:

```sh
printf '%s\n' \
  'SUBSYSTEM=="tty", ATTRS{idVendor}=="35ef", ATTRS{idProduct}=="0012", TAG+="uaccess"' \
  'SUBSYSTEM=="tty", ATTRS{idVendor}=="35ef", ATTRS{idProduct}=="0021", TAG+="uaccess"' \
  'SUBSYSTEM=="tty", ATTRS{idVendor}=="35ef", ATTRS{idProduct}=="0031", TAG+="uaccess"' \
  | sudo tee /etc/udev/rules.d/99-dygmate.rules
sudo udevadm control --reload-rules && sudo udevadm trigger
```

`TAG+="uaccess"` grants access to the user of the active login session, so no
group membership is needed and it works for the tray too. Replug the keyboard
after adding or changing the rule.

Close [Bazecor](https://github.com/Dygmalab/Bazecor) before running dygmate either way — the serial port is exclusive.
