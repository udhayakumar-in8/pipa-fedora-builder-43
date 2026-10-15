# Fedora Linux 44 for the Xiaomi Pad 6 (pipa)

[![](https://img.shields.io/badge/Pipa%20Linux%20Wiki-8A2BE2)](https://rr1111.github.io/pipa-linux-wiki)
[![](https://img.shields.io/badge/Releases-0000FF)](https://github.com/rr1111/pipa-fedora-builder-43/releases)


### This is a fork of [pipa-fedora-builder](https://github.com/timoxa0/pipa-fedora-builder)

### Flavors:
- Minimal KDE Plasma (recommended) or KDE Plasma Mobile Desktops

- Minimal Gnome Desktop

- TTY with essentials
  - No WM or DE preinstalled
  - run ```./niri-install``` to install & set up Niri or Hyprland with DankMaterialShell and get started quickly (Keyboard & Internet connection required) 
	
- Common Packages:
	- ```fish``` for a better command line experience, default for ```udhayakumar```
	- ```tuned``` & ```tuned-ppd``` for better performance and power profiles in Gnome and KDE
	- ```widevine-installer``` from Asahi Linux

#### [Installation guide](./INSTALL.md)
#### [Image building guide](./BUILD.md)

### Kernel Status:
| Sleep | Speakers | Mic | WLAN | Bluetooth | (Fast) Charging | Battery Status | Hall | Display | Brightness | Touch | GPU | USB (Host/Client) | DP alt mode | UFS | Back Camera | Front Camera | Sensors | Xiaomi Keyboard | Pen | Hall Sensor
| ----------- | ----------- | ----------- | ----------- | ----------- | ----------- | ----------- | ----------- | ----------- | ----------- | ----------- | ----------- | ----------- | ----------- | ----------- | ----------- | ----------- | ----------- | ----------- | ----------- | ----------- |
| ✅️ | ✅️ | ✅️ | ✅️ | ✅️ | ✅️ (~10w) | ✅️ | ✅️ | ✅️ | ✅️ | ✅️ | ✅️ | ✅️ | ✅️ | ✅️ | ⚠️ (sometimes) | ❌️ | ⚠️ (flaky) | ✅️ | ✅️ | ✅ |

### User Notes:
- Kernel updates are handled by dnf. The updated boot image will be flashed to the active slot
  
### Default Credentials:

- **Admin (sudo) User**
  - Username: `udhayakumar`
  - Password: `147147`

- **Root**
  - Username: `root`
  - Password: `fedora`

Change these default credentials after installation.

### Issues (all flavors):
- Front camera doesnt work, back camera might
- Sensors (accelerometer for auto screen rotation) are enabled by default. They can break after suspend, so the image restarts the ```hexagonrpcd-sdsp``` & ```iio-sensor-proxy``` services after every resume (it takes ~20s for rotation to come back). The accelerometer is checked once after boot, ~15s after each resume, and whenever iio-sensor-proxy reports it lost (```pipa-sensors-monitor```, event-driven via D-Bus, no polling); the sensors are restarted only if it's missing, giving up after 5 failed tries until reboot. Check them with ```sudo monitor-sensor``` (without sudo it only works from a terminal on the tablet itself, not over SSH). If it says *No accelerometer*, run ```pipa-sensor-check > sensors.txt``` and share the file

### Tips and Tricks:
- Run ```widevine-installer``` to install the Widevinde CDM for Firefox and Chromium based browsers, works for system packages only. **(The widevine CDM module is not altered in any way, nor is it preinstalled or distributed by me)**
- Visit [Pipa Linux Wiki](https://rr1111.github.io/pipa-linux-wiki) for more & general Info
- KDE Flavors: 
	- The login screen comes pre-rotated. If you change the rotation, apply it to plasmalogin in Settings -> Login Screen -> Apply Plasma Settings...
	- Auto rotation only runs in tablet mode by default; change it in Settings -> Display & Monitor -> Orientation
- Gnome Flavor:
	- Preinstalled: LibreOffice (Writer, Calc, Impress), Remmina (RDP/VNC), GNOME Terminal, Tilix, Text Editor, Vim, OpenVPN, RustDesk, VLC, Dia, Papers (PDF), GSConnect, nmap, and a C/C++ toolchain (gcc, make, cmake, autotools, gdb). Dark mode is on by default
	- Waterfox and AnyDesk have no ARM64 Linux builds, so they can't be installed on pipa. Firefox is preinstalled, and RustDesk is preinstalled as the AnyDesk alternative
	- Auto rotation works out of the box. Use the preinstalled Screen Rotate extension for a manual rotation toggle or to force auto rotation while a keyboard is attached
	- Install the [GJS OSK extension](https://github.com/Vishram1123/gjs-osk) to make the Gnome OSK usable (if your enter key gets stuck, remove it)
	- Install the [TouchUP extension](https://github.com/mityax/gnome-extension-touchup) to make the Gnome Shell more usable on a Touchscreen

## Related projects:
- [postmarketOS](https://wiki.postmarketos.org/wiki/Xiaomi_Pad_6_(xiaomi-pipa)) - pmOS for pipa
- [void-pipa](https://github.com/pipa-mainline/void-pipa) - Void Linux for pipa (EOL?)
- [void-linux-pipa](https://github.com/userg0d/void-linux-pipa) - Another Void Linux for pipa
- [pipa-alarm](https://t.me/pipa_mainline/32978) - alarm (Arch Linux ARM) for pipa
- [armtix-xiaomi-pipa](https://github.com/Neo10e/armtix-xiaomi-pipa) - ARMtix (Artix Linux ARM) for pipa

## Credits:
- [Pocketblue](https://github.com/pocketblue) for COPR Repos, packages & their awesome work
- [pipa-fedora-builder](https://github.com/timoxa0/pipa-fedora-builder) original scripts this is forked from, by timoxa0 (thanks!!!)
- [nabu-fedora-builder](https://github.com/nik012003/nabu-fedora-builder) original original scripts
- [Kernel port](https://github.com/pipa-mainline/linux) by adomerle, V1p0ll, Lukapanio, domin746826 and others
- [Void templates](https://github.com/pipa-mainline/void-pipa) by adomerle
- [Fedora Linux](https://www.fedoraproject.org)

This project is not associated with Fedora Linux or RedHat!
