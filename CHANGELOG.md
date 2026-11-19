# artix-install.sh changelog

## 1.0 (2026-11-18)

First release: a port of
[arch-install](https://github.com/aranmi-git/arch-install) 1.0 to Artix Linux.

### New for Artix
- **Init of your choice: OpenRC, runit, s6 or dinit.** Daemons come with
  their `<package>-<init>` start-script packages; service names are read from
  each package's file list and enabled the way the init expects (`rc-update`,
  runsvdir symlinks, s6 bundles + `s6-db-reload`, dinit `boot.d`).
- **Services written by the installer** for daemons without an Artix start
  script (logiops, keyd, input-remapper, CoolerControl, ckb-next, OpenLinkHub,
  grub-btrfsd, VM guest tools), for each of the four inits.
- **No systemd parts**: elogind for logins, busybox mkinitcpio hooks
  (`encrypt` with `cryptdevice=`, key file via `cryptkey=`), cronie for the
  snapper timeline and weekly `fstrim`, chrony, zramen, syslog-ng.
- **Window manager sessions** through `artix-session` (D-Bus session +
  PipeWire); desktops get PipeWire from an XDG autostart entry.
- **Arch repositories** ([extra], [multilib]) as an option, after Artix's.
- **[lib32]** for Steam and Wine.
- **Network**: NetworkManager, ConnMan or dhcpcd + iwd. Wi-Fi on the live ISO
  through ConnMan (or iwd).
- **Mirrors**: the ISO's list, or ranked with rankmirrors.
- **ZFS**: datasets other than `/` are legacy mounts in `/etc/fstab`;
  modules built with zfs-dkms (archzfs builds for Arch's kernels);
  ZFSBootMenu as kernel + initramfs started by a UEFI boot entry.
- **Ly** only when Artix has its start script for the chosen init; its tty's
  console login is switched off.

### Not carried over
- systemd-boot and unified kernel images (they need systemd's EFI stub).
- systemd-networkd; the COSMIC greeter.
- Carrying a live Wi-Fi network into the new system.

## What was tested, and what was not

### Automated, in this sandbox
- `shellcheck` clean with every optional check on.
- **Simulated install** (271 checks): GRUB with an encrypted `/boot`, rEFInd,
  Limine and EFISTUB on UEFI, GRUB, SYSLINUX and Limine on BIOS, ZFS with
  ZFSBootMenu (on LUKS2 and plain), spread over all four inits; services
  enabled per init, written services, snapper by cron, Secure Boot, no
  systemd command run or written, no password in any file or log.
- **Choice logic** (97 checks), **presets** (165), the **archzfs key** check
  against the real key files (4).

### Not tested
- **No real install yet**, on hardware or in a virtual machine.
- Artix's package and service names could not be listed from the sandbox;
  some were checked on packages.artixlinux.org. The installer checks every
  name against the live system's databases and reports missing ones.
- s6's database compile inside a chroot, Ly with each init, ZFS on a real
  Artix ISO, Secure Boot on real firmware.
