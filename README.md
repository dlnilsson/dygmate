# dygmate

Battery status for the Dygma Defy wireless, right in your system tray — over
RF and Bluetooth, on Windows and Linux. Right-click for the menu, and get an optional on-screen overlay when you
switch layers.

<p align="center">
  <img src="docs/notification.png" alt="Dygmate battery notification" height="160">
  <img src="docs/context-menu.png" alt="Dygmate context menu" height="160">
</p>

<p align="center">
  <img src="docs/dygmate-overlay.gif" alt="Dygmate layer overlay" width="426">
</p>

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
replug):

```sh
echo 'SUBSYSTEM=="tty", ATTRS{idVendor}=="35ef", ATTRS{idProduct}=="0012", TAG+="uaccess"' \
  | sudo tee /etc/udev/rules.d/99-dygmate.rules
sudo udevadm control --reload-rules && sudo udevadm trigger
```

`TAG+="uaccess"` grants access to the user of the active login session, so no
group membership is needed and it works for the tray too. Replug the keyboard
after adding or changing the rule.

Close Bazecor before running dygmate either way — the serial port is exclusive.
