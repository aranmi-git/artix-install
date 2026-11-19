#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# =============================================================================
#  artix-install.sh - menu-driven (dialog) installer for Artix Linux
#  https://github.com/aranmi-git/artix-install
#
#  Copyright (C) 2026 aranmi-git
#
#  This program is free software; you can redistribute it and/or modify it
#  under the terms of the GNU General Public License, version 2, as published
#  by the Free Software Foundation.
#
#  This program is distributed in the hope that it will be useful, but WITHOUT
#  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
#  FITNESS FOR A PARTICULAR PURPOSE. See the LICENSE file for the full text.
# =============================================================================
#
#  Features
#    * Init system of your choice: OpenRC, runit, s6 or dinit (no systemd);
#      every service is enabled the way that init expects
#    * UEFI (64-bit or 32-bit firmware) or legacy BIOS; GPT; whole-disk install
#    * Root filesystem: ext4, btrfs or ZFS
#        btrfs subvolumes: @ @home @snapshots @var_log @var_cache_pacman (+ @swap)
#        ZFS: pool zroot from archzfs, booted by ZFSBootMenu
#    * Encryption of the root partition: none, LUKS1 or LUKS2
#    * Boot loader: GRUB, Limine, rEFInd, EFISTUB, SYSLINUX/EXTLINUX or
#      ZFSBootMenu, following your kernel order
#    * Secure Boot with your own keys (sbctl)
#    * Snapshots: snapper on btrfs, or ZFS snapshots (before every pacman run)
#    * Kernels: linux, linux-lts, linux-zen, linux-hardened, in any order
#    * Optional Arch Linux repositories (extra, multilib) via artix-archlinux-support
#    * Keymap, locale, timezone, zram or swap file; NetworkManager, ConnMan or
#      dhcpcd + iwd
#    * Any number of desktops and window managers (incl. Hyprland), each with a
#      full tool set; login screen LightDM, SDDM, GDM, greetd/tuigreet, Ly
#    * Dotfile presets: CachyOS, EndeavourOS, Garuda, LARBS, gh0stzk, Chris Titus
#    * GPU drivers, applications, gaming (lib32, Steam, Wine), peripherals
#    * AUR helper of your choice (yay or paru) and AUR packages
#    * Several users, each with a sudo level; LARBS-style bootstrap
#    * Presets: install the same system again with a few answers
#
#  Usage
#    Boot an official Artix Linux ISO (x86_64; any init), connect to the
#    internet (connmanctl or nmtui for Wi-Fi), then run as root:
#        bash artix-install.sh
#
#  Partition layouts (GPT)
#    UEFI + GRUB, /boot inside root ..... ESP 512M (/boot/efi) | root
#    UEFI + GRUB, unencrypted /boot ..... ESP 1G   (/boot)     | root
#    UEFI + Limine/rEFInd/EFISTUB ....... ESP 1G   (/boot)     | root
#    UEFI + ZFSBootMenu ................. ESP 1G   (/boot/efi) | root (ZFS pool)
#    BIOS + GRUB, /boot inside root ..... BIOS boot 2M | root
#    BIOS + GRUB, unencrypted /boot ..... BIOS boot 2M | /boot 1G ext4  | root
#    BIOS + Limine ...................... BIOS boot 2M | /boot 1G FAT32 | root
#    BIOS + SYSLINUX .................... /boot 1G ext2 (legacy BIOS bootable) | root
#  "root" is the filesystem itself, or a LUKS container that holds it.
#
#  Encryption notes
#    * GRUB with /boot inside the encrypted root: GRUB asks for the passphrase
#      (US keyboard layout), then a key file inside the initramfs unlocks root,
#      so you type it only once. GRUB cannot use Argon2, so LUKS2 volumes that
#      GRUB must open are created with PBKDF2.
#    * Every other boot loader (and GRUB with an unencrypted /boot): kernel +
#      initramfs live on an unencrypted partition and the initramfs (encrypt
#      hook) asks for the passphrase; LUKS2 then uses Argon2id.
#  rEFInd, EFISTUB and SYSLINUX entries are written by
#  /usr/local/bin/update-boot-menu (settings: /etc/default/artix-boot), run by a
#  pacman hook whenever a kernel is installed, updated or removed.
#
#  !!! THE SELECTED DISK IS ERASED COMPLETELY !!!   Log: /tmp/artix-install.log
#  Keep backups.
# =============================================================================

SCRIPT_VERSION="1.0"
BACKTITLE="Artix Linux installer ${SCRIPT_VERSION}"
LOG=/tmp/artix-install.log
WARN_FILE=/tmp/artix-install.warnings
TARGET=/mnt/target
CRYPT_NAME=cryptroot

# Sizes in MiB
ESP_SIZE_MIB=512        # ESP when it only holds the GRUB EFI binary
BOOT_SIZE_MIB=1024      # ESP / boot partition that also holds kernels + initramfs
BIOSBOOT_SIZE_MIB=2     # GPT "BIOS boot" partition (GRUB core.img / Limine stage 2)
MIN_ROOT_GIB=8

BTRFS_OPTS="noatime,compress=zstd:1"
BTRFS_SUBVOLS=("@:/" "@home:/home" "@snapshots:/.snapshots" "@var_log:/var/log" "@var_cache_pacman:/var/cache/pacman/pkg")

GUID_ESP=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
GUID_BIOS=21686148-6449-6E6F-744E-656564454649
GUID_LINUX=0FC63DAF-8483-4772-8E79-3D69D8477DE4
GUID_LUKS=CA7D7CCB-63ED-4C53-861C-1742536059CC

ALL_KERNELS="linux linux-lts linux-zen linux-hardened"

# Init systems Artix offers; services come in "<package>-<init>" packages.
ALL_INITS="openrc runit s6 dinit"

# ZFS: the archzfs repository (built for Arch's kernels: on Artix the module is
# built with zfs-dkms)
ZPOOL=zroot
ZFS_BE=zroot/ROOT/artix
ARCHZFS_SERVER=https://github.com/archzfs/archzfs/releases/download/experimental
ARCHZFS_KEY=3A9917BF0DED5C13F69AC68FABEC0A1208037BE9
ZBM_VERSION=3.1.0
ZBM_GIT=https://github.com/zbm-dev/zfsbootmenu
ZBM_COMMIT=7174e420590a270ece3c6426bdb1d5cdd9ef27b0
# The archzfs release key, from the project's keyring repository (pinned commit)
ARCHZFS_KEYRING=https://raw.githubusercontent.com/archzfs/archzfs-keyring/82e6ac2d2001f1ff8f92f50f7d4cf97069b74659/keyring/packager/archzfs
ARCHZFS_UID=ArchZFS_Project__https___github.com_archzfs__51bd577f

# ---- user choices (defaults) ------------------------------------------------
DISK=""
INIT=openrc             # openrc | runit | s6 | dinit
ARCH_REPOS=0            # 1 = also use Arch's [extra] (and [multilib]) via artix-archlinux-support
FS=ext4                 # ext4 | btrfs | zfs (zfs: ZFSBootMenu, pool on LUKS)
ENC=luks2               # none | luks1 | luks2
BOOTLOADER=grub         # grub | limine | refind | efistub | syslinux | zfsbootmenu
GRUB_BOOT=encrypted     # encrypted | separate   (only GRUB + encryption)
SECUREBOOT=0            # 1 = sign the boot chain with your own keys (sbctl)
SNAPPER=0               # 1 = snapshots of / (snapper on btrfs, ZFS snapshots on ZFS)
SWAP=zram               # none | zram | file
SWAP_SIZE=4             # GiB, for SWAP=file
KERNELS="linux linux-lts"   # boot order, first = default; any of ALL_KERNELS
MIRROR=auto             # auto (the ISO's mirror list) | rank (fastest first, rankmirrors)
HOST_NAME=artix
KEYMAP=us
LOCALE=en_US.UTF-8
TIMEZONE=UTC
ROOT_PASS=""
USER_NAME=""            # primary user (first in USERS): owns the AUR helper and the dotfiles
USERS=()                # login names, in order
declare -A U_FULL=() U_PASS=() U_SUDO=()   # per user: full name, password, sudo level (sudo|nopasswd|none)
BS_PROGS=""             # LARBS-style programs list: local path or http(s) URL of a CSV
BS_DOTFILES=""          # git URL of a dotfiles repository, copied into the primary user's home
BS_BRANCH=""            # branch of the dotfiles repository (empty = default)
BS_SHELL=bash           # login shell of the primary user: bash | zsh | fish
BS_POWER=0              # 1 = wheel may run shutdown/reboot/mount/pacman -Syu without a password
STANDALONE=0            # 1 = --bootstrap on an installed system (TARGET=/)
LUKS_PASS=""
NET="nm"                # nm | connman | dhcpcd (+ iwd for Wi-Fi) | none
DESKTOP=none            # none, or a list of desktop/WM ids from desktop_table (xfce plasma i3 hyprland ...)
DM=auto                 # login screen: auto | lightdm | sddm | gdm | greetd | ly | none
DOTS=""                 # dotfile presets from dots_table (cachyos-i3 larbs ...)
EXTRA_PKGS=""           # packages from the official repositories
GPU=auto                # auto | none | list of: intel amd nouveau nvidia nvidia-dkms vm
APPS=""                 # list chosen in the Applications menu
GAMING=""               # list of: multilib steam wine lutris gamemode winetricks (multilib = Artix's [lib32])
PERIPH=""               # peripheral support: see periph_table
AUR_HELPER=none         # none | yay | paru
AUR_PKGS=""             # packages from the AUR (needs an AUR helper)

# ---- detected / computed ----------------------------------------------------
FIRMWARE=bios           # uefi | bios
EFI_BITS=64
ESP_PART="" ESP_NUM="" ESP_MOUNT="" ESP_SIZE=0
BIOSBOOT_PART="" BIOSBOOT_NUM=""
BOOT_PART="" BOOT_NUM="" BOOT_FS=""
ROOT_PART="" ROOT_NUM=""
ALL_PARTS=()
INSTALL_STARTED=0

# =============================================================================
#  Small helpers
# =============================================================================
die() {
	clear 2>/dev/null
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

# Hide credentials embedded in URLs (https://user:token@host/...) on stdin.
mask_secrets() { sed -u -E 's#(://)[^/@[:space:]"'"'"']+@#\1***@#g'; }

# Record a non-fatal problem (shown at the end of the installation).
warn() {
	printf 'WARNING: %s\n' "$*" >&2
	printf '%s\n' "$*" | mask_secrets >>"$WARN_FILE"
}

trim() {
	local s=$*
	s=${s#"${s%%[![:space:]]*}"}
	s=${s%"${s##*[![:space:]]}"}
	printf '%s' "$s"
}

encrypted()        { [[ $ENC != none ]]; }
grub_unlocks()     { [[ $BOOTLOADER == grub && $ENC != none && $GRUB_BOOT == encrypted ]]; }
# Boot methods whose kernel and initramfs live on the EFI system partition
# (mounted at /boot): the firmware or boot manager can only read FAT.
kernels_on_esp()   { [[ $BOOTLOADER == limine || $BOOTLOADER == refind || $BOOTLOADER == efistub ]]; }
# Methods that need 64-bit UEFI / BIOS firmware.
uefi_only()        { [[ $BOOTLOADER == refind || $BOOTLOADER == efistub || $BOOTLOADER == zfsbootmenu ]]; }
bios_only()        { [[ $BOOTLOADER == syslinux ]]; }
# Methods whose menu is written by /usr/local/bin/update-boot-menu.
uses_boot_menu()   { { uefi_only || bios_only; } && [[ $BOOTLOADER != zfsbootmenu ]]; }
boot_is_separate() { kernels_on_esp || bios_only || [[ $BOOTLOADER == grub && $ENC != none && $GRUB_BOOT == separate ]]; }
efi_arch()         { if [[ $EFI_BITS == 32 ]]; then echo ia32; else echo x64; fi; }
# Boot methods that Secure Boot is offered for (the firmware checks each step).
sb_capable()       { [[ $BOOTLOADER == efistub || $BOOTLOADER == refind || $BOOTLOADER == grub ]]; }
secureboot_on()    { [[ $SECUREBOOT == 1 && $FIRMWARE == uefi && $EFI_BITS == 64 ]] && sb_capable; }
snapper_on()       { [[ $SNAPPER == 1 && $FS == btrfs ]]; }
zfs_on()           { [[ $FS == zfs ]]; }
zfs_snap_on()      { [[ $SNAPPER == 1 && $FS == zfs ]]; }
# A key file in the initramfs unlocks root a second time: after GRUB (encrypted
# /boot) or ZFSBootMenu (pool on LUKS) already asked for the passphrase.
needs_keyfile()    { grub_unlocks || { zfs_on && encrypted; }; }
aur_on()           { [[ $AUR_HELPER == yay || $AUR_HELPER == paru ]]; }

grub_efi_target() {
	if [[ $EFI_BITS == 32 ]]; then echo i386-efi; else echo x86_64-efi; fi
}

root_device() {
	if encrypted; then echo "/dev/mapper/$CRYPT_NAME"; else echo "$ROOT_PART"; fi
}

# /dev/sda + 2 -> /dev/sda2 ; /dev/nvme0n1 + 2 -> /dev/nvme0n1p2
part_name() {
	if [[ $1 =~ [0-9]$ ]]; then echo "${1}p${2}"; else echo "${1}${2}"; fi
}

# has "<space separated list>" <word>
has() { [[ " $1 " == *" $2 "* ]]; }
without() { # without "<list>" word -> the list minus that word
	local w out=""
	for w in $1; do [[ $w == "$2" ]] || out+="${out:+ }$w"; done
	printf '%s\n' "$out"
}

multilib_on() { has "$GAMING" multilib || has "$GAMING" steam || has "$GAMING" wine; }
arch_repos_on() { [[ $ARCH_REPOS == 1 ]]; }

cpu_vendor() {
	case $(awk -F': ' '/^vendor_id/ { print $2; exit }' /proc/cpuinfo 2>/dev/null) in
		GenuineIntel) echo intel ;;
		AuthenticAMD) echo amd ;;
		*) echo other ;;
	esac
}

# GPU vendors found on the PCI bus -> driver keywords
detect_gpus() {
	local id out=""
	while read -r id; do
		case ${id:1:4} in
			8086) out+=" intel" ;;
			1002) out+=" amd" ;;
			10de) out+=" nouveau" ;;
			80ee | 15ad | 1af4 | 1234 | 1b36) out+=" vm" ;;
		esac
	done < <(lspci -nn 2>/dev/null | grep -E '\[03(00|02|80)\]' | grep -oE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' || true)
	tr ' ' '\n' <<<"$out" | awk 'NF && !seen[$0]++' | paste -sd ' ' -
}

vm_type() {
	local v
	v=$(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null | tr '\n' ' ') || true
	case $v in
		*innotek* | *VirtualBox*) echo virtualbox ;;
		*VMware*) echo vmware ;;
		*QEMU* | *KVM* | *Bochs* | *"Red Hat"*) echo qemu ;;
		*) echo none ;;
	esac
}

# Effective GPU driver list ("auto" only installs drivers when they are useful)
gpu_list() {
	case $GPU in
		none) ;;
		auto) if desktop_on || multilib_on; then detect_gpus; fi ;;
		*) echo "$GPU" ;;
	esac
}

nvidia_driver() { # prints the proprietary NVIDIA choice (nvidia | nvidia-dkms), if any
	local g
	for g in $(gpu_list); do
		if [[ $g == nvidia* ]]; then echo "$g"; return 0; fi
	done
	return 0
}

get_uuid() {
	local u
	u=$(blkid -c /dev/null -s UUID -o value "$1" 2>/dev/null) || true
	if [[ -z $u ]]; then
		echo "Could not read the UUID of $1" >&2
		return 1
	fi
	printf '%s\n' "$u"
}

swapfile_path() {
	if [[ $FS == btrfs ]]; then echo /swap/swapfile; else echo /swapfile; fi
}

ram_gib() {
	awk '/^MemTotal:/ { printf "%d", ($2 + 1048575) / 1048576 }' /proc/meminfo
}

# Run a command inside the target system with a clean environment.
in_target() {
	chroot "$TARGET" /usr/bin/env -i HOME=/root TERM=dumb LANG=C \
		PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@"
}

# Run a command inside the target as <user> (makepkg, AUR helpers, dotfiles).
as_user() { # as_user <user> <command...>
	local u=$1
	shift
	chroot "$TARGET" /usr/bin/env -i HOME="/home/$u" USER="$u" LOGNAME="$u" TERM=dumb LANG=C.UTF-8 \
		PATH=/usr/local/sbin:/usr/local/bin:/usr/bin /usr/bin/setpriv --reuid="$u" --regid="$u" --init-groups -- "$@"
}

# =============================================================================
#  dialog wrappers
# =============================================================================
# ui: run dialog, print the answer on stdout, keep dialog's exit status.
ui() {
	# shellcheck disable=SC2069  # answer (stderr) -> caller, screen (stdout) -> terminal
	dialog --backtitle "$BACKTITLE" --colors --cancel-label "Back" "$@" 2>&1 >/dev/tty
}

msg() { # msg "text" [title] [height] [width]
	dialog --backtitle "$BACKTITLE" --colors --title " ${2:-Notice} " \
		--msgbox "$1" "${3:-10}" "${4:-70}" >/dev/tty 2>&1 || true
}

yesno() { # yesno "text" [title] [defaultno: 1] [height] [width]
	local -a opt=()
	if [[ ${3:-0} == 1 ]]; then opt=(--defaultno); fi
	dialog --backtitle "$BACKTITLE" --colors --title " ${2:-Confirm} " "${opt[@]}" \
		--yesno "$1" "${4:-10}" "${5:-70}" >/dev/tty 2>&1
}

# Ask for a secret twice; prints it on stdout.
ask_password() { # ask_password "title" "what"
	local p1 p2
	while true; do
		p1=$(ui --title " $1 " --insecure --passwordbox "Enter $2:" 9 64) || return 1
		if [[ -z $p1 ]]; then
			msg "The password must not be empty." "$1"
			continue
		fi
		p2=$(ui --title " $1 " --insecure --passwordbox "Repeat $2:" 9 64) || return 1
		if [[ $p1 == "$p2" ]]; then
			printf '%s' "$p1"
			return 0
		fi
		msg "The two entries did not match. Please try again." "$1"
	done
}

# Interactive shell; Ctrl-C inside it must not terminate the installer.
run_shell() { # run_shell <command...>
	trap ':' INT
	"$@" </dev/tty >/dev/tty 2>&1 || true
	trap 'exit 130' INT TERM
}

# =============================================================================
#  Environment checks
# =============================================================================
detect_firmware() {
	if [[ -d /sys/firmware/efi ]]; then
		FIRMWARE=uefi
		EFI_BITS=$(cat /sys/firmware/efi/fw_platform_size 2>/dev/null || echo 64)
		[[ $EFI_BITS == 32 ]] || EFI_BITS=64
	else
		FIRMWARE=bios
	fi
}

preflight() {
	[[ $EUID -eq 0 ]] || die "Run this installer as root."
	[[ $(uname -m) == x86_64 ]] || die "This installer supports x86_64 only."
	command -v basestrap >/dev/null 2>&1 ||
		die "basestrap not found. Boot an official Artix Linux ISO and run the installer from there."
	[[ -d /run/systemd/system ]] && die "This is a systemd system; boot an Artix Linux ISO (or use arch-install.sh for Arch)."
	[[ -t 0 && -t 1 ]] || die "Run the installer from an interactive terminal."
	: >"$LOG" || die "Cannot write $LOG"
	: >"$WARN_FILE"
	detect_firmware
	local r
	r=$(ram_gib)
	if [[ $r =~ ^[0-9]+$ ]] && ((r > 0)); then
		SWAP_SIZE=$((r < 2 ? 2 : (r > 8 ? 8 : r)))
	fi
}

net_ok() {
	timeout 30 pacman -Sy >/dev/null 2>&1
}

# Before dialog exists: plain text. Artix ISOs use ConnMan (or NetworkManager).
ensure_network_text() {
	local a
	while ! net_ok; do
		clear
		cat <<-'EOF'
			The Artix Linux package mirrors cannot be reached.
			The installer downloads everything, so it needs internet access.

			  Wired:  usually works by itself (ConnMan on the ISO).
			  Wi-Fi:  connmanctl  (then: enable wifi / scan wifi / agent on /
			          services / connect wifi_...), or nmtui on graphical ISOs
			  Phone:  USB tethering appears as a wired connection.

		EOF
		read -r -p "[r]etry, [s]hell to fix it ('exit' returns), [q]uit: " a </dev/tty || a=q
		case $a in
			s | S) run_shell bash -i ;;
			q | Q) exit 1 ;;
			*) ;;
		esac
	done
}

# The ISO's pacman keyring: initialise it if the live system has not.
ensure_keyring() {
	if [[ ! -s /etc/pacman.d/gnupg/trustdb.gpg ]]; then
		echo "Initialising the pacman keyring ..."
		pacman-key --init >/dev/null 2>&1 || true
		pacman-key --populate artix >/dev/null 2>&1 || true
	fi
	# A newer artix-keyring avoids "invalid signature" errors with an old ISO.
	pacman -Sy --needed --noconfirm artix-keyring >/dev/null 2>&1 || true
}

ensure_dialog() {
	command -v dialog >/dev/null 2>&1 && return 0
	echo "Installing 'dialog' into the live system ..."
	pacman -Sy --needed --noconfirm dialog || die "Could not install 'dialog'. Check the internet connection and try again."
}

# Wi-Fi from the menu with ConnMan (Artix ISOs): the passphrase goes into a
# ConnMan provisioning file in the live system's RAM (mode 600), never onto a
# command line, and nothing of it is copied to the new system.
wifi_connman() {
	local -a nets=()
	local ssid psk s f=/var/lib/connman/artix-install-wifi.config
	connmanctl enable wifi >/dev/null 2>&1 || true
	dialog --backtitle "$BACKTITLE" --title " Wi-Fi " --infobox "Scanning ..." 3 40 >/dev/tty 2>&1
	connmanctl scan wifi >/dev/null 2>&1 || true
	sleep 3
	while IFS= read -r s; do
		[[ -n $s ]] && nets+=("$s" "")
	done < <(connmanctl services 2>/dev/null | awk '$NF ~ /^wifi_/ { $NF = ""; sub(/^[*A-Za-z]{0,3} +/, ""); sub(/ +$/, ""); if ($0 != "") print }' | sort -u)
	nets+=("<other>" "enter the name manually")
	ssid=$(ui --title " Wi-Fi " --menu "Network:" 18 60 10 "${nets[@]}") || return 0
	if [[ $ssid == "<other>" ]]; then
		ssid=$(ui --title " Wi-Fi " --inputbox "Network name (SSID):" 9 60) || return 0
	fi
	[[ -n $ssid ]] || return 0
	psk=$(ui --title " Wi-Fi " --insecure --passwordbox "Passphrase for '$ssid' (leave empty for an open network):" 9 64) || return 0
	mkdir -p /var/lib/connman
	(
		umask 077
		printf '[service_artix_install]\nType = wifi\nName = %s\n' "$ssid"
		if [[ -n $psk ]]; then printf 'Passphrase = %s\n' "$psk"; fi
	) >"$f"
	dialog --backtitle "$BACKTITLE" --title " Wi-Fi " --infobox "Connecting to '$ssid' ..." 3 50 >/dev/tty 2>&1
	connmanctl scan wifi >/dev/null 2>&1 || true
	sleep 8
}

# Wi-Fi from the menu: ConnMan when the ISO runs it, else iwd. The passphrase
# goes into the daemon's own network file (mode 600), never onto a command line.
wifi_setup() {
	local -a ifs=() nets=()
	local d ifc ssid psk f s
	for d in /sys/class/net/*/wireless; do
		[[ -e $d ]] || continue
		d=${d%/wireless}
		ifs+=("${d##*/}" "wireless")
	done
	if ((${#ifs[@]} == 0)); then
		msg "No wireless interface was found." "Wi-Fi"
		return 0
	fi
	if command -v connmanctl >/dev/null 2>&1 && pgrep -x connmand >/dev/null 2>&1; then
		wifi_connman
		return 0
	fi
	if ! command -v iwctl >/dev/null 2>&1; then
		msg "Neither ConnMan nor iwd runs on this live system. Use the shell (nmtui, wpa_supplicant ...)." "Wi-Fi"
		return 0
	fi
	ifc=$(ui --title " Wi-Fi " --menu "Wireless interface:" 12 50 4 "${ifs[@]}") || return 0
	dialog --backtitle "$BACKTITLE" --title " Wi-Fi " --infobox "Scanning on $ifc ..." 3 40 >/dev/tty 2>&1
	iwctl station "$ifc" scan >/dev/null 2>&1 || true
	sleep 4
	while IFS= read -r s; do
		[[ -n $s ]] && nets+=("$s" "")
	done < <(iwctl station "$ifc" get-networks 2>/dev/null | sed -e 's/\x1b\[[0-9;]*m//g' |
		awk 'NR > 4 && NF >= 3 { $1 = ($1 == ">") ? "" : $1; sub(/^ +/, ""); n = NF; $n = ""; $(n - 1) = ""; sub(/ +$/, ""); print }' | sort -u)
	nets+=("<other>" "enter the name manually")
	ssid=$(ui --title " Wi-Fi " --menu "Network:" 18 60 10 "${nets[@]}") || return 0
	if [[ $ssid == "<other>" ]]; then
		ssid=$(ui --title " Wi-Fi " --inputbox "Network name (SSID):" 9 60) || return 0
	fi
	[[ -n $ssid ]] || return 0
	psk=$(ui --title " Wi-Fi " --insecure --passwordbox "Passphrase for '$ssid' (leave empty for an open network):" 9 64) || return 0
	# iwd names files after the SSID; others are "=" + hex.
	if [[ $ssid =~ ^[A-Za-z0-9_\ -]+$ ]]; then f=$ssid; else f="=$(printf '%s' "$ssid" | od -An -tx1 | tr -d ' \n')"; fi
	mkdir -p /var/lib/iwd
	if [[ -n $psk ]]; then
		(umask 077 && printf '[Security]\nPassphrase=%s\n' "$psk" >"/var/lib/iwd/$f.psk")
	else
		: >"/var/lib/iwd/$f.open"
	fi
	dialog --backtitle "$BACKTITLE" --title " Wi-Fi " --infobox "Connecting to '$ssid' ..." 3 50 >/dev/tty 2>&1
	iwctl station "$ifc" connect "$ssid" >/dev/null 2>&1 </dev/null || true
	sleep 8
}

ensure_network() {
	dialog --backtitle "$BACKTITLE" --title " Network " --infobox "Checking the connection to the Artix mirrors ..." 3 60 >/dev/tty 2>&1
	while ! net_ok; do
		local c
		c=$(ui --title " No network " --cancel-label "Quit" --menu \
			"The Artix Linux package mirrors cannot be reached.\nThe installer downloads everything, so it needs internet access." 15 72 4 \
			retry "Try again" \
			wifi "Connect to a Wi-Fi network" \
			shell "Open a shell to fix it manually ('exit' returns here)" \
			quit "Quit the installer") || c=quit
		case $c in
			retry) ;;
			wifi) wifi_setup ;;
			shell)
				clear
				echo "Set up the network (connmanctl, nmtui, ip, ...), then type 'exit'."
				run_shell bash -i
				;;
			*) clear; exit 1 ;;
		esac
		dialog --backtitle "$BACKTITLE" --title " Network " --infobox "Checking the connection ..." 3 50 >/dev/tty 2>&1
	done
}

# =============================================================================
#  Partition layout
# =============================================================================
compute_layout() {
	local n=1
	ESP_PART="" ESP_NUM="" ESP_MOUNT="" ESP_SIZE=0
	BIOSBOOT_PART="" BIOSBOOT_NUM=""
	BOOT_PART="" BOOT_NUM="" BOOT_FS=""
	ALL_PARTS=()

	if [[ $FIRMWARE == uefi ]]; then
		ESP_NUM=$n
		ESP_PART=$(part_name "$DISK" "$n")
		n=$((n + 1))
		if boot_is_separate; then
			ESP_MOUNT=/boot
			ESP_SIZE=$BOOT_SIZE_MIB
		elif [[ $BOOTLOADER == zfsbootmenu ]]; then
			ESP_MOUNT=/boot/efi      # kernels stay in /boot (in the pool); ZFSBootMenu's images go here
			ESP_SIZE=$BOOT_SIZE_MIB
		else
			ESP_MOUNT=/boot/efi
			ESP_SIZE=$ESP_SIZE_MIB
		fi
		ALL_PARTS+=("$ESP_PART")
	else
		# SYSLINUX boots from a flagged /boot partition and needs no BIOS boot partition.
		if ! bios_only; then
			BIOSBOOT_NUM=$n
			BIOSBOOT_PART=$(part_name "$DISK" "$n")
			n=$((n + 1))
			ALL_PARTS+=("$BIOSBOOT_PART")
		fi
		if boot_is_separate; then
			BOOT_NUM=$n
			BOOT_PART=$(part_name "$DISK" "$n")
			n=$((n + 1))
			case $BOOTLOADER in
				limine) BOOT_FS=vfat ;;
				syslinux) BOOT_FS=ext2 ;;   # extlinux cannot read ext4 with the 64bit feature
				*) BOOT_FS=ext4 ;;
			esac
			ALL_PARTS+=("$BOOT_PART")
		fi
	fi
	ROOT_NUM=$n
	ROOT_PART=$(part_name "$DISK" "$n")
	ALL_PARTS+=("$ROOT_PART")
}

sfdisk_script() {
	local root_type=$GUID_LINUX
	if encrypted; then root_type=$GUID_LUKS; fi
	echo "label: gpt"
	if [[ -n $ESP_PART ]]; then
		echo "size=${ESP_SIZE}MiB, type=$GUID_ESP, name=\"EFI system partition\""
	fi
	if [[ -n $BIOSBOOT_PART ]]; then
		echo "size=${BIOSBOOT_SIZE_MIB}MiB, type=$GUID_BIOS, name=\"BIOS boot\""
	fi
	if [[ -n $BOOT_PART ]]; then
		if bios_only; then
			# gptmbr.bin boots the partition carrying this attribute.
			echo "size=${BOOT_SIZE_MIB}MiB, type=$GUID_LINUX, name=\"boot\", attrs=\"LegacyBIOSBootable\""
		else
			echo "size=${BOOT_SIZE_MIB}MiB, type=$GUID_LINUX, name=\"boot\""
		fi
	fi
	echo "type=$root_type, name=\"arch\""
}

required_mib() {
	local mib=$((MIN_ROOT_GIB * 1024 + 8 + ESP_SIZE))
	if [[ -n $BIOSBOOT_PART ]]; then mib=$((mib + BIOSBOOT_SIZE_MIB)); fi
	if [[ -n $BOOT_PART ]]; then mib=$((mib + BOOT_SIZE_MIB)); fi
	if [[ $SWAP == file ]] && ! zfs_on; then mib=$((mib + SWAP_SIZE * 1024)); fi
	echo "$mib"
}

enc_desc() {
	case $ENC in
		luks1) echo "LUKS1 (PBKDF2)" ;;
		luks2) if grub_unlocks; then echo "LUKS2 (PBKDF2)"; else echo "LUKS2 (Argon2id)"; fi ;;
		*) echo "none" ;;
	esac
}

layout_row() { printf '  %-18s %-9s %s\n' "$1" "$2" "$3"; }

layout_lines() {
	local rootdesc
	if [[ -n $ESP_PART ]]; then
		layout_row "$ESP_PART" "${ESP_SIZE} MiB" "FAT32 -> $ESP_MOUNT (EFI system partition)"
	fi
	if [[ -n $BIOSBOOT_PART ]]; then
		layout_row "$BIOSBOOT_PART" "${BIOSBOOT_SIZE_MIB} MiB" "BIOS boot (no filesystem)"
	fi
	if [[ -n $BOOT_PART ]]; then
		case $BOOT_FS in
			vfat) layout_row "$BOOT_PART" "${BOOT_SIZE_MIB} MiB" "FAT32 -> /boot" ;;
			ext2) layout_row "$BOOT_PART" "${BOOT_SIZE_MIB} MiB" "ext2 -> /boot (legacy BIOS bootable)" ;;
			*) layout_row "$BOOT_PART" "${BOOT_SIZE_MIB} MiB" "ext4 -> /boot" ;;
		esac
	fi
	if zfs_on; then
		if encrypted; then rootdesc="$(enc_desc) -> ZFS pool $ZPOOL -> /"; else rootdesc="ZFS pool $ZPOOL -> /"; fi
	elif encrypted; then rootdesc="$(enc_desc) -> $FS -> /"; else rootdesc="$FS -> /"; fi
	layout_row "$ROOT_PART" "rest" "$rootdesc"
}

# =============================================================================
#  Menu labels
# =============================================================================
lbl_disk() {
	if [[ -n $DISK ]]; then
		printf '%s  %s' "$DISK" "$(lsblk -dno SIZE "$DISK" 2>/dev/null | tr -d ' ')"
	else
		printf '\\Z1(not set)\\Zn'
	fi
}
lbl_enc() {
	case $ENC in
		none) printf 'none' ;;
		*) printf '%s' "${ENC^^}"; [[ -n $LUKS_PASS ]] || printf ' \\Z1(passphrase not set)\\Zn' ;;
	esac
}
lbl_boot() {
	case $BOOTLOADER in
		limine) printf 'Limine' ;;
		refind) printf 'rEFInd' ;;
		efistub) printf 'EFISTUB (no boot menu)' ;;
		syslinux) printf 'SYSLINUX (EXTLINUX)' ;;
		zfsbootmenu) printf 'ZFSBootMenu' ;;
		*)
			if ! encrypted; then
				printf 'GRUB'
			elif [[ $GRUB_BOOT == encrypted ]]; then
				printf 'GRUB (/boot encrypted)'
			else
				printf 'GRUB (unencrypted /boot)'
			fi
			;;
	esac
}
lbl_sb() {
	if [[ $SECUREBOOT != 1 ]]; then printf 'off'
	elif secureboot_on; then printf 'on (sbctl, your own keys)'
	else printf '\\Z1on, but not possible with this firmware or boot loader\\Zn'; fi
}
lbl_snapper() {
	if [[ $SNAPPER != 1 ]]; then printf 'off'
	elif zfs_on; then printf 'ZFS snapshots before pacman, bootable from ZFSBootMenu'
	elif [[ $FS != btrfs ]]; then printf '\\Z1on, but needs btrfs or ZFS\\Zn'
	elif [[ $BOOTLOADER == grub ]]; then printf 'snapper, bootable from GRUB'
	else printf 'snapper (not in the boot menu)'; fi
}
lbl_swap() {
	case $SWAP in
		file) printf 'swap file, %s GiB' "$SWAP_SIZE" ;;
		zram) printf 'zram (zramen)' ;;
		*) printf 'none' ;;
	esac
}
lbl_init() {
	case $INIT in
		openrc) printf 'OpenRC' ;;
		runit) printf 'runit' ;;
		s6) printf 's6 (s6-rc)' ;;
		dinit) printf 'dinit' ;;
	esac
}
lbl_arch_repos() { if arch_repos_on; then printf 'on: [extra]%s' "$(multilib_on && printf ' [multilib]')"; else printf 'off (Artix repositories only)'; fi; }
lbl_set()    { if [[ -n $1 ]]; then printf 'set'; else printf '\\Z1(not set)\\Zn'; fi; }
sudo_word() { case ${U_SUDO[$1]:-} in sudo) printf 'sudo' ;; nopasswd) printf 'sudo, no password' ;; *) printf 'no sudo' ;; esac; }
lbl_user() {
	local u out=""
	if ((${#USERS[@]} == 0)); then printf '\\Z1(not set)\\Zn'; return 0; fi
	for u in "${USERS[@]}"; do out+="${out:+, }$u ($(sudo_word "$u"))"; done
	printf '%s' "$out"
}
lbl_bootstrap() {
	local out=""
	[[ -n $BS_PROGS ]] && out+="programs list"
	[[ -n $BS_DOTFILES ]] && out+="${out:+, }dotfiles"
	[[ $BS_SHELL != bash ]] && out+="${out:+, }$BS_SHELL"
	[[ $BS_POWER == 1 ]] && out+="${out:+, }power cmds"
	printf '%s' "${out:-(none)}"
}
lbl_locale() { printf '%s' "$LOCALE"; }
lbl_mirror() { if [[ $MIRROR == auto ]]; then printf "the ISO's mirror list"; else printf 'fastest first (rankmirrors)'; fi; }
lbl_net() {
	case $NET in
		nm) printf 'NetworkManager' ;;
		connman) printf 'ConnMan' ;;
		dhcpcd) printf 'dhcpcd + iwd' ;;
		*) printf 'none' ;;
	esac
}
lbl_gpu() {
	local l
	case $GPU in
		none) printf 'none' ;;
		auto)
			l=$(detect_gpus)
			if ! desktop_on && ! multilib_on; then printf 'auto (only with a desktop)'; else printf 'auto (%s)' "${l:-nothing detected}"; fi
			;;
		*) printf '%s' "$GPU" ;;
	esac
}
lbl_list() { if [[ -n $1 ]]; then printf '%s' "$1"; else printf '(none)'; fi; }
lbl_aur() {
	if ! aur_on; then printf 'no AUR helper'
	elif [[ -n $AUR_PKGS ]]; then printf '%s; %s' "$AUR_HELPER" "$AUR_PKGS"
	else printf '%s' "$AUR_HELPER"; fi
}

# =============================================================================
#  Menus (each returns 1 when the user goes back without a change)
# =============================================================================
live_media_disk() {
	local src pk
	local m
	for m in /run/artix/bootmnt /run/archiso/bootmnt /run/*/bootmnt; do
		src=$(findmnt -no SOURCE "$m" 2>/dev/null) || src=""
		[[ -n $src ]] && break
	done
	[[ -b $src ]] || return 0
	pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 | tr -d ' ')
	if [[ -n $pk ]]; then echo "/dev/$pk"; else echo "$src"; fi
}

menu_disk() {
	local live d size model tran desc
	local -a items=()
	live=$(live_media_disk)
	while read -r d; do
		[[ $d =~ ^/dev/(loop|ram|zram|sr|fd) ]] && continue
		[[ $(lsblk -dno TYPE "$d" 2>/dev/null | tr -d ' ') == disk ]] || continue
		[[ $(lsblk -dno RO "$d" 2>/dev/null | tr -d ' ') == 0 ]] || continue
		size=$(lsblk -dno SIZE "$d" | tr -d ' ')
		model=$(trim "$(lsblk -dno MODEL "$d" 2>/dev/null)")
		tran=$(trim "$(lsblk -dno TRAN "$d" 2>/dev/null)")
		desc="$size  ${model:-unknown model}${tran:+  [$tran]}"
		[[ $d == "$live" ]] && desc+="  (live media)"
		items+=("$d" "$desc")
	done < <(lsblk -dnpo NAME)

	if ((${#items[@]} == 0)); then
		msg "No suitable disk was found." "Disk"
		return 1
	fi

	local sel
	sel=$(ui --title " Target disk " --default-item "${DISK:-${items[0]}}" --menu \
		"Select the disk to install Artix Linux on.\n\Z1\ZbThe whole disk will be erased.\Zn" 0 0 0 "${items[@]}") || return 1

	if [[ -n $live && $sel == "$live" ]]; then
		msg "$sel holds the live system you booted from. Choose another disk." "Disk"
		return 1
	fi
	local bytes
	bytes=$(blockdev --getsize64 "$sel" 2>/dev/null || echo 0)
	if ((bytes < (MIN_ROOT_GIB + 2) * 1024 * 1024 * 1024)); then
		msg "$sel is too small. At least $((MIN_ROOT_GIB + 2)) GiB are needed." "Disk"
		return 1
	fi

	local current
	current=$(lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$sel" 2>/dev/null | head -n 12)
	if dialog --backtitle "$BACKTITLE" --colors --cr-wrap --no-collapse --title " Confirm disk " --defaultno \
		--yesno "Current content of $sel:\n\n$current\n\n\Z1\ZbEverything on $sel will be erased when the installation starts.\Zn\nUse this disk?" \
		0 78 >/dev/tty 2>&1; then
		DISK=$sel
		return 0
	fi
	return 1
}

menu_fs() {
	local c
	local -a items=(ext4 "Classic journaling filesystem"
		btrfs "Subvolumes (@, @home, ...), zstd compression, snapshots")
	if [[ $FIRMWARE == uefi && $EFI_BITS == 64 ]]; then
		items+=(zfs "ZFS pool (archzfs), booted by ZFSBootMenu; can sit on LUKS2")
	fi
	c=$(ui --title " Filesystem " --default-item "$FS" --menu "Root filesystem:" 12 78 3 "${items[@]}") || return 1
	if [[ $c == zfs ]]; then
		menu_zfs_info || return 1
	elif zfs_on && [[ $BOOTLOADER == zfsbootmenu ]]; then
		BOOTLOADER=grub
		msg "ZFSBootMenu only boots ZFS, so the boot loader is now GRUB. Change it in the Bootloader item." "Boot loader"
	fi
	FS=$c
	if [[ $FS == btrfs && $SNAPPER != 1 ]] &&
		yesno "Take automatic btrfs snapshots with snapper (before and after every pacman transaction, plus hourly)?\n\nYou can change this later in the Snapshots item." "Snapshots"; then
		SNAPPER=1
	fi
	return 0
}

# ZFS: what changes, and the choices that go with it.
menu_zfs_info() {
	yesno "ZFS is not in Artix's repositories (its license). The installer uses the signed \Zbarchzfs\Zn repository; its modules are built for Arch's kernels, so on Artix the module is compiled for your kernels (zfs-dkms), on the live ISO too.\n\n- Boot loader: \ZbZFSBootMenu\Zn, built on the new system. It can boot any snapshot.\n- With encryption the pool sits on \ZbLUKS2\Zn: ZFSBootMenu asks for the passphrase once.\n- The live ISO's kernel must match Artix's current linux-headers: use a recent ISO.\n- A kernel update rebuilds the module; the LTS kernel changes least.\n- No swap file (zram instead) and no Secure Boot with ZFS.\n- Installing takes several minutes longer (two module builds).\n\nUse ZFS?" "ZFS" 0 21 76 || return 1
	BOOTLOADER=zfsbootmenu
	if [[ $SWAP == file ]]; then SWAP=zram; fi
	SECUREBOOT=0
	if [[ $KERNELS != linux-lts ]] && yesno "Use only the LTS kernel (linux-lts)?\n\nThe module is rebuilt for every kernel update; the LTS kernel changes least, and one kernel means one build. Now: $KERNELS" "ZFS kernel" 0 11 70; then
		KERNELS=linux-lts
	fi
	if [[ $SNAPPER != 1 ]] && yesno "Take a ZFS snapshot of the system before every pacman transaction (the last 10 are kept)? ZFSBootMenu can boot any of them." "Snapshots"; then
		SNAPPER=1
	fi
	return 0
}

menu_grub_boot() {
	local c
	c=$(ui --title " GRUB and encryption " --default-item "$GRUB_BOOT" --menu \
		"Where should the kernel and initramfs live?\n\n\Zbencrypted\Zn: everything except the ESP is encrypted. GRUB asks for the passphrase (US keyboard layout, unlocking takes ~10-30 s); LUKS2 is created with PBKDF2.\n\n\Zbseparate\Zn: a 1 GiB unencrypted /boot holds kernel + initramfs; the initramfs asks for the passphrase and LUKS2 keeps Argon2id." \
		19 78 2 \
		encrypted "/boot inside the encrypted root (GRUB unlocks it)" \
		separate "Unencrypted /boot partition") || return 1
	GRUB_BOOT=$c
}

menu_enc() {
	local c
	c=$(ui --title " Encryption " --default-item "$ENC" --menu "Encrypt the root partition?" 12 78 3 \
		none "No encryption" \
		luks1 "LUKS1 - PBKDF2, widest GRUB compatibility" \
		luks2 "LUKS2 - Argon2id (PBKDF2 when GRUB must unlock it)") || return 1
	ENC=$c
	if encrypted; then
		if [[ -z $LUKS_PASS ]] || ! yesno "An encryption passphrase is already set.\n\nKeep it?" "Passphrase"; then
			ask_luks_pass || true
		fi
		if [[ $BOOTLOADER == grub ]]; then menu_grub_boot || true; fi
	fi
	return 0
}

ask_luks_pass() {
	local p
	p=$(ask_password "Encryption passphrase" "the disk encryption passphrase") || return 1
	if ((${#p} < 8)) && ! yesno "This passphrase is shorter than 8 characters.\n\nUse it anyway?" "Weak passphrase" 1; then
		return 1
	fi
	LUKS_PASS=$p
}

menu_bootloader() {
	local c note
	if zfs_on; then
		msg "With ZFS the boot loader is ZFSBootMenu. To use another boot loader, choose ext4 or btrfs in the Filesystem item." "Boot loader" 9 70
		return 1
	fi
	local -a items=(
		grub "GRUB 2 - can unlock an encrypted /boot"
		limine "Limine - fast and simple; kernels on a FAT32 /boot")
	if [[ $FIRMWARE == uefi && $EFI_BITS == 64 ]]; then
		items+=(
			refind "rEFInd - graphical UEFI boot manager"
			efistub "EFISTUB - the firmware starts the kernel; no menu")
		note="\n\nsystemd-boot and unified kernel images need systemd's EFI stub, which Artix does not ship."
	elif [[ $FIRMWARE == uefi ]]; then
		note="\n\nrEFInd and EFISTUB need 64-bit UEFI and are hidden."
	else
		items+=(syslinux "SYSLINUX / EXTLINUX - small BIOS boot loader")
		note="\n\nrEFInd and EFISTUB need UEFI and are hidden."
	fi
	local n=$((${#items[@]} / 2)) h
	h=$((n + 8))
	if [[ -n $note ]]; then h=$((h + 2)); fi
	c=$(ui --title " Boot loader " --default-item "$BOOTLOADER" --menu \
		"Boot loader (firmware: ${FIRMWARE^^}$([[ $FIRMWARE == uefi ]] && echo ", ${EFI_BITS}-bit"))${note}" \
		"$h" 78 "$n" "${items[@]}") || return 1
	BOOTLOADER=$c
	case $BOOTLOADER in
		grub)
			if encrypted; then menu_grub_boot || true; fi
			;;
		limine)
			if encrypted; then
				msg "Limine only reads FAT filesystems, so the kernel and initramfs are placed on an unencrypted 1 GiB FAT32 /boot partition. The root filesystem stays encrypted and the initramfs asks for the passphrase." "Limine and LUKS" 10 72
			fi
			;;
		refind)
			msg "The EFI system partition (1 GiB, FAT32) is mounted at /boot and holds the kernels and initramfs images. $(lbl_boot) lists them in your kernel order; a pacman hook rewrites the list whenever a kernel is installed or removed.$(encrypted && printf '%s' '\n\nThe root filesystem stays encrypted; the initramfs asks for the passphrase.')" "$(lbl_boot)" 12 72
			;;
		efistub)
			msg "The firmware starts the kernel directly from the ESP (mounted at /boot); one UEFI boot entry per kernel, in your kernel order. There is no boot menu: pick another kernel in the firmware's boot menu (often F8, F11 or F12).\n\nThis needs firmware that keeps the boot entries the installer writes into NVRAM. Some boards ignore or forget them; choose rEFInd or GRUB for those." "EFISTUB" 13 74
			;;
		syslinux)
			msg "EXTLINUX is installed on a 1 GiB ext2 /boot partition marked 'legacy BIOS bootable', with SYSLINUX's GPT boot code in the first sector. No BIOS boot partition is needed.$(encrypted && printf '%s' '\n\n/boot is unencrypted; the root filesystem stays encrypted and the initramfs asks for the passphrase.')" "SYSLINUX" 10 72
			;;
	esac
	if [[ $SECUREBOOT == 1 ]] && ! secureboot_on; then
		msg "Secure Boot is not possible with $(lbl_boot) on this computer, so it will be left off. It works with GRUB, rEFInd and EFISTUB on 64-bit UEFI." "Secure Boot" 10 72
	fi
	return 0
}

menu_secureboot() {
	if zfs_on; then
		msg "Secure Boot is not offered with ZFS: ZFSBootMenu starts the kernel itself (kexec), which the firmware does not check." "Secure Boot" 9 70
		return 1
	fi
	if [[ $FIRMWARE != uefi || $EFI_BITS != 64 ]]; then
		msg "Secure Boot needs 64-bit UEFI firmware. This computer started with ${FIRMWARE^^}${EFI_BITS:+ ($EFI_BITS-bit)}." "Secure Boot"
		return 1
	fi
	if ! sb_capable; then
		msg "Secure Boot is offered for GRUB, rEFInd and EFISTUB. Limine and SYSLINUX are not signed by this installer.\n\nChoose one of those boot loaders first." "Secure Boot" 10 72
		return 1
	fi
	if yesno "Sign the boot loader and kernels with your own keys (sbctl)?\n\n- Before installing, put the firmware's Secure Boot in \ZbSetup Mode\Zn (delete or reset the keys in the firmware settings). Then the installer enrolls your keys, plus Microsoft's so graphics cards and other option ROMs still start.\n- If it is not in Setup Mode, the keys are still made and everything is signed; enroll them later with: sudo sbctl enroll-keys -m\n- Afterwards, turn Secure Boot on in the firmware. pacman re-signs kernels and boot loaders on every update.$([[ $BOOTLOADER == grub ]] && printf '%s' '\n\nWith GRUB, the modules it needs are built into the signed GRUB image.')" "Secure Boot" 0 19 76; then
		SECUREBOOT=1
	else
		SECUREBOOT=0
	fi
	return 0
}

menu_snapper() {
	if zfs_on; then
		if yesno "Take a ZFS snapshot of the system ($ZFS_BE) before every pacman transaction? The last 10 are kept, and ZFSBootMenu can boot any of them (Ctrl-S in its menu). /home is a separate dataset and is not rolled back." "Snapshots" 0 12 74; then SNAPPER=1; else SNAPPER=0; fi
		return 0
	fi
	if [[ $FS != btrfs ]]; then
		msg "Snapshots need btrfs or ZFS. Choose one of them in the Filesystem item first." "Snapshots"
		return 1
	fi
	local where
	case $BOOTLOADER in
		grub) where="GRUB lists the snapshots in a submenu (grub-btrfs), so you can boot an older state and roll back." ;;
		*) where="$(lbl_boot) cannot list snapshots; restore one from a running system with snapper, or from the live ISO." ;;
	esac
	if yesno "Take automatic btrfs snapshots of / with snapper?\n\n- one before and one after every pacman transaction (snap-pac)\n- hourly snapshots, the last few kept (timeline, run by cron)\n- /home is a separate subvolume and is not rolled back\n\n$where" "Snapshots" 0 16 76; then
		SNAPPER=1
	else
		SNAPPER=0
	fi
	return 0
}

menu_swap() {
	local c s
	if zfs_on; then
		c=$(ui --title " Swap " --default-item "$SWAP" --menu "Swap space (a swap file is not offered on ZFS):" 11 70 2 \
			none "No swap" zram "Compressed swap in RAM (zramen)") || return 1
		SWAP=$c
		return 0
	fi
	c=$(ui --title " Swap " --default-item "$SWAP" --menu "Swap space:" 12 70 3 \
		none "No swap" \
		zram "Compressed swap in RAM (zramen)" \
		file "Swap file on the root filesystem") || return 1
	if [[ $c == file ]]; then
		s=$(ui --title " Swap file " --inputbox "Swap file size in GiB (1-128):" 9 50 "$SWAP_SIZE") || return 1
		if ! [[ $s =~ ^[0-9]+$ ]] || ((s < 1 || s > 128)); then
			msg "Please enter a whole number between 1 and 128." "Swap file"
			return 1
		fi
		SWAP_SIZE=$s
	fi
	SWAP=$c
}

# ---- kernels: any of Artix's kernels, in the boot order you choose ------------
# KERNELS is the boot order: the first one boots by default, the others follow
# in the boot menu.
declare -A KVER=()

kernel_ver() { # package -> its version in the repository ("6.17.8.arch1"), or ""
	local v
	if [[ -z ${KVER[$1]+x} ]]; then
		v=$(pacman -Si "$1" 2>/dev/null | awk -F': ' '/^Version/ { print $2; exit }') || true
		KVER[$1]=${v%-*}
	fi
	printf '%s' "${KVER[$1]}"
}

kernel_label() { # package -> one line for the menus
	local v
	v=$(kernel_ver "$1")
	case $1 in
		linux) printf "the default kernel (now %s)" "${v:-latest}" ;;
		linux-lts) printf 'Long-term support (now %s)' "${v:-LTS}" ;;
		linux-zen) printf 'Zen: tuned for desktop responsiveness (now %s)' "${v:-latest}" ;;
		linux-hardened) printf 'Hardened: security patches, some features off (now %s)' "${v:-latest}" ;;
		*) printf '%s' "$1" ;;
	esac
}

lbl_kernels() {
	local k out=""
	for k in $KERNELS; do out+="${out:+ > }$k"; done
	printf '%s' "${out:-\\Z1(none)\\Zn}"
}

# Header packages for every kernel (DKMS builds modules for each)
kernel_headers() {
	local k
	for k in $KERNELS; do echo "${k}-headers"; done
}

kernel_pick() { # tick the kernels to install; new ones join at the end
	local sel k out=""
	local -a items=()
	for k in $ALL_KERNELS; do items+=("$k" "$(kernel_label "$k")"); done
	sel=$(checklist "Kernels" "Tick every kernel to install. Newly ticked ones are added at the end of the boot order; reorder them on the next screen." "$KERNELS" "${items[@]}") || return 1
	for k in $KERNELS; do
		if has "$sel" "$k"; then out+=" $k"; fi
	done
	for k in $sel; do
		if ! has "$out" "$k"; then out+=" $k"; fi
	done
	KERNELS=$(trim "$out")
}

kernel_move() { # kernel_move <package>: boot first / up / down / remove
	local k=$1 c i pos=0 n t
	local -a ks
	read -ra ks <<<"$KERNELS"
	n=${#ks[@]}
	for i in "${!ks[@]}"; do
		if [[ ${ks[i]} == "$k" ]]; then pos=$i; fi
	done
	c=$(ui --title " $k " --menu "$(kernel_label "$k")\n\nNow number $((pos + 1)) of $n in the boot order." 14 72 4 \
		first "Boot first (makes it the default)" \
		up "Move up" \
		down "Move down" \
		remove "Remove") || return 1
	case $c in
		first) KERNELS="$k $(without "$KERNELS" "$k")" ;;
		up)
			if ((pos > 0)); then
				t=${ks[pos - 1]} ks[pos - 1]=${ks[pos]} ks[pos]=$t
				KERNELS="${ks[*]}"
			fi
			;;
		down)
			if ((pos < n - 1)); then
				t=${ks[pos + 1]} ks[pos + 1]=${ks[pos]} ks[pos]=$t
				KERNELS="${ks[*]}"
			fi
			;;
		remove) KERNELS=$(without "$KERNELS" "$k") ;;
	esac
	KERNELS=$(trim "$KERNELS")
}

menu_kernel() {
	local orig=$KERNELS c="" k i n
	local -a items
	while :; do
		items=()
		i=0
		for k in $KERNELS; do
			i=$((i + 1))
			items+=("$k" "$i. $(kernel_label "$k")")
		done
		items+=(add "+ Add or remove kernels ..." "done" "= Done")
		n=$((${#items[@]} / 2))
		c=$(ui --title " Kernels and boot order " --default-item "${c:-done}" \
			--ok-label Select --cancel-label Back --menu \
			"Kernels to install, in boot order: number 1 boots by default, the others are the next entries in the boot menu (fallbacks). Select a kernel to move or remove it." \
			$((n + 9)) 78 "$n" "${items[@]}") || {
			KERNELS=$orig
			return 1
		}
		case $c in
			done)
				if [[ -z $KERNELS ]]; then
					msg "Pick at least one kernel." "Kernels"
					continue
				fi
				if [[ $KERNELS != *" "* ]] &&
					! yesno "Only one kernel: if it fails to boot after an update there is no other kernel to choose in the boot menu.\n\nContinue with one kernel?" "One kernel" 1; then
					continue
				fi
				return 0
				;;
			add) kernel_pick || true ;;
			*) kernel_move "$c" || true ;;
		esac
	done
}

# ---- mirrors: Artix's list, optionally ranked by speed --------------------------
# rankmirrors (pacman-contrib) times every HTTPS server of the list and keeps
# the 10 fastest; the result is copied to the new system by basestrap.
rank_mirrors() {
	local f=/etc/pacman.d/mirrorlist tmp
	command -v rankmirrors >/dev/null 2>&1 || pacman -S --needed --noconfirm pacman-contrib >/dev/null 2>&1 || return 1
	[[ -s $f.artix-install ]] || cp "$f" "$f.artix-install" || return 1
	tmp=$(mktemp) || return 1
	sed -n 's/^#\?[[:space:]]*\(Server[[:space:]]*=[[:space:]]*https:.*\)/\1/p' "$f.artix-install" | awk '!seen[$0]++' >"$tmp"
	if [[ ! -s $tmp ]] || ! timeout 180 rankmirrors -n 10 "$tmp" >"$tmp.ranked" 2>/dev/null || ! grep -q '^Server' "$tmp.ranked"; then
		rm -f "$tmp" "$tmp.ranked"
		return 1
	fi
	{ echo "# Ranked by artix-install.sh (rankmirrors)"; cat "$tmp.ranked"; } >"$f"
	rm -f "$tmp" "$tmp.ranked"
}

apply_mirror() {
	if [[ $MIRROR == auto ]]; then
		if [[ -s /etc/pacman.d/mirrorlist.artix-install ]]; then cp /etc/pacman.d/mirrorlist.artix-install /etc/pacman.d/mirrorlist; fi
	else
		dialog --backtitle "$BACKTITLE" --title " Mirrors " --infobox "Timing the mirrors (up to 3 minutes) ..." 3 60 >/dev/tty 2>&1
		if ! rank_mirrors; then
			msg "The mirrors could not be ranked. The ISO's mirror list is kept." "Mirrors"
			MIRROR=auto
			return 1
		fi
	fi
	pacman -Sy >/dev/null 2>&1 || true
}

menu_mirror() {
	local c
	c=$(ui --title " Mirrors " --default-item "$MIRROR" --menu "Package mirrors (the list is copied to the new system):" 11 74 2 \
		auto "Artix's mirror list as it is on the ISO" \
		rank "Fastest first: time every mirror (rankmirrors)") || return 1
	MIRROR=$c
	apply_mirror || true
	return 0
}

menu_init() {
	local c
	c=$(ui --title " Init system " --default-item "$INIT" --menu "Init system of the new system. Every service the installer sets up is enabled the way this init expects; daemons come with their \"<package>-<init>\" start scripts." 15 78 4 \
		openrc "OpenRC - dependency-based, the most widely used on Artix" \
		runit "runit - small and fast, supervised services" \
		s6 "s6 / s6-rc - supervision with a compiled service database" \
		dinit "dinit - dependency-based, supervised, quick to boot") || return 1
	INIT=$c
	if [[ $(desktop_dm) == ly ]] && ! official_has "ly-$INIT"; then
		msg "Artix has no Ly start script for $(lbl_init) (ly-$INIT). Choose another login screen in the Login item." "Ly" 9 70
	fi
	return 0
}

menu_arch_repos() {
	if yesno "Also use Arch Linux's repositories ([extra], and [multilib] for 32-bit gaming)?\n\nArtix's own repositories come first, so its systemd-free builds are always preferred. Arch's add packages Artix does not carry (some games, tools and desktop parts). They are built for systemd systems: a package that needs systemd itself cannot be installed this way.\n\nThis installs artix-archlinux-support (Arch's keyring and mirror list) on the live system and the new one." "Arch repositories" 1 16 76; then
		ARCH_REPOS=1
		dialog --backtitle "$BACKTITLE" --title " Arch repositories " --infobox "Adding Arch's repositories to the live system ..." 3 60 >/dev/tty 2>&1
		if ! arch_repos_setup live >>"$LOG" 2>&1; then
			msg "Arch's repositories could not be added (details in $LOG). They stay off." "Arch repositories"
			ARCH_REPOS=0
			arch_repos_live_off
		fi
	else
		ARCH_REPOS=0
		arch_repos_live_off
	fi
	official_refresh
	return 0
}

# Back to the live system's own pacman.conf (Artix repositories only).
arch_repos_live_off() {
	if [[ -s /etc/pacman.conf.artix-install ]]; then
		cp /etc/pacman.conf.artix-install /etc/pacman.conf
		pacman -Sy >/dev/null 2>&1 || true
	fi
}

menu_hostname() {
	local c
	c=$(ui --title " Hostname " --inputbox "Hostname of the new system:" 9 60 "$HOST_NAME") || return 1
	if ! [[ $c =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
		msg "Use letters, digits and '-' only (1-63 characters, no leading/trailing '-')." "Hostname"
		return 1
	fi
	HOST_NAME=$c
}

menu_keymap() {
	local -a maps=()
	local c
	mapfile -t maps < <(localectl list-keymaps 2>/dev/null ||
		find /usr/share/kbd/keymaps -type f -name '*.map.gz' -printf '%f\n' 2>/dev/null | sed 's/\.map\.gz$//' | sort -u)
	if ((${#maps[@]})); then
		c=$(ui --title " Keyboard " --default-item "$KEYMAP" --no-items --menu "Console keymap:" 0 0 0 "${maps[@]}") || return 1
	else
		c=$(ui --title " Keyboard " --inputbox "Console keymap (e.g. us, de-latin1, fr, uk):" 9 60 "$KEYMAP") || return 1
	fi
	[[ $c =~ ^[A-Za-z0-9._-]+$ ]] || return 1
	KEYMAP=$c
	# Use it right away, so passphrases typed in this installer match the boot prompt.
	loadkeys "$KEYMAP" >/dev/null 2>&1 || true
}

menu_locale() {
	local -a items=()
	local c
	if [[ -r /usr/share/i18n/SUPPORTED ]]; then
		mapfile -t items < <(awk '$2 == "UTF-8" { print $1 }' /usr/share/i18n/SUPPORTED | sort -u)
	fi
	if ((${#items[@]})); then
		c=$(ui --title " Locale " --default-item "$LOCALE" --no-items --menu "System locale:" 0 0 0 "${items[@]}") || return 1
	else
		c=$(ui --title " Locale " --inputbox "System locale (e.g. en_US.UTF-8):" 9 60 "$LOCALE") || return 1
		[[ $c =~ ^[A-Za-z_]+\.UTF-8(@[A-Za-z]+)?$ ]] || { msg "Please enter a UTF-8 locale such as en_US.UTF-8." "Locale"; return 1; }
	fi
	LOCALE=$c
}

menu_timezone() {
	local -a regions=(UTC Africa America Antarctica Arctic Asia Atlantic Australia Europe Indian Pacific)
	local -a cities=()
	local r c
	r=$(ui --title " Timezone " --default-item "${TIMEZONE%%/*}" --no-items --menu "Region:" 0 0 0 "${regions[@]}") || return 1
	if [[ $r == UTC ]]; then
		TIMEZONE=UTC
		return 0
	fi
	mapfile -t cities < <(cd "/usr/share/zoneinfo/$r" 2>/dev/null && find . -type f | sed 's|^\./||' | sort)
	if ((${#cities[@]} == 0)); then
		msg "No time zones found for $r." "Timezone"
		return 1
	fi
	c=$(ui --title " Timezone: $r " --default-item "${TIMEZONE#*/}" --no-items --menu "City:" 0 0 0 "${cities[@]}") || return 1
	TIMEZONE="$r/$c"
}

menu_rootpass() {
	local p
	p=$(ask_password "Root password" "the root password") || return 1
	ROOT_PASS=$p
}

sync_primary() {
	if ((${#USERS[@]})); then
		USER_NAME=${USERS[0]}
	else
		USER_NAME=""
	fi
}

valid_login() { # valid_login <name> [allow existing on this system: 1]
	if ! [[ $1 =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]; then
		msg "Invalid login name. Start with a lowercase letter or _, then lowercase letters, digits, - or _ (max 31)." "User"
		return 1
	fi
	if [[ ${2:-0} != 1 ]] && { [[ $1 == root ]] || grep -q "^${1}:" /etc/passwd 2>/dev/null; }; then
		msg "'$1' is a reserved system account name." "User"
		return 1
	fi
	return 0
}

menu_sudo_level() { # menu_sudo_level <user> -> prints sudo|nopasswd|none
	ui --title " sudo for $1 " --default-item "${U_SUDO[$1]:-sudo}" --menu "Administrator rights for $1:" 12 72 3 \
		sudo "Administrator: sudo asks for the password (wheel)" \
		nopasswd "Administrator: sudo never asks for a password" \
		none "Regular user, no sudo"
}

# Add (no argument) or edit a user.
user_dialog() {
	local u=${1:-} n p lvl
	if [[ -z $u ]]; then
		u=$(ui --title " New user " --inputbox "Login name (lowercase letters, digits, '-', '_'):" 9 64) || return 1
		valid_login "$u" || return 1
		if [[ -n ${U_SUDO[$u]+x} ]]; then
			msg "'$u' is already in the list." "User"
			return 1
		fi
	fi
	n=$(ui --title " User $u " --inputbox "Full name (optional):" 9 64 "${U_FULL[$u]:-}") || return 1
	if [[ $n == *:* ]]; then
		msg "The full name must not contain ':'." "User"
		return 1
	fi
	if [[ -n ${U_PASS[$u]:-} ]] && yesno "Keep the current password of $u?" "User $u"; then
		p=${U_PASS[$u]}
	else
		p=$(ask_password "Password for $u" "the password for $u") || return 1
	fi
	lvl=$(menu_sudo_level "$u") || return 1
	if [[ -z ${U_SUDO[$u]+x} ]]; then USERS+=("$u"); fi
	U_FULL[$u]=$n
	U_PASS[$u]=$p
	U_SUDO[$u]=$lvl
	sync_primary
}

remove_user() {
	local u=$1 x
	local -a keep=()
	for x in "${USERS[@]}"; do [[ $x == "$u" ]] || keep+=("$x"); done
	USERS=("${keep[@]}")
	unset 'U_FULL[$u]' 'U_PASS[$u]' 'U_SUDO[$u]'
	sync_primary
}

make_primary() {
	local u=$1 x
	local -a order=("$u")
	for x in "${USERS[@]}"; do [[ $x == "$u" ]] || order+=("$x"); done
	USERS=("${order[@]}")
	sync_primary
}

menu_user() {
	local c u a
	local -a items=()
	while true; do
		items=()
		for u in "${USERS[@]}"; do
			items+=("$u" "${U_FULL[$u]:+${U_FULL[$u]} - }$(sudo_word "$u")$([[ $u == "${USERS[0]}" ]] && echo ' - primary')")
		done
		items+=("+add" "Add a user")
		c=$(ui --title " Users " --cancel-label "Done" --menu \
			"Accounts on the new system. The primary user (first) also gets the AUR helper and the dotfiles. Select a user to edit it." \
			0 0 0 "${items[@]}") || break
		if [[ $c == "+add" ]]; then
			user_dialog || true
			continue
		fi
		a=$(ui --title " $c " --menu "What to do with $c?" 12 60 4 \
			edit "Change name, password or sudo level" \
			primary "Make $c the primary user" \
			delete "Remove $c from the list") || continue
		case $a in
			edit) user_dialog "$c" || true ;;
			primary) make_primary "$c" ;;
			delete) if yesno "Remove $c?" "Users" 1; then remove_user "$c"; fi ;;
		esac
	done
	((${#USERS[@]} > 0))
}

# ---- LARBS-style bootstrap settings ---------------------------------------------
menu_bootstrap() {
	local c v re_url='^(https?|git)://[^[:space:]]+$|^git@[^[:space:]]+$'
	while true; do
		c=$(ui --title " Bootstrap (LARBS-style) " --cancel-label "Done" --menu \
			"After the base install: install a list of programs, copy a dotfiles repository into the primary user's home, set a login shell. Everything here is optional." \
			18 78 6 \
			progs "Programs list: ${BS_PROGS:-(none)}" \
			presets "Dotfile presets: $(lbl_dots)" \
			dotfiles "Own dotfiles repo: ${BS_DOTFILES:-(none)}${BS_BRANCH:+ ($BS_BRANCH)}" \
			shell "Login shell: $BS_SHELL" \
			power "Passwordless power/mount/update commands for wheel: $([[ $BS_POWER == 1 ]] && echo yes || echo no)" \
			example "Show the programs list format") || break
		case $c in
			presets) menu_dotfiles || true ;;
			progs)
				v=$(ui --title " Programs list " --inputbox "Path or http(s) URL of a programs CSV (see 'example'). Leave empty for none." 10 78 "$BS_PROGS") || continue
				v=$(trim "$v")
				if [[ -n $v && ! $v =~ ^https?:// && ! -f $v ]]; then
					msg "File not found: $v" "Programs list"
					continue
				fi
				if [[ -n $v && -f $v ]]; then v=$(readlink -f "$v"); fi
				BS_PROGS=$v
				;;
			dotfiles)
				v=$(ui --title " Dotfiles " --inputbox "Git URL of a dotfiles repository (copied into the primary user's home, like LARBS). Leave empty for none." 10 78 "$BS_DOTFILES") || continue
				v=$(trim "$v")
				if [[ -n $v && ! $v =~ $re_url ]]; then
					msg "That does not look like a git URL." "Dotfiles"
					continue
				fi
				BS_DOTFILES=$v
				if [[ -n $v ]]; then
					v=$(ui --title " Dotfiles " --inputbox "Branch (leave empty for the repository's default):" 9 60 "$BS_BRANCH") || continue
					v=$(trim "$v")
					if [[ -n $v && ! $v =~ ^[A-Za-z0-9._/-]+$ ]]; then msg "Invalid branch name." "Dotfiles"; continue; fi
					BS_BRANCH=$v
				else
					BS_BRANCH=""
				fi
				;;
			shell)
				v=$(ui --title " Login shell " --default-item "$BS_SHELL" --menu "Login shell for the primary user:" 11 50 3 \
					bash "GNU Bash" zsh "Z shell" fish "fish") || continue
				BS_SHELL=$v
				;;
			power)
				if yesno "Let members of wheel run shutdown, reboot, poweroff, mount, umount and 'pacman -Syu' without typing a password (like LARBS)?" "Power commands" 1; then BS_POWER=1; else BS_POWER=0; fi
				;;
			example)
				dialog --backtitle "$BACKTITLE" --title " Programs list format " --cr-wrap --no-collapse --msgbox \
"One program per line:  TAG,PROGRAM,DESCRIPTION
Lines starting with # are ignored. TAG:
  (empty)  package from the Artix repositories
  A        package from the AUR (needs an AUR helper)
  G        git repository, built with make && make install
  P        Python program installed with pipx (as the user)
  F        Flatpak app from Flathub

This is LARBS's own format, so LARBS's progs.csv works.
Example:
#TAG,NAME IN REPO (OR GIT URL),PURPOSE
,firefox,\"is the web browser.\"
,vlc,\"plays videos and music.\"
A,librewolf-bin,\"is a browser from the AUR.\"
G,https://git.suckless.org/st,\"is the terminal.\"
P,yt-dlp,\"downloads videos.\"
F,com.spotify.Client,\"plays music.\"" 23 74 >/dev/tty 2>&1 || true
				;;
		esac
	done
	return 0
}

menu_network() {
	local c
	c=$(ui --title " Network " --default-item "$NET" --menu "Network management on the new system:" 13 76 4 \
		nm "NetworkManager (recommended; Wi-Fi via nmtui or applet)" \
		connman "ConnMan (as on the Artix ISO; Wi-Fi via connmanctl)" \
		dhcpcd "dhcpcd + iwd - small, no desktop applet" \
		none "Configure networking yourself later") || return 1
	NET=$c
}


# ---- packages: official repositories first, the AUR when a helper is chosen ----
# The live system's sync databases (with multilib turned on) answer "is this in
# the official repositories?". Names that are not, come from the AUR when an AUR
# helper is chosen, and are reported otherwise.
OFFICIAL_LIST=/tmp/artix-install.official

official_refresh() {
	{ pacman -Slq 2>/dev/null; pacman -Sgq 2>/dev/null; } | sort -u >"$OFFICIAL_LIST" || true
}
official_has() { # official_has <package or group>
	[[ -s $OFFICIAL_LIST ]] || official_refresh
	grep -qxF -- "$1" "$OFFICIAL_LIST"
}
# Packages of a list that are not in the official repositories.
not_official() {
	local p out=""
	[[ -s $OFFICIAL_LIST ]] || official_refresh
	[[ -s $OFFICIAL_LIST ]] || return 0   # cannot tell (no database): assume official
	for p in "$@"; do official_has "$p" || out+="${out:+ }$p"; done
	printf '%s' "$out"
}

# 32-bit libraries (Steam, Wine) are in Artix's [lib32] repository, which the
# ISO's pacman.conf has commented out; the installer needs to see it.
enable_multilib() { # enable_multilib <pacman.conf>
	local f=${1:-/etc/pacman.conf}
	grep -q '^\[lib32\]' "$f" && return 0
	if grep -q '^#\[lib32\]' "$f"; then
		sed -i '/^#\[lib32\]/{s/^#//;n;s/^#[[:space:]]*Include/Include/}' "$f"
	else
		printf '\n[lib32]\nInclude = /etc/pacman.d/mirrorlist\n' >>"$f"
	fi
}

# Arch's own repositories, after Artix's (so Artix's systemd-free builds win):
# artix-archlinux-support brings Arch's keyring and mirror list.
arch_repos_conf() { # arch_repos_conf <pacman.conf>
	local f=$1
	grep -q '^\[extra\]' "$f" || printf '\n# Arch Linux repositories (artix-archlinux-support), added by artix-install.sh\n[extra]\nInclude = /etc/pacman.d/mirrorlist-arch\n' >>"$f"
	if multilib_on && ! grep -q '^\[multilib\]' "$f"; then
		printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist-arch\n' >>"$f"
	fi
}

# On the live system (to see the packages) or in the new one (<root> = $TARGET).
arch_repos_setup() { # arch_repos_setup live|target
	arch_repos_on || return 0
	if [[ $1 == live ]]; then
		[[ -s /etc/pacman.conf.artix-install ]] || cp /etc/pacman.conf /etc/pacman.conf.artix-install || return 1
		pacman -S --needed --noconfirm artix-archlinux-support || return 1
		pacman-key --populate archlinux || return 1
		arch_repos_conf /etc/pacman.conf
		pacman -Sy
	else
		in_target pacman -S --needed --noconfirm artix-archlinux-support || return 1
		in_target pacman-key --populate archlinux || return 1
		arch_repos_conf "$TARGET/etc/pacman.conf"
		in_target pacman -Sy
	fi
	echo "Arch Linux repositories enabled ($1): [extra]$(multilib_on && echo ' [multilib]')"
}

# ---- desktops and window managers --------------------------------------------
# id|kind|label|packages that must install|packages installed when available
# kind: de = desktop environment, x11 / wl = X11 / Wayland window manager
desktop_table() {
	cat <<'EOF'
xfce|de|Xfce|xfce4 xfce4-goodies pavucontrol gvfs gnome-keyring|
plasma|de|KDE Plasma|plasma konsole dolphin|ark kate spectacle gwenview okular
gnome|de|GNOME|gnome gnome-tweaks|
mate|de|MATE|mate mate-extra pavucontrol|
cinnamon|de|Cinnamon|cinnamon gnome-terminal gnome-keyring|
lxqt|de|LXQt|lxqt breeze-icons pavucontrol-qt|
budgie|de|Budgie|budgie mate-terminal nemo pavucontrol|
cosmic|de|COSMIC|cosmic|
enlightenment|de|Enlightenment|enlightenment terminology|
i3|x11|i3|i3-wm i3status i3lock|i3blocks autotiling
bspwm|x11|bspwm|bspwm sxhkd polybar|dmenu
dwm|x11|dwm (AUR)|dwm st dmenu slstatus slock|
awesome|x11|awesome|awesome|
qtile|x11|Qtile|qtile|python-psutil python-dbus-fast
herbstluftwm|x11|herbstluftwm|herbstluftwm|polybar
openbox|x11|Openbox|openbox obconf tint2|jgmenu lxappearance-obconf
fluxbox|x11|Fluxbox|fluxbox|
icewm|x11|IceWM|icewm|
spectrwm|x11|spectrwm|spectrwm|
leftwm|x11|LeftWM|leftwm|polybar
sway|wl|Sway|sway swaylock swayidle swaybg waybar|xdg-desktop-portal-wlr autotiling
hyprland|wl|Hyprland|hyprland hyprlock hypridle hyprpaper waybar xdg-desktop-portal-hyprland|hyprpolkitagent qt5-wayland qt6-wayland
niri|wl|niri|niri xwayland-satellite swaybg swaylock swayidle waybar|xdg-desktop-portal-gnome
river|wl|river|river swaybg swaylock swayidle waybar|xdg-desktop-portal-wlr
labwc|wl|labwc|labwc swaybg swaylock swayidle waybar|xdg-desktop-portal-wlr
wayfire|wl|Wayfire|wayfire swaybg swaylock|wcm xdg-desktop-portal-wlr
EOF
}

# The "rounded" set every X11 / Wayland window manager gets: terminal, launcher,
# notifications, compositor/wallpaper, file manager, polkit agent, lock,
# volume/brightness/media keys, screenshots, fonts and themes.
WM_X11_TOOLS="alacritty rofi dunst picom feh thunar thunar-volman gvfs tumbler polkit-gnome xss-lock brightnessctl playerctl pamixer pavucontrol maim xclip xdotool flameshot lxappearance-gtk3 dex xorg-xsetroot numlockx xorg-setxkbmap xorg-xrandr arandr udiskie ttf-font-awesome ttf-nerd-fonts-symbols papirus-icon-theme arc-gtk-theme network-manager-applet"
WM_WL_TOOLS="foot alacritty fuzzel wofi mako grim slurp swappy wl-clipboard cliphist brightnessctl playerctl pamixer pavucontrol thunar thunar-volman gvfs tumbler polkit-gnome nwg-look kanshi wlogout xdg-desktop-portal xdg-desktop-portal-gtk xorg-xwayland udiskie ttf-font-awesome ttf-nerd-fonts-symbols papirus-icon-theme arc-gtk-theme network-manager-applet"

desktop_on() { [[ -n $DESKTOP && $DESKTOP != none ]]; }
desktop_field() { desktop_table | awk -F'|' -v i="$1" -v f="$2" '$1 == i { print $f; exit }'; }
desktop_kind() { desktop_field "$1" 2; }
has_kind() { # has_kind de|x11|wl: is any selected desktop of that kind?
	local d
	desktop_on || return 1
	for d in $DESKTOP; do
		if [[ $(desktop_kind "$d") == "$1" ]]; then return 0; fi
	done
	return 1
}

lbl_desktop() {
	local d out=""
	if ! desktop_on; then
		printf 'none (console only)'
		return 0
	fi
	for d in $DESKTOP; do out+="${out:+, }$(desktop_field "$d" 3)"; done
	printf '%s' "$out"
}

# Login screen: an explicit choice, or picked from the selected desktops.
desktop_dm() {
	desktop_on || return 0
	case $DM in
		none) return 0 ;;
		lightdm | sddm | gdm | greetd | ly) echo "$DM" ;;
		*)
			if has "$DESKTOP" plasma || has "$DESKTOP" lxqt || has "$DESKTOP" cosmic; then echo sddm
			elif has "$DESKTOP" gnome; then echo gdm
			elif has "$DESKTOP" hyprland && ! has_kind x11 && ! has_kind de; then echo sddm
			elif has_kind wl && ! has_kind x11 && ! has_kind de; then echo greetd
			else echo lightdm; fi
			;;
	esac
}
lbl_dm() {
	if ! desktop_on; then printf 'n/a (no desktop)'; return 0; fi
	case $DM in
		auto) printf 'auto: %s' "$(desktop_dm)" ;;
		none) printf 'none (console + startx)' ;;
		*) printf '%s' "$DM" ;;
	esac
}

dm_packages() {
	local dm
	dm=$(desktop_dm)
	case $dm in
		lightdm) printf '%s\n' lightdm lightdm-gtk-greeter ;;
		sddm | gdm | ly) echo "$dm" ;;
		greetd)
			printf '%s\n' greetd greetd-tuigreet
			if has_kind x11 || has_kind de; then echo xorg-xinit; fi
			;;
		*) if has_kind x11 || has_kind de; then echo xorg-xinit; fi ;;
	esac
	if [[ -n $dm ]]; then dm_service_pkg; fi
}

# The login screen's start script for the chosen init, e.g. sddm-openrc.
dm_service_pkg() {
	local dm
	dm=$(desktop_dm)
	if [[ -n $dm ]]; then echo "$dm-$INIT"; fi
}

desktop_packages() {
	local d
	desktop_on || return 0
	printf '%s\n' xorg-server mesa pipewire pipewire-pulse pipewire-alsa wireplumber \
		xdg-user-dirs xdg-utils noto-fonts noto-fonts-emoji ttf-dejavu
	for d in $DESKTOP; do
		desktop_field "$d" 4 | tr ' ' '\n'
	done
	dm_packages
}

# Installed with install_available: a missing one is skipped with a warning.
desktop_extra_packages() {
	local d
	desktop_on || return 0
	for d in $DESKTOP; do
		desktop_field "$d" 5 | tr ' ' '\n'
	done
	if has_kind x11; then tr ' ' '\n' <<<"$WM_X11_TOOLS"; fi
	if has_kind wl; then tr ' ' '\n' <<<"$WM_WL_TOOLS"; fi
	if [[ $NET == nm ]]; then
		if has "$DESKTOP" xfce || has "$DESKTOP" mate || has "$DESKTOP" budgie || has "$DESKTOP" cinnamon; then
			echo network-manager-applet
		fi
		if has "$DESKTOP" lxqt; then echo nm-tray; fi
	fi
}

menu_desktop() {
	local c id kind label
	local -a items=()
	while IFS='|' read -r id kind label _; do
		case $kind in
			de) label="Desktop:     $label" ;;
			x11) label="WM, X11:     $label" ;;
			*) label="WM, Wayland: $label" ;;
		esac
		items+=("$id" "$label")
	done < <(desktop_table)
	c=$(checklist "Desktops and window managers" "Pick any number (space toggles); each one becomes a session on the login screen. Window managers come with a bar, launcher, terminal, notifications, file manager, lock and screenshot tools." "$DESKTOP" "${items[@]}") || return 1
	DESKTOP=${c:-none}
	prune_dots
	if [[ -n $PRUNED ]]; then
		msg "These dotfile presets were removed because their desktop is no longer selected:\n\n$PRUNED" "Dotfiles" 11 70
	fi
	if has "$DESKTOP" dwm && ! aur_on; then
		msg "dwm, st and slstatus are only in the AUR. Choose an AUR helper (yay or paru) in the AUR item, or dwm is skipped." "dwm" 9 70
	fi
	if desktop_on && [[ $NET != nm ]]; then
		if yesno "Desktops work best with NetworkManager.\n\nSwitch the network setting to NetworkManager?" "Network"; then
			NET="nm"
		fi
	fi
	return 0
}

menu_dm() {
	local c now
	local -a items
	if ! desktop_on; then
		msg "Choose a desktop or window manager first." "Login screen"
		return 1
	fi
	now=$(DM=auto desktop_dm)
	items=(auto "Choose for me (now: $now)"
		lightdm "LightDM + GTK greeter - X11 and Wayland sessions"
		sddm "SDDM - KDE's login screen, X11 and Wayland"
		gdm "GDM - GNOME's login screen"
		greetd "greetd + tuigreet - text login, best for Wayland WMs"
		ly "Ly - text login with a session list")
	items+=(none "None - log in on the console, start it yourself")
	c=$(ui --title " Login screen " --default-item "$DM" --menu "Display manager for: $(lbl_desktop)" 0 78 0 "${items[@]}") || return 1
	DM=$c
}

# ---- dotfile presets ------------------------------------------------------------
# id|for (desktop ids or "any")|label|sources|packages|note
# source = <git url>#<branch>#<how>; how: skel = repo's etc/skel -> ~,
# dots = the repo's dot-files -> ~, config = repo's config/ -> ~/.config,
# build = clone to ~/.local/src and make install, fish / bash = shell configs.
dots_table() {
	local gh=https://github.com gl=https://gitlab.com/garuda-linux/themes-and-settings/settings
	local cx="$gh/CachyOS/cachyos-alacritty-config#master#skel" cp="$gh/CachyOS/cachyos-picom-config#develop#skel"
	local cdev="base-devel libx11 libxft libxinerama freetype2 fontconfig harfbuzz"
	cat <<EOF
cachyos-i3|i3|CachyOS i3|$gh/CachyOS/cachyos-i3wm-settings#develop#skel $cx $cp|polybar rofi dunst picom feh pamixer polkit-gnome xob dex jq alacritty redshift ttf-hack|
cachyos-hyprland|hyprland|CachyOS Hyprland|$gh/CachyOS/cachyos-hyprland-settings#master#skel $cx|waybar swaybg swaylock mako wofi wlogout wl-clipboard kvantum qt5ct brightnessctl pamixer polkit-kde-agent ttf-font-awesome noto-fonts-emoji alacritty grim slurp|
cachyos-niri|niri|CachyOS niri|$gh/CachyOS/cachyos-niri-settings#master#skel $cx|waybar swaybg swww swaylock mako wofi wlogout wl-clipboard bemenu kvantum qt5ct brightnessctl pamixer wob polkit-kde-agent xwayland-satellite ttf-font-awesome noto-fonts-emoji alacritty|
cachyos-qtile|qtile|CachyOS Qtile|$gh/CachyOS/cachyos-qtile-settings#master#skel|picom rofi thunar alacritty python-psutil python-pulsectl python-dbus-fast polkit-gnome gnome-keyring feh qt5ct flameshot playerctl dunst wired ttf-font-awesome ttf-roboto ttf-ibm-plex|
cachyos-wayfire|wayfire|CachyOS Wayfire|$gh/CachyOS/cachyos-wayfire-settings#develop#skel $cx|bemenu kvantum qt5ct alacritty xorg-xwayland|
cachyos-openbox|openbox|CachyOS Openbox|$gh/CachyOS/cachyos-openbox-settings#develop#skel $cx $cp|dunst nitrogen rofi tint2 picom brightnessctl scrot xclip xsettingsd xss-lock thunar thunar-volman tumbler mpv pavucontrol xfce4-power-manager polkit-gnome jgmenu alacritty|
cachyos-kde|plasma|CachyOS KDE Plasma look|$gh/CachyOS/cachyos-kde-settings#develop#skel $cx|alacritty ttf-hack|
cachyos-xfce|xfce|CachyOS Xfce look|$gh/CachyOS/cachyos-xfce-settings#develop#skel $cx|alacritty kvantum qt5ct xfce4-whiskermenu-plugin|
cachyos-fish|any|CachyOS fish config (login shell: fish)|$gh/CachyOS/cachyos-fish-config#main#fish|fish fastfetch bat eza fzf|
eos-i3|i3|EndeavourOS i3|$gh/endeavouros-team/endeavouros-i3wm-setup#main#skel|i3blocks rofi dunst picom dex xfce4-terminal thunar xss-lock numlockx nitrogen feh scrot autotiling playerctl clipman polkit-gnome brightnessctl|
eos-sway|sway|EndeavourOS Sway (community)|$gh/EndeavourOS-Community-Editions/sway#main#dots|waybar wofi mako foot swaybg swaylock swayidle grim slurp wl-clipboard|
eos-bspwm|bspwm|EndeavourOS bspwm (community)|$gh/EndeavourOS-Community-Editions/bspwm#main#dots|sxhkd polybar rofi dunst picom nitrogen feh xfce4-terminal|
eos-openbox|openbox|EndeavourOS Openbox (community)|$gh/EndeavourOS-Community-Editions/openbox#main#dots|tint2 obconf jgmenu picom|
eos-awesome|awesome|EndeavourOS awesome (community)|$gh/EndeavourOS-Community-Editions/awesome#master#dots|xfce4-terminal rofi picom|
garuda-sway|sway|Garuda Sway|$gl/garuda-sway-settings.git#master#skel|waybar wofi mako foot swaybg swaylock swayidle grim slurp wl-clipboard|
garuda-i3|i3|Garuda i3|$gl/garuda-i3-settings.git#master#skel|rofi dunst kitty polkit-gnome numlockx xfce4-power-manager dex playerctl brightnessctl dmenu|
garuda-bspwm|bspwm|Garuda bspwm|$gl/garuda-bspwm-settings.git#master#skel|sxhkd polybar rofi dunst picom|
garuda-wayfire|wayfire|Garuda Wayfire|$gl/garuda-wayfire-settings.git#master#skel|alacritty|
larbs|dwm|LARBS (Luke Smith): voidrice, dwm, st, dmenu|$gh/LukeSmithxyz/voidrice#master#dots $gh/LukeSmithxyz/dwm#master#build $gh/LukeSmithxyz/st#master#build $gh/LukeSmithxyz/dmenu#master#build $gh/LukeSmithxyz/dwmblocks#master#build|zsh lf nsxiv mpv zathura zathura-pdf-mupdf dunst picom xwallpaper maim xclip xdotool unclutter pulsemixer neovim ffmpeg fzf ttf-font-awesome noto-fonts-emoji $cdev|dwm, st, dmenu and dwmblocks are built from source into /usr/local; the login shell becomes zsh.
gh0stzk-bspwm|bspwm|gh0stzk bspwm (themed rices)|$gh/gh0stzk/dotfiles#master#config|polybar sxhkd picom rofi dunst eww feh alacritty kitty jq xdotool maim xclip brightnessctl playerctl pamixer xsettingsd|
titus-bash|any|Chris Titus mybash (.bashrc + starship prompt)|$gh/ChrisTitusTech/mybash#main#bash|starship fzf zoxide bat eza fastfetch trash-cli tree multitail neovim|
EOF
}
dots_field() { dots_table | awk -F'|' -v i="$1" -v f="$2" '$1 == i { print $f; exit }'; }

# Drop presets whose desktop is no longer selected. Sets PRUNED to their labels.
PRUNED=""
prune_dots() {
	local id d kept=""
	PRUNED=""
	for id in $DOTS; do
		d=$(dots_field "$id" 2)
		if [[ $d == any ]] || has "$DESKTOP" "$d"; then
			kept+="${kept:+ }$id"
		else
			PRUNED+="${PRUNED:+, }$(dots_field "$id" 3)"
		fi
	done
	DOTS=$kept
}

lbl_dots() {
	local n
	n=$(wc -w <<<"$DOTS")
	if ((n == 0)); then printf '(none)'; elif ((n == 1)); then dots_field "$DOTS" 3; else printf '%s presets' "$n"; fi
}

menu_dotfiles() {
	local c id for label d show added="" out
	local -a items=()
	while IFS='|' read -r id for label _; do
		show=0
		if [[ $for == any ]] || ! desktop_on; then show=1; fi
		for d in $for; do
			if has "$DESKTOP" "$d"; then show=1; fi
		done
		if ((show)); then
			if [[ $for == any ]]; then items+=("$id" "$label"); else items+=("$id" "$label  [$(desktop_field "$for" 3)]"); fi
		fi
	done < <(dots_table)
	c=$(checklist "Dotfiles" "Popular configurations, copied into the primary user's home at the end of the install (an existing file is kept as name.~1~). The packages they use are installed (from the AUR too when an AUR helper is chosen).$(desktop_on && echo " Only presets for your desktops are shown.")" "$DOTS" "${items[@]}") || return 1
	# A preset needs its window manager.
	for id in $c; do
		for d in $(dots_field "$id" 2); do
			[[ $d == any ]] && continue
			if ! has "$DESKTOP" "$d"; then
				if desktop_on; then DESKTOP+=" $d"; else DESKTOP=$d; fi
				added+="${added:+, }$(desktop_field "$d" 3)"
			fi
		done
	done
	DOTS=$c
	out=""
	if [[ -n $added ]]; then out+="Added to Desktops: $added.\n\n"; fi
	if has "$DOTS" larbs && has "$DOTS" cachyos-fish; then
		out+="LARBS uses zsh and the CachyOS preset uses fish; the login shell is set to fish (change it under Bootstrap).\n\n"
		BS_SHELL=fish
	elif has "$DOTS" larbs && [[ $BS_SHELL == bash ]]; then
		BS_SHELL=zsh
		out+="LARBS's dotfiles expect zsh: the login shell is now zsh.\n\n"
	elif has "$DOTS" cachyos-fish && [[ $BS_SHELL != fish ]]; then
		BS_SHELL=fish
		out+="The CachyOS fish preset sets the login shell to fish.\n\n"
	fi
	if [[ -n $out ]]; then msg "${out%\\n\\n}" "Dotfiles" 11 70; fi
	return 0
}

# checklist helper: checklist "title" "text" "<current list>" tag desc tag desc ...
checklist() {
	local title=$1 text=$2 cur=$3 out
	shift 3
	local -a items=()
	while (($# >= 2)); do
		if has "$cur" "$1"; then items+=("$1" "$2" on); else items+=("$1" "$2" off); fi
		shift 2
	done
	out=$(ui --title " $title " --separate-output --checklist "$text" 0 0 0 "${items[@]}") || return 1
	printf '%s\n' "$out" | paste -sd ' ' -
}

menu_gpu() {
	local c sel det
	det=$(detect_gpus)
	c=$(ui --title " GPU drivers " --default-item "$([[ $GPU == auto || $GPU == none ]] && echo "$GPU" || echo choose)" --menu \
		"Detected: \Zb${det:-no known GPU}\Zn\n\nAuto picks open-source drivers (nouveau for NVIDIA). Choose the NVIDIA driver yourself for best NVIDIA performance." 15 78 3 \
		auto "Install drivers for the detected GPUs" \
		choose "Pick the drivers yourself" \
		none "No GPU packages") || return 1
	if [[ $c != choose ]]; then
		GPU=$c
		return 0
	fi
	sel=$(checklist "GPU drivers" "Space selects. Pick ONE NVIDIA driver at most (check your card family). The legacy NVIDIA drivers come from the AUR." \
		"$([[ $GPU == auto || $GPU == none ]] && echo "$det" || echo "$GPU")" \
		intel "Intel - Mesa, Vulkan, VA-API" \
		amd "AMD - Mesa, RADV Vulkan, VA-API" \
		nouveau "NVIDIA open source (nouveau)" \
		nvidia "NVIDIA: RTX 20xx / GTX 16xx and newer (open kernel module)" \
		nvidia580 "NVIDIA legacy 580xx: GTX 9xx / 10xx (AUR)" \
		nvidia470 "NVIDIA legacy 470xx: GTX 6xx / 7xx (AUR)" \
		vm "Virtual machine - Mesa + guest tools") || return 1
	GPU=${sel:-none}
}

menu_apps() {
	local sel
	sel=$(checklist "Applications" "Space selects. Installed from the Artix repositories." "$APPS" \
		firefox "Firefox web browser" \
		chromium "Chromium web browser" \
		thunderbird "Thunderbird mail" \
		vlc "VLC media player" \
		mpv "mpv media player" \
		libreoffice "LibreOffice suite" \
		gimp "GIMP image editor" \
		obs "OBS Studio" \
		keepassxc "KeePassXC password manager" \
		telegram-desktop "Telegram" \
		discord "Discord" \
		flatpak "Flatpak + Flathub remote" \
		git "Git" \
		htop "htop" \
		neovim "Neovim" \
		openssh "OpenSSH server (sshd service)" \
		cups "Printing: CUPS (service)") || return 1
	APPS=$sel
}

menu_gaming() {
	local sel
	sel=$(checklist "Gaming" "Space selects. Steam and Wine turn on the 32-bit repository (multilib) automatically." "$GAMING" \
		multilib "32-bit libraries (multilib): Mesa, Vulkan, GPU driver" \
		steam "Steam" \
		wine "Wine" \
		winetricks "Winetricks" \
		lutris "Lutris game launcher" \
		gamemode "Feral GameMode") || return 1
	GAMING=$sel
}

menu_aur() {
	local c
	c=$(ui --title " AUR helper " --default-item "$AUR_HELPER" --menu \
		"The AUR (Arch User Repository) holds build recipes written by users, not by Arch. An AUR helper builds and updates them like normal packages.\n\nChoosing one also lets the installer take AUR-only items from it (some window managers, peripheral tools, legacy NVIDIA drivers). It is installed for the primary user from its prebuilt (-bin) AUR package." \
		17 78 3 \
		yay "yay - the most widely used helper (Go)" \
		paru "paru - yay-like, written in Rust, reviews PKGBUILDs by default" \
		none "No AUR helper (official repositories only)") || return 1
	AUR_HELPER=$c
	if ! aur_on; then
		AUR_PKGS=""
		return 0
	fi
	c=$(ui --title " AUR packages " --inputbox \
		"Packages to build from the AUR with $AUR_HELPER, separated by spaces (optional). Only add packages you trust: their build scripts run on your system.\n\nExamples: visual-studio-code-bin google-chrome spotify" \
		12 78 "$AUR_PKGS") || return 0
	c=$(trim "$(printf '%s' "$c" | tr ',' ' ' | tr -s ' ')")
	if ! pkg_words_ok "$c"; then
		msg "Package names may only contain letters, digits and . _ + -, and must start with a letter or digit." "AUR packages"
		return 0
	fi
	AUR_PKGS=$c
	return 0
}

menu_extras() {
	local c
	c=$(ui --title " Extra packages " --inputbox \
		"Additional packages from the official repositories, separated by spaces (optional). For the AUR, use the AUR item.\nExamples: vim htop openssh openssh-$INIT tlp tlp-$INIT" \
		10 78 "$EXTRA_PKGS") || return 1
	c=$(trim "$(printf '%s' "$c" | tr ',' ' ' | tr -s ' ')")
	if ! pkg_words_ok "$c"; then
		msg "Package names may only contain letters, digits and . _ + -, and must start with a letter or digit." "Extra packages"
		return 1
	fi
	EXTRA_PKGS=$c
}

# =============================================================================
#  Validation and confirmation
# =============================================================================
# Everything the install will ask pacman for (for the availability check).
all_wanted_packages() {
	{
		desktop_packages
		desktop_extra_packages
		gpu_packages
		app_packages
		gaming_packages
		periph_packages
		local id
		for id in $DOTS; do dots_field "$id" 5 | tr ' ' '\n'; done
		tr ' ' '\n' <<<"$EXTRA_PKGS"
	} | awk 'NF && !seen[$0]++'
}

validate() {
	local -a missing=()
	[[ -n $DISK && -b $DISK ]] || missing+=("target disk")
	[[ -n $ROOT_PASS ]] || missing+=("root password")
	((${#USERS[@]} > 0)) || missing+=("at least one user account")
	if encrypted && [[ -z $LUKS_PASS ]]; then missing+=("encryption passphrase (or choose 'none')"); fi
	if ((${#missing[@]})); then
		msg "Please set first:\n$(printf '  - %s\\n' "${missing[@]}")" "Incomplete" 12 70
		return 1
	fi

	local nv count=0 g
	for g in $(gpu_list); do [[ $g == nvidia* ]] && count=$((count + 1)); done
	nv=$(nvidia_driver)
	if ((count > 1)); then
		msg "Select only one NVIDIA driver." "GPU drivers"
		return 1
	fi
	if [[ -n $nv ]] && has "$(gpu_list)" nouveau; then
		msg "The NVIDIA driver and nouveau cannot be installed together. Pick one." "GPU drivers"
		return 1
	fi
	if [[ $nv == nvidia580 || $nv == nvidia470 ]] && ! aur_on; then
		msg "The legacy NVIDIA drivers are in the AUR. Choose an AUR helper (yay or paru), or nouveau." "NVIDIA" 9 70
		return 1
	fi
	if [[ -n $GAMING || -n $nv ]] && ! desktop_on; then
		yesno "You selected GPU or gaming packages without a desktop. Continue anyway?" "No desktop" 1 || return 1
	fi
	if has "$PERIPH" openlinkhub && has "$PERIPH" ckb-next; then
		msg "Pick ckb-next OR OpenLinkHub in Peripherals: they drive the same Corsair devices." "Peripherals"
		return 1
	fi
	if periph_gui && ! desktop_on; then
		yesno "Some peripheral tools you picked are desktop apps, and no desktop is selected. Continue anyway?" "No desktop" 1 || return 1
	fi
	if [[ -n $AUR_PKGS ]] && ! aur_on; then
		msg "AUR packages are listed, but no AUR helper is chosen (AUR item)." "AUR"
		return 1
	fi

	if uefi_only && [[ $FIRMWARE != uefi || $EFI_BITS != 64 ]]; then
		msg "$(lbl_boot) needs 64-bit UEFI firmware, but this computer was started with ${FIRMWARE^^}$([[ $FIRMWARE == uefi ]] && echo " (${EFI_BITS}-bit)"). Choose another boot loader." "Boot loader"
		return 1
	fi
	if bios_only && [[ $FIRMWARE != bios ]]; then
		msg "$(lbl_boot) is only offered for BIOS (legacy) systems. Choose another boot loader." "Boot loader"
		return 1
	fi
	if [[ $BOOTLOADER == efistub || $BOOTLOADER == zfsbootmenu ]] && [[ ! -d /sys/firmware/efi/efivars ]]; then
		msg "$(lbl_boot) is started from a UEFI boot entry, but the EFI variables (/sys/firmware/efi/efivars) are not available." "Boot loader"
		return 1
	fi
	# Login screens need a start script for the chosen init (sddm-openrc, ...).
	local dsp
	dsp=$(dm_service_pkg)
	if [[ -n $dsp && -s $OFFICIAL_LIST ]] && ! official_has "$dsp"; then
		msg "Artix has no start script for the login screen $(desktop_dm) with $(lbl_init) ($dsp). Choose another login screen (Login item) or init (Init item)." "Login screen" 10 74
		return 1
	fi
	if [[ $SECUREBOOT == 1 ]] && ! secureboot_on; then
		yesno "Secure Boot is not possible with $(lbl_boot) on this computer and will be left off.\n\nContinue without it?" "Secure Boot" 0 || return 1
	fi
	if [[ $SNAPPER == 1 && $FS != btrfs && $FS != zfs ]]; then
		yesno "Snapshots need btrfs or ZFS; with $FS they are skipped.\n\nContinue without snapshots?" "Snapshots" 0 || return 1
	fi
	if zfs_on && [[ $BOOTLOADER != zfsbootmenu ]]; then
		msg "ZFS is booted by ZFSBootMenu. Choose ZFS again in the Filesystem item to set it up." "ZFS"
		return 1
	fi
	if [[ $BOOTLOADER == zfsbootmenu ]] && ! zfs_on; then
		msg "ZFSBootMenu only boots ZFS. Choose another boot loader, or ZFS in the Filesystem item." "Boot loader"
		return 1
	fi
	if zfs_on && [[ $SWAP == file ]]; then
		msg "A swap file on ZFS can hang the system under memory pressure. Choose zram or no swap (Swap item)." "Swap"
		return 1
	fi

	if [[ -z $KERNELS ]]; then
		msg "Choose at least one kernel (menu item Kernel)." "Kernel"
		return 1
	fi

	# Packages that are not in the official repositories.
	local -a want=()
	local nf
	mapfile -t want < <(all_wanted_packages)
	nf=$(not_official "${want[@]}")
	if [[ -n $nf ]]; then
		if aur_on; then
			yesno "These packages are not in the official repositories and will be built from the AUR with $AUR_HELPER:\n\n$nf\n\nAUR build scripts are written by users. Continue?" "From the AUR" 0 15 76 || return 1
		else
			yesno "These packages are not in the official repositories and will be skipped (choose an AUR helper in the AUR item to get them from the AUR):\n\n$nf\n\nContinue without them?" "Not available" 0 15 76 || return 1
		fi
	fi

	compute_layout
	local bytes need
	bytes=$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)
	need=$(required_mib)
	if ((bytes / 1048576 < need)); then
		msg "$DISK is too small for this configuration: $((need / 1024 + 1)) GiB are required." "Disk too small"
		return 1
	fi
	if desktop_on && ((bytes / 1073741824 < 20)); then
		yesno "A desktop installation should have at least 20 GiB.\n\nContinue anyway?" "Small disk" 1 || return 1
	fi
	if grub_unlocks && [[ $LUKS_PASS == *[![:ascii:]]* ]]; then
		yesno "The passphrase contains non-ASCII characters. GRUB reads the passphrase with a US keyboard layout and may not be able to unlock the disk.\n\nContinue anyway?" "Passphrase" 1 || return 1
	fi
	if grub_unlocks && [[ $KEYMAP != us ]]; then
		msg "Note: GRUB asks for the passphrase using the US keyboard layout, not '$KEYMAP'. Characters that differ between the layouts must be typed at their US positions." "Keyboard layout" 9 72
	fi
	return 0
}

build_summary() {
	local model
	model=$(trim "$(lsblk -dno MODEL "$DISK" 2>/dev/null)")
	cat <<EOF
Disk        $DISK  $(lsblk -dno SIZE "$DISK" | tr -d ' ')  ${model}
            \Z1\ZbEVERYTHING ON THIS DISK WILL BE ERASED\Zn
Firmware    ${FIRMWARE^^}$([[ $FIRMWARE == uefi ]] && echo " (${EFI_BITS}-bit)")
Partitions  GPT:
$(layout_lines)
Boot loader $(lbl_boot); Secure Boot: $(lbl_sb)
Snapshots   $(lbl_snapper)
Swap        $(lbl_swap)
Kernels     $(lbl_kernels)
Mirrors     $(lbl_mirror)
Host        $HOST_NAME, keymap $KEYMAP, locale $(lbl_locale), $TIMEZONE
Users       $(lbl_user)
Bootstrap   $(lbl_bootstrap)$([[ -n $DOTS ]] && printf '; dotfiles: %s' "$DOTS")
Desktop     $(lbl_desktop)
Login       $(lbl_dm); network: $(lbl_net)
GPU         $(lbl_gpu)
Software    $(lbl_list "$(trim "$APPS $EXTRA_PKGS")"); gaming: $(lbl_list "$GAMING")
Peripherals $(lbl_periph)
AUR         $(lbl_aur)
EOF
}

confirm_install() {
	local word
	dialog --backtitle "$BACKTITLE" --colors --cr-wrap --no-collapse --title " Summary " \
		--yes-label "Continue" --no-label "Back" --defaultno \
		--yesno "$(build_summary)" 0 0 >/dev/tty 2>&1 || return 1
	word=$(ui --title " Last chance " --inputbox \
		"\Z1\ZbAll data on $DISK will be destroyed.\Zn\n\nType the disk name (\Zb${DISK#/dev/}\Zn) to start the installation:" \
		11 70) || return 1
	if [[ $word != "${DISK#/dev/}" ]]; then
		msg "The confirmation did not match. Nothing was changed." "Cancelled"
		return 1
	fi
	return 0
}

# =============================================================================
#  Installation steps
#  Each step runs in a subshell with "set -Eeuo pipefail": the first failing
#  command aborts the step and the installer shows the end of the log.
# =============================================================================
step_prepare_live() {
	local -a need=()
	enable_multilib /etc/pacman.conf
	if [[ $MIRROR == rank ]] && [[ ! -s /etc/pacman.d/mirrorlist.artix-install ]]; then
		echo "Ranking mirrors ..."
		rank_mirrors || echo "rankmirrors failed; keeping the current mirror list."
	fi
	pacman -Sy
	arch_repos_setup live
	official_refresh
	command -v sfdisk >/dev/null || need+=(util-linux)
	command -v mkfs.vfat >/dev/null || need+=(dosfstools)
	command -v mkfs.ext4 >/dev/null || need+=(e2fsprogs)
	if [[ $FS == btrfs ]] && ! command -v mkfs.btrfs >/dev/null; then need+=(btrfs-progs); fi
	if encrypted && ! command -v cryptsetup >/dev/null; then need+=(cryptsetup); fi
	if ((${#need[@]} == 0)); then
		echo "All tools needed by the installer are present."
	else
		echo "Installing into the live system: ${need[*]}"
		pacman -S --needed --noconfirm "${need[@]}"
	fi
	if zfs_on; then zfs_live_setup; fi
}

release_disk() {
	local disk=$1 dev mp type sw
	zfs_release_disk "$disk"
	# Unmount everything on the disk (deepest devices first) and disable swap.
	while read -r dev; do
		while read -r mp; do
			[[ -n $mp ]] || continue
			while read -r sw; do
				if [[ -n $sw ]]; then swapoff "$sw" 2>/dev/null || true; fi
			done < <(awk -v m="${mp%/}/" 'NR > 1 && index($1, m) == 1 { print $1 }' /proc/swaps 2>/dev/null || true)
			echo "Unmounting $mp"
			umount -R "$mp" 2>/dev/null || umount -Rl "$mp" 2>/dev/null || true
		done < <(findmnt -rn -o TARGET -S "$dev" 2>/dev/null | sort -r || true)
		swapoff "$dev" 2>/dev/null || true
	done < <(lsblk -lnpo NAME "$disk" | tac)
	# Close LUKS / LVM mappings stacked on it.
	while read -r dev type; do
		case $type in
			crypt)
				echo "Closing $dev"
				cryptsetup close "$dev" 2>/dev/null || dmsetup remove "$dev" 2>/dev/null || true
				;;
			lvm)
				echo "Removing $dev"
				dmsetup remove "$dev" 2>/dev/null || true
				;;
		esac
	done < <(lsblk -lnpo NAME,TYPE "$disk" | tac)
}

wait_for_partitions() {
	local p _
	partprobe "$DISK" 2>/dev/null || partx -u "$DISK" 2>/dev/null || blockdev --rereadpt "$DISK" 2>/dev/null || true
	udevadm settle 2>/dev/null || true
	for p in "${ALL_PARTS[@]}"; do
		for _ in $(seq 1 30); do
			[[ -b $p ]] && break
			sleep 0.5
		done
		if [[ ! -b $p ]]; then
			echo "Partition $p did not appear." >&2
			return 1
		fi
	done
}

step_partition() {
	local p
	echo "Releasing $DISK ..."
	release_disk "$DISK"
	if mountpoint -q "$TARGET"; then
		umount -R "$TARGET" 2>/dev/null || umount -Rl "$TARGET"
	fi

	echo "Removing old signatures ..."
	while read -r p; do
		[[ $p == "$DISK" ]] && continue
		wipefs -af "$p" >/dev/null 2>&1 || true
	done < <(lsblk -lnpo NAME "$DISK")
	wipefs -af "$DISK"

	echo "Partition script:"
	sfdisk_script | sed 's/^/    /'
	sfdisk_script | sfdisk --wipe always --wipe-partitions always "$DISK"
	wait_for_partitions

	if [[ $FIRMWARE == bios ]] && command -v parted >/dev/null; then
		# Some old BIOSes only boot GPT disks whose protective MBR is "active".
		parted -s "$DISK" disk_set pmbr_boot on || true
	fi
	echo
	lsblk -o NAME,SIZE,TYPE,PARTTYPENAME,PARTLABEL "$DISK" || lsblk "$DISK"
}

step_encrypt() {
	local -a fmt=(--batch-mode --type "$ENC")
	if [[ $ENC == luks2 ]]; then
		if grub_unlocks; then fmt+=(--pbkdf pbkdf2); else fmt+=(--pbkdf argon2id); fi
	fi
	echo "Creating $(enc_desc) container on $ROOT_PART ..."
	printf '%s' "$LUKS_PASS" | cryptsetup luksFormat "${fmt[@]}" --key-file=- "$ROOT_PART"
	echo "Opening it as /dev/mapper/$CRYPT_NAME ..."
	printf '%s' "$LUKS_PASS" | cryptsetup open --key-file=- "$ROOT_PART" "$CRYPT_NAME"
	cryptsetup luksDump "$ROOT_PART" | grep -E '^(Version|Cipher|PBKDF|Hash)|^[[:space:]]+(PBKDF|Cipher):' || true
}

mount_target() {
	local rootdev e sv mp
	rootdev=$(root_device)
	mkdir -p "$TARGET"
	if zfs_on; then
		: # the pool's datasets are mounted under $TARGET by zfs_create_pool
	elif [[ $FS == btrfs ]]; then
		mount -o "$BTRFS_OPTS,subvol=@" "$rootdev" "$TARGET"
		for e in "${BTRFS_SUBVOLS[@]:1}"; do
			sv=${e%%:*}
			mp=${e#*:}
			mkdir -p "$TARGET$mp"
			mount -o "$BTRFS_OPTS,subvol=$sv" "$rootdev" "$TARGET$mp"
		done
		if [[ $SWAP == file ]]; then
			mkdir -p "$TARGET/swap"
			mount -o "noatime,subvol=@swap" "$rootdev" "$TARGET/swap"
		fi
	else
		mount -o noatime "$rootdev" "$TARGET"
	fi
	if [[ -n $BOOT_PART ]]; then
		mkdir -p "$TARGET/boot"
		if [[ $BOOT_FS == vfat ]]; then
			mount -o umask=0077 "$BOOT_PART" "$TARGET/boot"
		else
			mount -o noatime "$BOOT_PART" "$TARGET/boot"
		fi
	fi
	if [[ -n $ESP_PART ]]; then
		mkdir -p "$TARGET$ESP_MOUNT"
		mount -o umask=0077 "$ESP_PART" "$TARGET$ESP_MOUNT"
	fi
}

make_swapfile() {
	local f
	f="$TARGET$(swapfile_path)"
	echo "Creating a ${SWAP_SIZE} GiB swap file at $(swapfile_path) ..."
	if [[ $FS == btrfs ]]; then
		btrfs filesystem mkswapfile --size "${SWAP_SIZE}g" "$f"
	else
		dd if=/dev/zero of="$f" bs=1M count=$((SWAP_SIZE * 1024)) status=none
		chmod 600 "$f"
		mkswap "$f"
	fi
	chmod 600 "$f"
}

step_filesystems() {
	local rootdev e
	rootdev=$(root_device)
	case $FS in
		ext4)
			mkfs.ext4 -F -L arch "$rootdev"
			;;
		btrfs)
			mkfs.btrfs -f -L arch "$rootdev"
			mkdir -p "$TARGET"
			mount "$rootdev" "$TARGET"
			for e in "${BTRFS_SUBVOLS[@]}"; do
				btrfs subvolume create "$TARGET/${e%%:*}"
			done
			if [[ $SWAP == file ]]; then btrfs subvolume create "$TARGET/@swap"; fi
			umount "$TARGET"
			;;
		zfs) zfs_create_pool ;;
	esac
	if [[ -n $ESP_PART ]]; then mkfs.vfat -F 32 -n EFI "$ESP_PART"; fi
	if [[ -n $BOOT_PART ]]; then
		case $BOOT_FS in
			vfat) mkfs.vfat -F 32 -n BOOT "$BOOT_PART" ;;
			ext2) mkfs.ext2 -F -L boot "$BOOT_PART" ;;
			*) mkfs.ext4 -F -L boot "$BOOT_PART" ;;
		esac
	fi

	echo "Mounting the new filesystems under $TARGET ..."
	mount_target
	if [[ $SWAP == file ]] && ! zfs_on; then make_swapfile; fi
	findmnt -R "$TARGET" || true
}

mount_chroot_fs() {
	local d
	if [[ $FIRMWARE == uefi && -d /sys/firmware/efi/efivars ]] && ! mountpoint -q /sys/firmware/efi/efivars; then
		mount -t efivarfs efivarfs /sys/firmware/efi/efivars || true
	fi
	for d in dev proc sys; do
		mkdir -p "$TARGET/$d"
		if ! mountpoint -q "$TARGET/$d"; then
			mount --rbind "/$d" "$TARGET/$d"
			mount --make-rslave "$TARGET/$d"
		fi
	done
	# A private /run, so package scripts cannot touch the live system's services.
	mkdir -p "$TARGET/run"
	if ! mountpoint -q "$TARGET/run"; then
		mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$TARGET/run"
		if [[ -d /run/udev ]]; then
			mkdir -p "$TARGET/run/udev"
			mount --bind /run/udev "$TARGET/run/udev"
		fi
	fi
}

# The init itself: Artix's package names.
init_base_pkg() { if [[ $INIT == s6 ]]; then echo s6-base; else echo "$INIT"; fi; }

base_packages() {
	local k v
	printf '%s\n' base "$(init_base_pkg)" "elogind-$INIT" linux-firmware mkinitcpio sudo nano less man-db man-pages \
		bash-completion dosfstools e2fsprogs
	for k in $KERNELS; do echo "$k"; done
	v=$(cpu_vendor)
	if [[ $v == intel || $v == amd ]]; then echo "$v-ucode"; fi
	if [[ $FS == btrfs ]]; then echo btrfs-progs; fi
	if encrypted; then echo cryptsetup; fi
}

# The initramfs: busybox-based hooks (Artix has no systemd hooks). The encrypt
# hook asks for the passphrase (cryptdevice= on the kernel command line).
write_mkinitcpio_conf() { # write_mkinitcpio_conf [early]
	local hooks="base udev autodetect microcode modconf kms keyboard keymap consolefont block"
	if encrypted; then hooks+=" encrypt"; fi
	if zfs_on; then
		# "early": zfs-utils (the zfs hook) is installed after basestrap.
		if [[ ${1:-} != early ]]; then hooks+=" zfs"; fi
		hooks+=" filesystems"
	else
		hooks+=" filesystems fsck"
	fi
	# The NVIDIA driver must not compete with nouveau in early boot.
	if [[ -n $(nvidia_driver) ]]; then hooks=${hooks/ kms/}; fi
	mkdir -p "$TARGET/etc/mkinitcpio.conf.d"
	{
		echo "# Written by artix-install.sh"
		echo "HOOKS=($hooks)"
		# "early": before basestrap, when the key file does not exist yet.
		if needs_keyfile && [[ ${1:-} != early ]]; then echo "FILES=(/etc/cryptsetup-keys.d/$CRYPT_NAME.key)"; fi
	} >"$TARGET/etc/mkinitcpio.conf.d/10-artix-install.conf"
	echo "mkinitcpio hooks: $hooks"
}

# Only the default image per kernel: the fallback images would fill /boot with
# several kernels.
trim_mkinitcpio_presets() {
	local k p
	for k in $KERNELS; do
		p="$TARGET/etc/mkinitcpio.d/$k.preset"
		[[ -f $p ]] || continue
		sed -i -E "s/^PRESETS=.*/PRESETS=('default')/" "$p"
		rm -f "$TARGET/boot/initramfs-$k-fallback.img"
	done
}

step_bootstrap() {
	local -a pkgs
	mapfile -t pkgs < <(base_packages)
	# Read by mkinitcpio's keymap hook when basestrap installs the kernels.
	mkdir -p "$TARGET/etc"
	printf 'KEYMAP=%s\n' "$KEYMAP" >"$TARGET/etc/vconsole.conf"
	write_mkinitcpio_conf early
	echo "Init: $(lbl_init). Packages: ${pkgs[*]}"
	# basestrap copies the live system's keyring and mirror list.
	stdbuf -oL basestrap "$TARGET" "${pkgs[@]}"
	if multilib_on || [[ -n $(nvidia_driver) ]]; then enable_multilib "$TARGET/etc/pacman.conf"; fi
	sed -i -e 's/^#Color/Color/' -e 's/^#ParallelDownloads.*/ParallelDownloads = 5/' "$TARGET/etc/pacman.conf"
	trim_mkinitcpio_presets
	mount_chroot_fs
	rm -f "$TARGET/etc/resolv.conf"
	cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf" || true
	in_target pacman -Sy
	arch_repos_setup target
	if zfs_on; then zfs_target_setup; fi
}

set_locale() {
	local f="$TARGET/etc/locale.gen"
	if [[ ! -f $f ]]; then
		warn "$f not found; locale not configured."
		return 0
	fi
	awk -v loc="$LOCALE" '
		{ s = $0; sub(/^#/, "", s); split(s, a, /[ \t]+/) }
		(a[1] == loc || a[1] == "en_US.UTF-8") && a[2] == "UTF-8" { print s; next }
		{ print }' "$f" >"$f.new"
	mv "$f.new" "$f"
	if ! grep -q "^$LOCALE UTF-8" "$f"; then echo "$LOCALE UTF-8" >>"$f"; fi
	printf 'LANG=%s\n' "$LOCALE" >"$TARGET/etc/locale.conf"
	in_target locale-gen
}

write_fstab() {
	local fs_uuid boot_uuid="" esp_uuid="" e sv mp
	if ! zfs_on; then fs_uuid=$(get_uuid "$(root_device)"); fi
	if [[ -n $BOOT_PART ]]; then boot_uuid=$(get_uuid "$BOOT_PART"); fi
	if [[ -n $ESP_PART ]]; then esp_uuid=$(get_uuid "$ESP_PART"); fi
	{
		echo "# /etc/fstab - generated by artix-install.sh"
		echo "# <device>                                 <dir>             <type> <options>                         <dump> <pass>"
		if zfs_on; then
			echo "# / is $ZFS_BE, mounted by the initramfs (ZFSBootMenu passes root=zfs:...)."
			for e in "${ZFS_LEGACY[@]}"; do
				printf '%-30s %-22s  zfs    defaults,noatime  0 0\n' "$ZPOOL/${e%%:*}" "${e#*:}"
			done
		elif [[ $FS == btrfs ]]; then
			for e in "${BTRFS_SUBVOLS[@]}"; do
				sv=${e%%:*}
				mp=${e#*:}
				printf 'UUID=%s  %-22s  btrfs  %s,subvol=/%s  0 0\n' "$fs_uuid" "$mp" "$BTRFS_OPTS" "$sv"
			done
			if [[ $SWAP == file ]]; then
				printf 'UUID=%s  %-22s  btrfs  noatime,subvol=/@swap  0 0\n' "$fs_uuid" "/swap"
			fi
		else
			printf 'UUID=%s  %-22s  ext4   defaults,noatime  0 1\n' "$fs_uuid" "/"
		fi
		if [[ -n $BOOT_PART ]]; then
			case $BOOT_FS in
				vfat) printf 'UUID=%s  %-22s  vfat   defaults,noatime,umask=0077  0 2\n' "$boot_uuid" "/boot" ;;
				ext2) printf 'UUID=%s  %-22s  ext2   defaults,noatime  0 2\n' "$boot_uuid" "/boot" ;;
				*) printf 'UUID=%s  %-22s  ext4   defaults,noatime  0 2\n' "$boot_uuid" "/boot" ;;
			esac
		fi
		if [[ -n $ESP_PART ]]; then
			printf 'UUID=%s  %-22s  vfat   defaults,noatime,umask=0077  0 2\n' "$esp_uuid" "$ESP_MOUNT"
		fi
		if [[ $SWAP == file ]] && ! zfs_on; then
			printf '%s  none  swap  defaults  0 0\n' "$(swapfile_path)"
		fi
	} >"$TARGET/etc/fstab"
	echo "--- /etc/fstab ---"
	cat "$TARGET/etc/fstab"
}

setup_crypt_target() {
	local kf="/etc/cryptsetup-keys.d/$CRYPT_NAME.key"
	if needs_keyfile; then
		# GRUB (or ZFSBootMenu) already asked for the passphrase; a key file inside
		# the initramfs, which lies on the encrypted disk, unlocks root a second
		# time without asking again; the encrypt hook is told by cryptkey=.
		echo "Adding a key file for the initramfs ..."
		mkdir -p "$TARGET/etc/cryptsetup-keys.d"
		chmod 700 "$TARGET/etc/cryptsetup-keys.d"
		(umask 077 && head -c 64 /dev/urandom >"$TARGET$kf")
		local -a kopts=(--batch-mode --pbkdf-force-iterations 1000)
		if [[ $ENC == luks2 ]]; then kopts+=(--pbkdf pbkdf2); fi
		printf '%s' "$LUKS_PASS" | cryptsetup luksAddKey "${kopts[@]}" --key-file=- "$ROOT_PART" "$TARGET$kf"
		chmod 400 "$TARGET$kf"
		# The initramfs holds the key: only root may read it.
		mkdir -p "$TARGET/etc/pacman.d/hooks"
		cat >"$TARGET/etc/pacman.d/hooks/91-initramfs-permissions.hook" <<'EOF'
# artix-install.sh: the initramfs contains the disk key file; keep it root-only.
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/modules/*/vmlinuz
Target = usr/lib/initcpio/*
Target = usr/lib/firmware/*

[Action]
Description = Restricting initramfs permissions...
When = PostTransaction
Exec = /bin/sh -c 'chmod 600 /boot/initramfs-*.img 2>/dev/null; true'
EOF
	fi
	# The kernel command line names the volume (rd.luks.name); no crypttab entry
	# for root, so nothing asks a second time after the switch to the real root.
}


# =============================================================================
#  ZFS (archzfs repository, ZFSBootMenu)
# =============================================================================
# The archzfs release key: from the project's keyring repository at a pinned
# commit, else from a keyserver by its full fingerprint. Either way the
# fingerprint is checked before pacman is told to trust it.
archzfs_keyfile() { # archzfs_keyfile <output file>
	local out=$1 g f fpr
	g=$(mktemp -d) || return 1
	for f in "$ARCHZFS_KEY.asc" "uid/$ARCHZFS_UID/$ARCHZFS_UID.asc" "uid/$ARCHZFS_UID/certification/$ARCHZFS_KEY.asc"; do
		curl -fsSL --retry 3 "$ARCHZFS_KEYRING/$ARCHZFS_KEY/$f" -o "$g/part.asc" || break
		gpg --homedir "$g" --dearmor <"$g/part.asc" >>"$g/key.gpg" || break
	done
	if [[ -s $g/key.gpg ]] && gpg --homedir "$g" --batch --quiet --import "$g/key.gpg" 2>/dev/null; then
		fpr=$(gpg --homedir "$g" --with-colons --list-keys 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
	fi
	if [[ ${fpr:-} != "$ARCHZFS_KEY" ]]; then
		echo "Keyring repository not usable; asking a keyserver for $ARCHZFS_KEY ..."
		rm -f "$g/key.gpg"
		gpg --homedir "$g" --batch --quiet --keyserver hkps://keyserver.ubuntu.com --recv-keys "$ARCHZFS_KEY" 2>/dev/null ||
			gpg --homedir "$g" --batch --quiet --keyserver hkps://keys.openpgp.org --recv-keys "$ARCHZFS_KEY" 2>/dev/null || true
		fpr=$(gpg --homedir "$g" --with-colons --list-keys 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
		gpg --homedir "$g" --batch --export "$ARCHZFS_KEY" >"$g/key.gpg" 2>/dev/null || true
	fi
	if [[ ${fpr:-} != "$ARCHZFS_KEY" || ! -s $g/key.gpg ]]; then
		echo "Could not get the archzfs signing key ($ARCHZFS_KEY)." >&2
		rm -rf "$g"
		return 1
	fi
	cp "$g/key.gpg" "$out" || return 1
	rm -rf "$g"
	echo "archzfs key $ARCHZFS_KEY: fingerprint checked."
}

archzfs_repo() { # archzfs_repo <pacman.conf>
	grep -q '^\[archzfs\]' "$1" && return 0
	printf '\n# ZFS for Arch Linux (added by artix-install.sh), signed by %s\n[archzfs]\nSigLevel = Required\nServer = %s\n' \
		"$ARCHZFS_KEY" "$ARCHZFS_SERVER" >>"$1"
}

# "6.18.63-3-lts" -> "6.18.63-3"; "7.2.15-arch1-1" -> "7.2.15.arch1-1"
kernel_pkgver() {
	local r=$1
	case $r in
		*-lts | *-zen | *-hardened) r=${r%-*} ;;
	esac
	if [[ $r =~ ^([0-9.]+)-([a-z]+[0-9]+)-([0-9]+)$ ]]; then
		echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
	else
		echo "$r"
	fi
}

# The linux=<version> a zfs-<kernel> package was built for (from "pacman -Si").
zfs_built_for() { # zfs_built_for <kernel> <"pacman -Si" output>
	awk -v k="$1" '
		/^Depends On/ { on = 1 }
		on && /^[A-Z][A-Za-z ]+:/ && !/^Depends On/ { on = 0 }
		on { for (i = 1; i <= NF; i++) if (index($i, k "=") == 1) { print substr($i, length(k) + 2); exit } }' <<<"$2"
}

# ZFS on the live ISO: the prebuilt module when it matches the running kernel,
# otherwise zfs-dkms with that kernel's headers from the Arch Linux Archive.
zfs_live_setup() {
	local kver pver info built hdr
	if command -v zpool >/dev/null && modprobe zfs 2>/dev/null; then
		echo "ZFS is already available on the live system."
		return 0
	fi
	echo "Adding the archzfs repository to the live system ..."
	archzfs_keyfile /tmp/archzfs.gpg || return 1
	pacman-key --add /tmp/archzfs.gpg || return 1
	pacman-key --lsign-key "$ARCHZFS_KEY" || return 1
	# Only for the live system: basestrap uses this file, and the new system gets
	# the repository on its own (zfs_target_setup).
	cp /etc/pacman.conf /tmp/pacman.conf.before-archzfs || return 1
	archzfs_repo /etc/pacman.conf || return 1
	pacman -Sy || return 1
	kver=$(uname -r)
	pver=$(kernel_pkgver "$kver")
	info=$(pacman -Si archzfs/zfs-linux 2>/dev/null) || info=""
	built=$(zfs_built_for linux "$info")
	echo "Live kernel: $kver (package $pver); archzfs zfs-linux is built for linux ${built:-?}."
	if [[ -n $built && $built == "$pver" ]] && pacman -S --needed --noconfirm zfs-utils zfs-linux; then
		:
	else
		echo "No prebuilt module for this kernel: building zfs-dkms (a few minutes) ..."
		# The live system's writable space is a RAM disk; the compiler needs room.
		local c
		for c in /run/artix/cowspace /run/*/cowspace; do
			mount -o remount,size=75% "$c" 2>/dev/null && break
		done
		# Artix keeps no archive of old packages: the repository's headers must
		# match the ISO's kernel.
		hdr=$(pacman -Si linux-headers 2>/dev/null | awk -F': ' '/^Version/ { print $2; exit }') || hdr=""
		if [[ $hdr != "$pver" ]]; then
			echo "The live kernel is $pver, but Artix's linux-headers are ${hdr:-missing}: the ZFS module cannot be built for this ISO. Download the newest Artix ISO." >&2
			return 1
		fi
		pacman -S --needed --noconfirm linux-headers || return 1
		pacman -S --needed --noconfirm zfs-utils zfs-dkms || return 1
	fi
	cp /tmp/pacman.conf.before-archzfs /etc/pacman.conf || return 1
	modprobe zfs || {
		echo "The ZFS module does not load on the live kernel $kver. Use the newest Artix ISO." >&2
		return 1
	}
	echo "ZFS $(cat /sys/module/zfs/version 2>/dev/null) is loaded."
}

# Pools left imported by an earlier attempt that sit on this disk.
zfs_release_disk() {
	command -v zpool >/dev/null || return 0
	local pool st
	while read -r pool; do
		[[ -n $pool ]] || continue
		st=$(zpool status -P "$pool" 2>/dev/null) || continue
		if grep -q -e "$1" -e "/dev/mapper/$CRYPT_NAME" -e /dev/disk/by-partuuid <<<"$st"; then
			echo "Exporting ZFS pool $pool"
			zpool export -f "$pool" 2>/dev/null || true
		fi
	done < <(zpool list -H -o name 2>/dev/null || true)
}

zfs_vdev() {
	if encrypted; then
		echo "/dev/mapper/$CRYPT_NAME"
	else
		local u
		u=$(partuuid_of "$ROOT_PART")
		if [[ -n $u && -e /dev/disk/by-partuuid/$u ]]; then echo "/dev/disk/by-partuuid/$u"; else echo "$ROOT_PART"; fi
	fi
}

# Pool and datasets. The boot environment zroot/ROOT/artix holds / and /boot,
# so a snapshot of it holds the kernels too; /home and the logs are separate.
# Those are "legacy" datasets mounted from /etc/fstab, so every init mounts
# them with its usual local-filesystem step (no ZFS start scripts needed).
ZFS_LEGACY=("home:/home" "var/log:/var/log" "var/cache/pacman:/var/cache/pacman")
zfs_create_pool() {
	local dev
	dev=$(zfs_vdev)
	# The same host id on the live system and the new one: the pool imports cleanly.
	zgenhostid -f
	echo "Creating ZFS pool $ZPOOL on $dev ..."
	zpool create -f -o ashift=12 -o autotrim=on \
		-O compression=lz4 -O acltype=posixacl -O xattr=sa -O relatime=on -O dnodesize=auto \
		-O normalization=formD -O mountpoint=none -O canmount=off \
		-R "$TARGET" "$ZPOOL" "$dev"
	zfs create -o mountpoint=none "$ZPOOL/ROOT"
	zfs create -o mountpoint=/ -o canmount=noauto "$ZFS_BE"
	zfs mount "$ZFS_BE"
	zfs create -o canmount=off -o mountpoint=none "$ZPOOL/var"
	zfs create -o canmount=off -o mountpoint=none "$ZPOOL/var/cache"
	local e ds mp
	for e in "${ZFS_LEGACY[@]}"; do
		ds=${e%%:*} mp=${e#*:}
		zfs create -o mountpoint=legacy "$ZPOOL/$ds"
		mkdir -p "$TARGET$mp"
		mount -t zfs "$ZPOOL/$ds" "$TARGET$mp"
	done
	zpool set bootfs="$ZFS_BE" "$ZPOOL"
	mkdir -p /etc/zfs
	zpool set cachefile=/etc/zfs/zpool.cache "$ZPOOL"
	zfs list -o name,mountpoint,canmount -r "$ZPOOL"
}

# The new system: the archzfs repository and key, the host id, the module for
# every kernel (prebuilt when archzfs has the installed kernel's version, else
# zfs-dkms), and the services that import and mount the pool.
zfs_target_setup() {
	local k info built have dkms=0
	local -a pkgs=(zfs-utils)
	archzfs_keyfile "$TARGET/root/archzfs.gpg"
	in_target pacman-key --add /root/archzfs.gpg
	in_target pacman-key --lsign-key "$ARCHZFS_KEY"
	rm -f "$TARGET/root/archzfs.gpg"
	archzfs_repo "$TARGET/etc/pacman.conf"
	in_target pacman -Sy
	cp /etc/hostid "$TARGET/etc/hostid"
	mkdir -p "$TARGET/etc/zfs"
	cp /etc/zfs/zpool.cache "$TARGET/etc/zfs/zpool.cache"
	for k in $KERNELS; do
		have=$(in_target pacman -Q "$k" | awk '{ print $2 }')
		info=$(in_target pacman -Si "archzfs/zfs-$k" 2>/dev/null) || info=""
		built=$(zfs_built_for "$k" "$info")
		if [[ -n $built && $built == "$have" ]]; then
			echo "$k $have: prebuilt module zfs-$k."
			pkgs+=("zfs-$k")
		else
			echo "$k $have: archzfs has zfs-$k for ${built:-no version}; using zfs-dkms."
			dkms=1
		fi
	done
	if ((dkms)); then
		pkgs=(zfs-utils zfs-dkms)
		for k in $KERNELS; do pkgs+=("$k-headers"); done
	fi
	echo "Installing ${pkgs[*]} ..."
	in_target pacman -S --needed --noconfirm "${pkgs[@]}"
	# The initramfs imports the pool and mounts /; fstab mounts the rest.
}

zfs_snapshot_hook() { # zfs_snapshot_hook <root dir>
	local root=$1
	mkdir -p "$root/usr/local/bin" "$root/etc/pacman.d/hooks"
	cat >"$root/usr/local/bin/zfs-pacman-snapshot" <<'EOF'
#!/bin/bash
# artix-install.sh: snapshot the running boot environment before pacman changes
# it, and keep the newest KEEP of these snapshots. ZFSBootMenu can boot any of
# them (select the boot environment, then Ctrl-S).
KEEP=10
[[ $(findmnt -no FSTYPE /) == zfs ]] || exit 0
be=$(findmnt -no SOURCE /) || exit 0
zfs snapshot "$be@pacman-$(date +%Y%m%d-%H%M%S)" || exit 0
zfs list -H -t snapshot -o name -s creation -d 1 "$be" 2>/dev/null | grep -F "$be@pacman-" |
	head -n -"$KEEP" | while read -r s; do zfs destroy "$s" || true; done
exit 0
EOF
	chmod 755 "$root/usr/local/bin/zfs-pacman-snapshot"
	cat >"$root/etc/pacman.d/hooks/05-zfs-snapshot.hook" <<'EOF'
# artix-install.sh: a ZFS snapshot of the system before every pacman transaction
[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Operation = Remove
Target = *

[Action]
Description = Taking a ZFS snapshot of the system...
When = PreTransaction
Exec = /usr/local/bin/zfs-pacman-snapshot
EOF
}

# Set a password. The password travels on stdin only: never in a command line,
# never in the log. Arch hashes it with yescrypt (login.defs).
set_password() { # set_password <user> <password>
	printf '%s:%s\n' "$1" "$2" | in_target chpasswd
	if ! awk -F: -v u="$1" '$1 == u && $2 ~ /^\$[^$]+\$/ { ok = 1 } END { exit !ok }' "$TARGET/etc/shadow"; then
		echo "The password of '$1' was not stored in /etc/shadow." >&2
		return 1
	fi
	echo "Password set for '$1'."
}

setup_users() {
	local base="" g u groups shell=/bin/bash
	for g in audio video input storage users plugdev; do
		if grep -q "^${g}:" "$TARGET/etc/group"; then base+="${base:+,}$g"; fi
	done
	for u in "${USERS[@]}"; do
		groups=$base
		if [[ ${U_SUDO[$u]} != none ]]; then groups="wheel,$groups"; fi
		if grep -q "^${u}:" "$TARGET/etc/passwd"; then
			in_target usermod -a -G "$groups" "$u"
			if [[ -n ${U_FULL[$u]} ]]; then in_target usermod -c "${U_FULL[$u]}" "$u"; fi
		else
			in_target useradd -m -s "$shell" -G "$groups" -c "${U_FULL[$u]}" "$u"
		fi
		set_password "$u" "${U_PASS[$u]}"
		mkdir -p "$TARGET/etc/sudoers.d"
		if [[ ${U_SUDO[$u]} == nopasswd ]]; then
			printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$u" >"$TARGET/etc/sudoers.d/20-nopasswd-$u"
			chmod 440 "$TARGET/etc/sudoers.d/20-nopasswd-$u"
		else
			rm -f "$TARGET/etc/sudoers.d/20-nopasswd-$u"
		fi
		echo "User '$u': groups $groups, $(sudo_word "$u")."
	done
	if [[ -n $ROOT_PASS ]]; then
		set_password root "$ROOT_PASS"
	fi
	mkdir -p "$TARGET/etc/sudoers.d"
	if [[ ! -e $TARGET/etc/sudoers.d/10-wheel ]]; then
		printf '%%wheel ALL=(ALL:ALL) ALL\n' >"$TARGET/etc/sudoers.d/10-wheel"
		chmod 440 "$TARGET/etc/sudoers.d/10-wheel"
	fi
	if [[ $BS_POWER == 1 ]]; then
		cat >"$TARGET/etc/sudoers.d/30-wheel-power" <<'EOF'
# artix-install.sh (LARBS-style): wheel may run these without a password
%wheel ALL=(ALL:ALL) NOPASSWD: /usr/bin/shutdown,/usr/bin/reboot,/usr/bin/poweroff,/usr/bin/halt,/usr/bin/loginctl suspend,/usr/bin/mount,/usr/bin/umount,/usr/bin/pacman -Syu,/usr/bin/pacman -Syyu,/usr/bin/pacman -Syu --noconfirm
EOF
		chmod 440 "$TARGET/etc/sudoers.d/30-wheel-power"
	fi
	in_target visudo -c
}

step_configure() {
	echo "Hostname, keymap, timezone ..."
	echo "$HOST_NAME" >"$TARGET/etc/hostname"
	if [[ $INIT == openrc ]]; then
		mkdir -p "$TARGET/etc/conf.d"
		printf 'hostname="%s"\n' "$HOST_NAME" >"$TARGET/etc/conf.d/hostname"
		printf 'keymap="%s"\n' "$KEYMAP" >"$TARGET/etc/conf.d/keymaps"
	fi
	cat >"$TARGET/etc/hosts" <<EOF
127.0.0.1	localhost
::1		localhost
127.0.1.1	$HOST_NAME
EOF
	printf 'KEYMAP=%s\n' "$KEYMAP" >"$TARGET/etc/vconsole.conf"
	ln -sfn "/usr/share/zoneinfo/$TIMEZONE" "$TARGET/etc/localtime"
	in_target hwclock --systohc 2>/dev/null || true

	echo "Locale $LOCALE ..."
	set_locale

	write_fstab
	write_mkinitcpio_conf
	if encrypted; then setup_crypt_target; fi
	setup_users
}

target_packages() {
	case $BOOTLOADER in
		grub)
			printf '%s\n' grub
			if [[ $FIRMWARE == uefi ]]; then echo efibootmgr; fi
			if snapper_on; then printf '%s\n' grub-btrfs inotify-tools; fi
			;;
		limine)
			echo limine
			if [[ $FIRMWARE == uefi ]]; then echo efibootmgr; fi
			;;
		refind | efistub) echo efibootmgr ;;
		syslinux) echo syslinux ;;
		zfsbootmenu)
			# ZFSBootMenu's own dependencies (objcopy is in binutils)
			printf '%s\n' efibootmgr kexec-tools fzf mbuffer perl perl-sort-versions perl-boolean perl-yaml-pp \
				openssl ncurses
			;;
	esac
	if [[ $BOOTLOADER == refind ]]; then echo refind; fi
	if secureboot_on; then echo sbctl; fi
	if snapper_on; then printf '%s\n' snapper snap-pac; fi
	case $NET in
		nm) echo networkmanager ;;
		connman) echo connman ;;
		dhcpcd) printf '%s\n' dhcpcd iwd ;;
	esac
	echo cronie
	echo git
	desktop_packages
}

link_in_target() { # link_in_target <existing file> <link path>   (paths inside the target)
	if [[ -e $TARGET$1 ]]; then
		ln -sfn "$1" "$TARGET$2"
	else
		warn "$1 not found in the new system; skipped."
	fi
}

# Console keymap -> X11 keyboard layout ("layout" or "layout variant")
xkb_layout_of() {
	local k=${1%.map.gz}
	case $k in
		us | us-acentos) echo us ;;
		uk | gb) echo gb ;;
		dvorak | dvorak-*) echo "us dvorak" ;;
		colemak) echo "us colemak" ;;
		de-latin1-nodeadkeys) echo "de nodeadkeys" ;;
		de | de-latin1 | de_CH-latin1) [[ $k == de_CH* ]] && echo ch || echo de ;;
		sg | sg-latin1 | ch-de) echo ch ;;
		fr_CH | fr_CH-latin1 | ch-fr) echo "ch fr" ;;
		fr | fr-latin1 | fr-latin9 | fr-pc) echo fr ;;
		be-latin1 | be) echo be ;;
		br-abnt2 | br-abnt) echo br ;;
		la-latin1) echo latam ;;
		es | es-cp850) echo es ;;
		pt-latin1 | pt-latin9 | pt) echo pt ;;
		it | it2 | it-ibm) echo it ;;
		se-lat6 | se-latin1 | sv-latin1) echo se ;;
		no | no-latin1) echo no ;;
		dk | dk-latin1) echo dk ;;
		'fi') echo 'fi' ;;
		pl | pl2) echo pl ;;
		cz | cz-qwertz | cz-lat2) echo cz ;;
		cz-us-qwertz) echo "cz qwerty" ;;
		sk-qwertz) echo sk ;;
		hu) echo hu ;;
		ru | ruwin_*) echo ru ;;
		ua | ua-utf) echo ua ;;
		jp106) echo jp ;;
		tr_q-latin5 | trq) echo tr ;;
		*) k=${k%%[-_]*}; echo "${k%%[0-9]*}" ;;
	esac
}

# Make graphical logins use the same keyboard layout as the console, so
# passwords type the same everywhere.
write_x_keyboard() {
	local lv layout variant=""
	[[ $KEYMAP == us ]] && return 0
	lv=$(xkb_layout_of "$KEYMAP")
	layout=${lv%% *}
	if [[ $lv == *" "* ]]; then variant=${lv#* }; fi
	if [[ -z $layout ]]; then
		warn "Could not map keymap '$KEYMAP' to an X11 layout; the graphical login uses a US layout."
		return 0
	fi
	if [[ ! -d $TARGET/usr/share/X11/xkb/symbols ]] || [[ ! -e $TARGET/usr/share/X11/xkb/symbols/$layout ]]; then
		warn "X11 has no keyboard layout '$layout' (from keymap '$KEYMAP'); the graphical login uses a US layout. Set it in /etc/X11/xorg.conf.d/00-keyboard.conf (XkbLayout)."
		return 0
	fi
	mkdir -p "$TARGET/etc/X11/xorg.conf.d"
	{
		echo "# Written by artix-install.sh from the console keymap '$KEYMAP'"
		echo 'Section "InputClass"'
		echo '	Identifier "system-keyboard"'
		echo '	MatchIsKeyboard "on"'
		echo "	Option \"XkbLayout\" \"$layout\""
		if [[ -n $variant ]]; then echo "	Option \"XkbVariant\" \"$variant\""; fi
		echo 'EndSection'
	} >"$TARGET/etc/X11/xorg.conf.d/00-keyboard.conf"
	echo "X11 keyboard layout: $layout${variant:+ ($variant)} (from keymap $KEYMAP)"
}

# The keyboard layout for graphical logins (PipeWire and D-Bus: finish_desktop).
configure_desktop() {
	desktop_on || return 0
	write_x_keyboard
}

gpu_packages() {
	local g list
	list=$(gpu_list)
	[[ -n $list ]] || return 0
	printf '%s\n' mesa vulkan-icd-loader
	for g in $list; do
		case $g in
			intel) printf '%s\n' vulkan-intel intel-media-driver ;;
			amd) echo vulkan-radeon ;;
			nouveau) echo vulkan-nouveau ;;
			nvidia) printf '%s\n' nvidia-open-dkms nvidia-utils; kernel_headers ;;
			nvidia580) printf '%s\n' nvidia-580xx-dkms nvidia-580xx-utils; kernel_headers ;;
			nvidia470) printf '%s\n' nvidia-470xx-dkms nvidia-470xx-utils; kernel_headers ;;
			vm)
				case $(vm_type) in
					virtualbox) echo virtualbox-guest-utils ;;
					vmware) echo open-vm-tools ;;
					qemu) printf '%s\n' spice-vdagent qemu-guest-agent ;;
				esac
				;;
		esac
	done
	if multilib_on; then
		printf '%s\n' lib32-mesa lib32-vulkan-icd-loader
		for g in $list; do
			case $g in
				intel) echo lib32-vulkan-intel ;;
				amd) echo lib32-vulkan-radeon ;;
				nouveau) echo lib32-vulkan-nouveau ;;
				nvidia) echo lib32-nvidia-utils ;;
				nvidia580) echo lib32-nvidia-580xx-utils ;;
				nvidia470) echo lib32-nvidia-470xx-utils ;;
			esac
		done
	fi
}

app_packages() {
	local a
	for a in $APPS; do
		case $a in
			libreoffice) echo libreoffice-fresh ;;
			obs) echo obs-studio ;;
			vlc) printf '%s\n' vlc vlc-plugins-all ;;
			*) echo "$a" ;;
		esac
	done
}

gaming_packages() {
	local g
	if multilib_on; then printf '%s\n' lib32-mesa lib32-vulkan-icd-loader lib32-pipewire; fi
	for g in $GAMING; do
		case $g in
			steam) echo steam ;;
			wine) printf '%s\n' wine wine-mono wine-gecko ;;
			gamemode)
				echo gamemode
				if multilib_on; then echo lib32-gamemode; fi
				;;
			winetricks | lutris) echo "$g" ;;
		esac
	done
}

# ---- peripherals --------------------------------------------------------------
# id|menu text (max 39 characters)|packages, official or AUR ("-": its own function)|needs a desktop
periph_table() {
	cat <<'EOF'
bluetooth|Bluetooth: bluez, Blueman (service)|bluez bluez-utils|0
solaar|Logitech: Solaar - pairing, battery|solaar|1
openlogi|Logitech: OpenLogi beta|-|1
logiops|Logitech: logiops, MX mice (service)|logiops|0
g810-led|Logitech: G keyboard lighting|g810-led|0
piper|Gaming mice: Piper (service)|piper|1
openlinkhub|Corsair: OpenLinkHub (service)|-|0
ckb-next|Corsair: ckb-next (service)|ckb-next|1
openrazer|Razer: OpenRazer, Polychromatic|openrazer-daemon openrazer-driver-dkms polychromatic|1
openrgb|RGB lighting, many brands: OpenRGB|openrgb i2c-tools|1
coolercontrol|Fans, pumps: CoolerControl (service)|coolercontrol|1
controllers|PlayStation/Switch/Steam/8BitDo pads|game-devices-udev|0
xone|Xbox dongle, USB pads: xone (driver)|xone-dkms|0
xpadneo|Xbox pads, Bluetooth: xpadneo (driver)|xpadneo-dkms bluez bluez-utils|0
sc-controller|Gamepad mapper: SC Controller|sc-controller|1
antimicrox|Gamepad to keys/mouse: AntiMicroX|antimicrox|1
oversteer|Steering wheels: Oversteer|oversteer|1
wacom|Drawing tablets: Wacom|xf86-input-wacom libwacom|0
input-remapper|Key/button remapper (service)|input-remapper|1
keyd|Key remapping daemon (service)|keyd|0
kanata|Key remapper: kanata|kanata|0
EOF
}
periph_field() { periph_table | awk -F'|' -v id="$1" -v f="$2" '$1 == id { print $f }'; }
periph_ids() { periph_table | cut -d'|' -f1; }
periph_gui() { local p; for p in $PERIPH; do [[ $(periph_field "$p" 4) == 1 ]] && return 0; done; return 1; }

# IDs that match what is plugged in (USB vendor:product) or built in (Bluetooth).
detect_periph() {
	local d v p ids="" usb=" "
	for d in /sys/bus/usb/devices/*; do
		[[ -r $d/idVendor && -r $d/idProduct ]] || continue
		v=$(<"$d/idVendor") p=$(<"$d/idProduct")
		usb+="$v:$p $v "
	done
	[[ $usb == *" 046d "* ]] && ids+=" solaar"
	[[ $usb == *" 1b1c "* ]] && ids+=" openlinkhub"
	[[ $usb == *" 1532 "* ]] && ids+=" openrazer"
	[[ $usb =~ \ (054c|057e|28de|2dc8)\  ]] && ids+=" controllers"
	[[ $usb =~ \ 045e:(02e6|02fe|02f9|091e|02ea|02dd|02e3|0b00|0b12|0b13)\  ]] && ids+=" xone"
	[[ $usb == *" 056a "* ]] && ids+=" wacom"
	compgen -G '/sys/class/bluetooth/hci*' >/dev/null && ids+=" bluetooth"
	trim "$ids"
}

PERIPH_ASKED=0
CORSAIR_HELP="Both drive the same Corsair USB devices, so only one can be installed.

\ZbOpenLinkHub\Zn (recommended): newer and actively developed. Covers the iCUE LINK hub with its fans and coolers, Commander Core / Core XT / Pro, most Corsair AIO coolers, many keyboards, mice and headsets, and DDR4/DDR5 memory lighting. Runs as a background service; you set it up in a web browser at http://127.0.0.1:27003. From the AUR with an AUR helper (updated with the system); otherwise built from a fixed release (0.9.4).

\Zbckb-next\Zn: keyboards and mice only (lighting, macros, remapping); no AIO coolers, fan hubs or iCUE LINK. A desktop app with a tray icon."

menu_periph() {
	local sel det cur c p
	local -a items=()
	det=$(detect_periph)
	cur=$PERIPH
	if ((PERIPH_ASKED == 0)) && [[ -z $cur ]]; then cur=$det; fi
	while IFS='|' read -r p c _ _; do items+=("$p" "$c"); done < <(periph_table)
	sel=$(checklist "Peripherals" "Detected now: \Zb${det:-nothing known}\Zn (ticked the first time). Tools that are not in the official repositories come from the AUR (needs an AUR helper). Pick ckb-next OR OpenLinkHub for Corsair." "$cur" "${items[@]}") || return 1
	PERIPH_ASKED=1
	if has "$sel" openlinkhub && has "$sel" ckb-next; then
		c=$(ui --title " Corsair: pick one " --default-item openlinkhub --menu "$CORSAIR_HELP" 22 78 2 \
			openlinkhub "AIOs, hubs, iCUE LINK, more (recommended)" \
			ckb-next "keyboards and mice") || return 1
		if [[ $c == openlinkhub ]]; then sel=$(without "$sel" ckb-next); else sel=$(without "$sel" openlinkhub); fi
	fi
	c=0
	for p in solaar openlogi logiops; do has "$sel" "$p" && c=$((c + 1)); done
	if ((c > 1)); then
		yesno "Solaar, OpenLogi and logiops each take over a Logitech device; only one can control a given mouse or receiver at a time. Keep all of them anyway?" "Logitech" 1 || return 1
	fi
	PERIPH=$sel
}

lbl_periph() { lbl_list "$PERIPH"; }

periph_packages() {
	local p f
	for p in $PERIPH; do
		f=$(periph_field "$p" 3)
		[[ $f == - ]] && continue
		tr ' ' '\n' <<<"$f"
		if [[ $p == bluetooth ]] && desktop_on; then echo blueman; fi
	done
}

periph_dkms() { has "$PERIPH" openrazer || has "$PERIPH" xone || has "$PERIPH" xpadneo; }

# "<base package>|<service name>|<command for a written service>"
periph_services() {
	local p
	for p in $PERIPH; do
		case $p in
			bluetooth | xpadneo) echo "bluez|bluetoothd|/usr/lib/bluetooth/bluetoothd" ;;
			logiops) echo "logiops|logid|/usr/bin/logid" ;;
			piper) echo "libratbag|ratbagd|/usr/bin/ratbagd" ;;
			ckb-next) echo "ckb-next|ckb-next-daemon|/usr/bin/ckb-next-daemon" ;;
			coolercontrol) echo "coolercontrol|coolercontrold|/usr/bin/coolercontrold" ;;
			input-remapper) echo "input-remapper|input-remapper|/usr/bin/input-remapper-service" ;;
			keyd) echo "keyd|keyd|/usr/bin/keyd" ;;
		esac
	done
}

# ---- installing packages ------------------------------------------------------
# Build tools added only for an install from source, and removed afterwards.
TOOLS_ADDED=""
tools_add() { # tools_add <pkg>...; 1 if they cannot be installed
	local p add=""
	for p in "$@"; do
		in_target pacman -Q "$p" >/dev/null 2>&1 || add+=" $p"
	done
	[[ -n $add ]] || return 0
	# shellcheck disable=SC2086
	in_target pacman -S --needed --noconfirm --asdeps $add || return 1
	TOOLS_ADDED+="$add"
}
tools_remove() {
	[[ -n $TOOLS_ADDED ]] || return 0
	# shellcheck disable=SC2086
	if in_target pacman -Rns --noconfirm $TOOLS_ADDED >/dev/null 2>&1; then
		echo "Removed the build tools again:$TOOLS_ADDED"
	else
		echo "Build tools left installed (another package needs them):$TOOLS_ADDED"
	fi
	TOOLS_ADDED=""
}

sha256_is() { # sha256_is <file> <expected>
	local got
	got=$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)
	if [[ $got != "$2" ]]; then
		echo "Checksum mismatch for ${1##*/}: expected $2, got ${got:-nothing}" >&2
		return 1
	fi
}

# ---- AUR helper -----------------------------------------------------------------
AUR_READY=0
AUR_SUDOERS=/etc/sudoers.d/99-artix-install-aur

# makepkg and the helpers run as the primary user and call "sudo pacman": allow
# that without a password only while the installer runs.
aur_sudo_on() {
	printf '%s ALL=(ALL:ALL) NOPASSWD: /usr/bin/pacman\n' "$USER_NAME" >"$TARGET$AUR_SUDOERS"
	chmod 440 "$TARGET$AUR_SUDOERS"
}
aur_sudo_off() { rm -f "$TARGET$AUR_SUDOERS"; }

# Clone an AUR package: aur.archlinux.org, or Arch's GitHub mirror of the AUR.
aur_clone() { # aur_clone <package> <dir>
	as_user "$USER_NAME" git clone -q --depth 1 "https://aur.archlinux.org/$1.git" "$2" 2>/dev/null && [[ -s $TARGET$2/PKGBUILD ]] && return 0
	rm -rf "$TARGET$2"
	echo "aur.archlinux.org did not answer; using Arch's GitHub mirror of the AUR."
	as_user "$USER_NAME" git clone -q --depth 1 --branch "$1" --single-branch https://github.com/archlinux/aur.git "$2"
}

# Install yay or paru (prebuilt -bin package) for the primary user.
aur_setup() {
	local pkg="${AUR_HELPER}-bin" dir
	[[ $AUR_READY == 1 ]] && return 0
	aur_on || return 1
	[[ -n $USER_NAME ]] || return 1
	# Already installed (an earlier step): only the temporary sudo rule is needed.
	if in_target pacman -Q "$AUR_HELPER" >/dev/null 2>&1 || in_target pacman -Q "$pkg" >/dev/null 2>&1; then
		aur_sudo_on
		AUR_READY=1
		return 0
	fi
	echo "Installing the AUR helper $AUR_HELPER (from $pkg) for $USER_NAME ..."
	in_target pacman -S --needed --noconfirm base-devel git || return 1
	# Use every core for builds.
	sed -i -E "s/^#?MAKEFLAGS=.*/MAKEFLAGS=\"-j\$(nproc)\"/" "$TARGET/etc/makepkg.conf" || true
	aur_sudo_on
	dir="/home/$USER_NAME/.cache/artix-install/$pkg"
	rm -rf "$TARGET$dir"
	as_user "$USER_NAME" mkdir -p "${dir%/*}" || return 1
	aur_clone "$pkg" "$dir" || return 1
	as_user "$USER_NAME" /bin/sh -c "cd '$dir' && makepkg -si --noconfirm --needed" || return 1
	rm -rf "$TARGET/home/$USER_NAME/.cache/artix-install"
	in_target pacman -Q "$AUR_HELPER" >/dev/null 2>&1 || in_target pacman -Q "$pkg" >/dev/null 2>&1 || return 1
	AUR_READY=1
	echo "$AUR_HELPER installed."
}

aur_install() { # aur_install <package>...  (as the primary user)
	(($#)) || return 0
	if ! aur_setup; then
		echo "The AUR helper is not available." >&2
		return 1
	fi
	echo "From the AUR ($AUR_HELPER): $*"
	case $AUR_HELPER in
		yay) as_user "$USER_NAME" yay -S --needed --noconfirm --answerdiff None --answerclean None --removemake "$@" ;;
		paru) as_user "$USER_NAME" paru -S --needed --noconfirm --skipreview --removemake "$@" ;;
	esac
}

# Official packages with pacman; the rest from the AUR when a helper is chosen.
# Never fails the install: problems become warnings.
install_available() { # install_available "label" pkg...
	local label=$1 p
	shift
	local -a want=() off=() aur=() missing=()
	mapfile -t want < <(printf '%s\n' "$@" | awk 'NF && !seen[$0]++')
	((${#want[@]})) || return 0
	for p in "${want[@]}"; do
		if official_has "$p" || in_target pacman -Si "$p" >/dev/null 2>&1 || in_target pacman -Sg "$p" >/dev/null 2>&1; then
			off+=("$p")
		elif aur_on; then
			aur+=("$p")
		else
			missing+=("$p")
		fi
	done
	if ((${#missing[@]})); then warn "$label - not in the official repositories (an AUR helper would get them), skipped: ${missing[*]}"; fi
	if ((${#off[@]})); then
		echo "Installing $label: ${off[*]}"
		if ! in_target pacman -S --needed --noconfirm "${off[@]}"; then
			warn "$label - installing them together failed; trying one by one."
			for p in "${off[@]}"; do
				in_target pacman -S --needed --noconfirm "$p" || warn "$label - could not install $p"
			done
		fi
	fi
	if ((${#aur[@]})); then
		if ! aur_install "${aur[@]}"; then
			warn "$label - building them together from the AUR failed; trying one by one."
			for p in "${aur[@]}"; do
				aur_install "$p" || warn "$label - could not build $p from the AUR"
			done
		fi
	fi
	return 0
}

# Packages that must install (base of the chosen setup): official ones fail the
# step when pacman fails; AUR-only ones are handled like install_available.
install_required() { # install_required "label" pkg...
	local label=$1 p
	shift
	local -a want=() off=() rest=()
	mapfile -t want < <(printf '%s\n' "$@" | awk 'NF && !seen[$0]++')
	((${#want[@]})) || return 0
	for p in "${want[@]}"; do
		if official_has "$p" || in_target pacman -Si "$p" >/dev/null 2>&1 || in_target pacman -Sg "$p" >/dev/null 2>&1; then off+=("$p"); else rest+=("$p"); fi
	done
	if ((${#off[@]})); then
		echo "Installing $label: ${off[*]}"
		in_target pacman -S --needed --noconfirm "${off[@]}"
	fi
	if ((${#rest[@]})); then install_available "$label" "${rest[@]}"; fi
}

# ---- tools from outside the official repositories ---------------------------------
OPENLOGI_VERSION=0.9.0
OPENLOGI_URL=https://github.com/AprilNEA/OpenLogi/releases/download/v0.9.0/openlogi-v0.9.0-linux-amd64.pkg.tar.zst
OPENLOGI_SHA256=ba428a1d8043e7ef82c9576e9fa1d37c31be781cca304e59d655af4a0ab045d4
OPENLINKHUB_VERSION=0.9.4
OPENLINKHUB_GIT=https://github.com/jurkovic-nikola/OpenLinkHub
OPENLINKHUB_COMMIT=a08204cf88fd373a0bbdbe1f4382e8c64024adca

# Each install_* below is called in "if": errexit is off, so every step checks itself.

# OpenLogi: openlogi-bin from the AUR, or the project's own Arch package
# (pinned SHA-256). Its agent is a systemd user service upstream; on Artix it
# starts with the desktop session instead (XDG autostart).
install_openlogi() {
	local d=/tmp/artix-install-openlogi
	if aur_on; then
		echo "OpenLogi: from the AUR (openlogi-bin) ..."
		aur_install openlogi-bin || return 1
	else
		echo "OpenLogi $OPENLOGI_VERSION: the project's Arch package (pinned checksum) ..."
		rm -rf "$TARGET$d" && mkdir -p "$TARGET$d" || return 1
		curl -fsSL --proto '=https' --max-time 300 -o "$TARGET$d/openlogi.pkg.tar.zst" "$OPENLOGI_URL" || return 1
		sha256_is "$TARGET$d/openlogi.pkg.tar.zst" "$OPENLOGI_SHA256" || return 1
		in_target pacman -U --noconfirm "$d/openlogi.pkg.tar.zst" || return 1
		rm -rf "$TARGET$d"
	fi
	mkdir -p "$TARGET/etc/modules-load.d"
	echo uinput >"$TARGET/etc/modules-load.d/openlogi.conf"
	local ex=""
	if [[ -e $TARGET/usr/lib/systemd/user/openlogi-agent.service ]]; then
		ex=$(sed -n 's/^ExecStart=//p' "$TARGET/usr/lib/systemd/user/openlogi-agent.service" | head -n1)
	fi
	if [[ -n $ex ]]; then
		mkdir -p "$TARGET/etc/xdg/autostart"
		printf '[Desktop Entry]\nType=Application\nName=OpenLogi agent\nComment=Started with the session (artix-install.sh)\nExec=%s\nNoDisplay=true\n' "$ex" \
			>"$TARGET/etc/xdg/autostart/openlogi-agent.desktop"
	fi
	echo "OpenLogi installed: run openlogi-desktop; its agent starts with your session."
}

# OpenLinkHub: from the AUR, or a fixed release built with Go. Either way it
# runs as its own user from a service written for the chosen init.
install_openlinkhub() {
	local o=/opt/OpenLinkHub head
	if aur_on; then
		echo "OpenLinkHub: from the AUR (openlinkhub) ..."
		aur_install openlinkhub || return 1
		write_openlinkhub_service || return 1
		echo "OpenLinkHub installed: service 'openlinkhub', web UI at http://127.0.0.1:27003"
		return 0
	fi
	echo "OpenLinkHub $OPENLINKHUB_VERSION: building from source ..."
	tools_add go gcc git || return 1
	rm -rf "$TARGET$o"
	in_target git -c advice.detachedHead=false clone -q --depth 1 -b "$OPENLINKHUB_VERSION" "$OPENLINKHUB_GIT" "$o" || return 1
	head=$(in_target git -C "$o" rev-parse HEAD) || return 1
	if [[ $head != "$OPENLINKHUB_COMMIT" ]]; then
		echo "OpenLinkHub: tag $OPENLINKHUB_VERSION points to $head, expected $OPENLINKHUB_COMMIT" >&2
		return 1
	fi
	# go.sum pins every Go module; GOTOOLCHAIN=local keeps Arch's Go (no toolchain download).
	in_target /bin/sh -c "cd $o && GOTOOLCHAIN=local GOFLAGS=-mod=readonly GOPATH=/tmp/artix-go GOCACHE=/tmp/artix-go/cache CGO_ENABLED=1 go build -trimpath -o OpenLinkHub ." || return 1
	rm -rf "$TARGET/tmp/artix-go" "$TARGET$o/.git"
	[[ -x $TARGET$o/OpenLinkHub ]] || return 1
	if ! grep -q '^openlinkhub:' "$TARGET/etc/passwd"; then
		in_target useradd -r -M -d "$o" -s /usr/bin/nologin openlinkhub || return 1
	fi
	in_target chown -R openlinkhub:openlinkhub "$o" || return 1
	mkdir -p "$TARGET/etc/udev/rules.d"
	cp "$TARGET$o/99-openlinkhub.rules" "$TARGET/etc/udev/rules.d/99-openlinkhub.rules" || return 1
	write_openlinkhub_service || return 1
	echo "OpenLinkHub installed: service 'openlinkhub', web UI at http://127.0.0.1:27003"
}

# The project's systemd unit, as a service for the chosen init: udev rules
# reloaded and the Corsair devices re-triggered, then OpenLinkHub as its own
# user in its directory.
write_openlinkhub_service() {
	local bin="" d
	for d in /opt/OpenLinkHub/OpenLinkHub /usr/bin/OpenLinkHub /usr/bin/openlinkhub; do
		if [[ -x $TARGET$d ]]; then bin=$d; break; fi
	done
	if [[ -z $bin ]]; then
		echo "OpenLinkHub: its program was not found." >&2
		return 1
	fi
	if ! grep -q '^openlinkhub:' "$TARGET/etc/passwd"; then
		in_target useradd -r -M -d "${bin%/*}" -s /usr/bin/nologin openlinkhub || return 1
	fi
	write_service openlinkhub daemon "OpenLinkHub (Corsair)" \
		"/bin/sh -c 'udevadm control --reload-rules; udevadm trigger --subsystem-match=usb --attr-match=idVendor=1b1c; udevadm settle --timeout=30; cd ${bin%/*} && exec setpriv --reuid=openlinkhub --regid=openlinkhub --init-groups $bin'" || return 1
	OPENLINKHUB_SVC=1
}
OPENLINKHUB_SVC=0

# After the peripheral packages: tools from outside the repositories, configs, groups.
periph_finish() {
	local p u ok
	[[ -n $PERIPH ]] || return 0
	TOOLS_ADDED=""
	for p in openlogi openlinkhub; do
		has "$PERIPH" "$p" || continue
		ok=0
		case $p in
			openlogi) if install_openlogi; then ok=1; fi ;;
			openlinkhub) if install_openlinkhub; then ok=1; fi ;;
		esac
		if ((ok == 0)); then
			warn "$p could not be installed (details in the log); the rest of the install continues."
			PERIPH=$(without "$PERIPH" "$p")   # its service is then not enabled
		fi
	done
	tools_remove
	# logid stops without a config file: start with an empty device list.
	if has "$PERIPH" logiops && [[ ! -e $TARGET/etc/logid.cfg ]]; then
		printf '%s\n' '// logiops (artix-install.sh): add your devices, see https://github.com/PixlOne/logiops/wiki/Configuration' \
			'// then restart the logid service' 'devices: ();' >"$TARGET/etc/logid.cfg"
	fi
	# OpenRGB reads motherboard and memory RGB over SMBus.
	if has "$PERIPH" openrgb; then
		mkdir -p "$TARGET/etc/modules-load.d"
		echo i2c-dev >"$TARGET/etc/modules-load.d/openrgb.conf"
	fi
	# Groups that only exist once their package is installed.
	for u in "${USERS[@]}"; do
		for p in plugdev keyd input; do
			case $p in
				plugdev) has "$PERIPH" openrazer || continue ;;
				keyd) has "$PERIPH" keyd || continue ;;
				input) has "$PERIPH" input-remapper || has "$PERIPH" kanata || continue ;;
			esac
			if grep -q "^$p:" "$TARGET/etc/group"; then in_target usermod -a -G "$p" "$u"; fi
		done
	done
	if has "$PERIPH" xone; then
		echo "xone: if the wireless dongle does not light up, its firmware is missing: see the xone-dkms notes (xone-dongle-firmware)."
	fi
	return 0
}

install_software() {
	local -a list=()
	mapfile -t list < <(desktop_extra_packages)
	install_available "desktop and window manager tools" "${list[@]}"
	mapfile -t list < <(gpu_packages)
	install_available "GPU drivers" "${list[@]}"
	mapfile -t list < <(app_packages)
	install_available "applications" "${list[@]}"
	mapfile -t list < <(gaming_packages)
	install_available "gaming packages" "${list[@]}"
	if periph_dkms; then
		mapfile -t list < <(kernel_headers)
		install_available "kernel headers (for the peripheral drivers)" "${list[@]}"
	fi
	mapfile -t list < <(periph_packages)
	install_available "peripheral support" "${list[@]}"
	read -ra list <<<"$EXTRA_PKGS"
	install_available "extra packages" "${list[@]}"
	if [[ -n $AUR_PKGS ]]; then
		read -ra list <<<"$AUR_PKGS"
		if ! aur_install "${list[@]}"; then warn "Some AUR packages could not be built: $AUR_PKGS"; fi
	fi

	if has "$APPS" flatpak; then
		in_target flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo ||
			warn "Could not add the Flathub remote; run: flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo"
	fi
}

# =============================================================================
#  Services: one interface for OpenRC, runit, s6 and dinit
#  Artix ships a daemon's start scripts in a separate "<package>-<init>"
#  package. The service names are read from that package's file list, so the
#  installer never guesses them. Daemons without such a package get a service
#  written here, for whichever init was chosen.
# =============================================================================
svc_dir() { # where <init> keeps service definitions (inside the target)
	case $INIT in
		openrc) echo /etc/init.d ;;
		runit) echo /etc/runit/sv ;;
		s6) echo /etc/s6/sv ;;
		dinit) echo /etc/dinit.d ;;
	esac
}

svc_exists() { # svc_exists <name>
	case $INIT in
		openrc) [[ -f $TARGET/etc/init.d/$1 ]] ;;
		runit) [[ -d $TARGET/etc/runit/sv/$1 ]] ;;
		s6) [[ -d $TARGET/etc/s6/sv/$1 || -d $TARGET/etc/s6/adminsv/$1 ]] ;;
		dinit) [[ -f $TARGET/etc/dinit.d/$1 ]] ;;
	esac
}

# The services in a package (normally <base>-$INIT). For s6, the bundles (which
# hold a daemon and its logger) or else the services that are not loggers.
pkg_services() { # pkg_services <package>
	local files n t out=""
	files=$(in_target pacman -Qlq "$1" 2>/dev/null) || return 0
	case $INIT in
		openrc) awk -F/ '$0 ~ "^/etc/init[.]d/[^/]+$" { print $4 }' <<<"$files" ;;
		runit) awk -F/ '$0 ~ "^/etc/runit/sv/[^/]+/$" { print $5 }' <<<"$files" ;;
		dinit) awk -F/ '$0 ~ "^/etc/dinit[.]d/[^/]+$" { print $4 }' <<<"$files" ;;
		s6)
			local -a names=()
			mapfile -t names < <(awk -F/ '$0 ~ "^/etc/s6/sv/[^/]+/$" { print $5 }' <<<"$files")
			for n in "${names[@]}"; do
				t=$(cat "$TARGET/etc/s6/sv/$n/type" 2>/dev/null) || t=""
				if [[ $t == bundle ]]; then out+=" $n"; fi
			done
			if [[ -z $out ]]; then
				for n in "${names[@]}"; do
					[[ $n == *-log ]] || out+=" $n"
				done
			fi
			tr ' ' '\n' <<<"$out" | awk NF
			;;
	esac
}

S6_CHANGED=0
svc_enable() { # svc_enable <name>
	local n=$1
	if ! svc_exists "$n"; then
		echo "No $INIT service '$n' in the new system." >&2
		return 1
	fi
	case $INIT in
		openrc) in_target rc-update add "$n" default >/dev/null ;;
		runit)
			mkdir -p "$TARGET/etc/runit/runsvdir/default"
			ln -sfn "/etc/runit/sv/$n" "$TARGET/etc/runit/runsvdir/default/$n"
			;;
		s6)
			mkdir -p "$TARGET/etc/s6/adminsv/default/contents.d"
			: >"$TARGET/etc/s6/adminsv/default/contents.d/$n"
			S6_CHANGED=1
			;;
		dinit)
			mkdir -p "$TARGET/etc/dinit.d/boot.d"
			ln -sfn "../$n" "$TARGET/etc/dinit.d/boot.d/$n"
			;;
	esac
}

svc_disable() { # svc_disable <name>  (quietly does nothing if it is not enabled)
	case $INIT in
		openrc) in_target rc-update del "$1" default >/dev/null 2>&1 || true ;;
		runit) rm -f "$TARGET/etc/runit/runsvdir/default/$1" ;;
		s6)
			if [[ -e $TARGET/etc/s6/adminsv/default/contents.d/$1 ]]; then
				rm -f "$TARGET/etc/s6/adminsv/default/contents.d/$1"
				S6_CHANGED=1
			fi
			;;
		dinit) rm -f "$TARGET/etc/dinit.d/boot.d/$1" ;;
	esac
}

# s6 compiles its service database; do that once after a batch of changes.
svc_commit() {
	[[ $INIT == s6 && $S6_CHANGED == 1 ]] || return 0
	if in_target s6-db-reload -r >/dev/null 2>&1; then
		echo "s6: service database compiled."
	else
		warn "s6: the service database could not be compiled now; it is compiled again at boot. If a service does not start, run: s6-db-reload"
	fi
	S6_CHANGED=0
}

enable_pkg() { # enable_pkg <package> - every service it ships; 1 if none
	local s ok=1
	for s in $(pkg_services "$1"); do
		if svc_enable "$s"; then
			echo "Enabled service: $s ($INIT, from $1)"
			ok=0
		fi
	done
	return "$ok"
}

# A service written by the installer: /usr/local/libexec/artix-install/<name>
# holds the command; the init's own definition runs it. "daemon" keeps
# running (supervised); "oneshot" runs once at boot.
write_service() { # write_service <name> daemon|oneshot "<description>" "<shell command>"
	local n=$1 kind=$2 desc=$3 cmd=$4 x=/usr/local/libexec/artix-install
	mkdir -p "$TARGET$x"
	if [[ $kind == daemon ]]; then
		printf '#!/bin/sh\n# %s (artix-install.sh)\nexec %s\n' "$desc" "$cmd" >"$TARGET$x/$n"
	else
		printf '#!/bin/sh\n# %s (artix-install.sh)\n%s\n' "$desc" "$cmd" >"$TARGET$x/$n"
	fi
	chmod 755 "$TARGET$x/$n"
	case $INIT in
		openrc)
			mkdir -p "$TARGET/etc/init.d"
			if [[ $kind == daemon ]]; then
				printf '#!/sbin/openrc-run\n# Written by artix-install.sh\ndescription="%s"\nsupervisor=supervise-daemon\ncommand="%s"\n\ndepend() {\n\tneed localmount\n\tafter bootmisc udev\n}\n' \
					"$desc" "$x/$n" >"$TARGET/etc/init.d/$n"
			else
				printf '#!/sbin/openrc-run\n# Written by artix-install.sh\ndescription="%s"\n\ndepend() {\n\tneed localmount\n}\n\nstart() {\n\tebegin "%s"\n\t%s\n\teend $?\n}\n' \
					"$desc" "$desc" "$x/$n" >"$TARGET/etc/init.d/$n"
			fi
			chmod 755 "$TARGET/etc/init.d/$n"
			;;
		runit)
			mkdir -p "$TARGET/etc/runit/sv/$n"
			if [[ $kind == daemon ]]; then
				printf '#!/bin/sh\n# %s (artix-install.sh)\nexec %s 2>&1\n' "$desc" "$x/$n" >"$TARGET/etc/runit/sv/$n/run"
			else
				printf '#!/bin/sh\n# %s (artix-install.sh): runs once, then stays "up"\n%s\nexec sleep infinity\n' "$desc" "$x/$n" >"$TARGET/etc/runit/sv/$n/run"
			fi
			chmod 755 "$TARGET/etc/runit/sv/$n/run"
			;;
		s6)
			mkdir -p "$TARGET/etc/s6/adminsv/$n"
			if [[ $kind == daemon ]]; then
				echo longrun >"$TARGET/etc/s6/adminsv/$n/type"
				printf '#!/bin/sh\n# %s (artix-install.sh)\nexec %s 2>&1\n' "$desc" "$x/$n" >"$TARGET/etc/s6/adminsv/$n/run"
				chmod 755 "$TARGET/etc/s6/adminsv/$n/run"
			else
				echo oneshot >"$TARGET/etc/s6/adminsv/$n/type"
				printf '%s\n' "$x/$n" >"$TARGET/etc/s6/adminsv/$n/up"
			fi
			S6_CHANGED=1
			;;
		dinit)
			mkdir -p "$TARGET/etc/dinit.d"
			if [[ $kind == daemon ]]; then
				printf '# %s (artix-install.sh)\ntype = process\ncommand = %s\nrestart = true\n' "$desc" "$x/$n" >"$TARGET/etc/dinit.d/$n"
			else
				printf '# %s (artix-install.sh)\ntype = scripted\ncommand = %s\n' "$desc" "$x/$n" >"$TARGET/etc/dinit.d/$n"
			fi
			;;
	esac
	echo "Service written: $n ($INIT, $kind)"
}

# A daemon: Artix's "<base>-$INIT" package when there is one, otherwise a
# service written here that runs <command>.
service_for() { # service_for <base package> <service name> "<command>"
	local base=$1 n=$2 cmd=$3 pkg="$1-$INIT"
	if official_has "$pkg" || in_target pacman -Si "$pkg" >/dev/null 2>&1; then
		if in_target pacman -S --needed --noconfirm "$pkg" >/dev/null && enable_pkg "$pkg"; then
			return 0
		fi
	fi
	if [[ -z $cmd ]]; then
		warn "$base: no $INIT service package ($pkg); start it yourself."
		return 0
	fi
	if [[ ! -x $TARGET${cmd%% *} ]]; then
		warn "$base: ${cmd%% *} is not installed; service '$n' not set up."
		return 0
	fi
	write_service "$n" daemon "$base" "$cmd"
	svc_enable "$n" && echo "Enabled service: $n ($INIT, written by the installer)"
	return 0
}

# ---- network, swap, services ----------------------------------------------------
# Wi-Fi joined on the live system is not carried over: its passphrase would
# have to be stored in a file of the new system. Connect again after the first
# boot (nmtui, connmanctl or iwctl).
configure_network() {
	case $NET in
		dhcpcd)
			# iwd only handles Wi-Fi; dhcpcd gives every interface an address.
			mkdir -p "$TARGET/etc/iwd"
			[[ -e $TARGET/etc/iwd/main.conf ]] || printf '[General]\nEnableNetworkConfiguration=false\n' >"$TARGET/etc/iwd/main.conf"
			;;
	esac
	if compgen -G '/sys/class/net/*/wireless' >/dev/null && [[ $NET != none ]]; then
		case $NET in
			nm) echo "Wi-Fi: connect after the first boot with nmtui (or the desktop's network applet)." ;;
			connman) echo "Wi-Fi: connect after the first boot with connmanctl (or cmst / connman-gtk)." ;;
			dhcpcd) echo "Wi-Fi: connect after the first boot with: iwctl station wlan0 connect <network>" ;;
		esac
	fi
}

# zramen (Artix): a compressed swap device in RAM at boot.
configure_zram() {
	[[ $SWAP == zram ]] || return 0
	mkdir -p "$TARGET/etc/sysctl.d"
	printf 'vm.swappiness = 180\nvm.watermark_boost_factor = 0\nvm.watermark_scale_factor = 125\nvm.page-cluster = 0\n' \
		>"$TARGET/etc/sysctl.d/99-zram.conf"
}

# Packages whose <init> service packages are installed with the system.
init_service_bases() {
	echo dbus
	echo elogind
	echo cronie
	echo chrony
	echo syslog-ng
	case $NET in
		nm) echo networkmanager ;;
		connman) echo connman ;;
		dhcpcd) printf '%s\n' dhcpcd iwd ;;
	esac
	if [[ $SWAP == zram ]]; then echo zramen; fi
	if has "$APPS" openssh; then echo openssh; fi
	if has "$APPS" cups; then echo cups; fi
	return 0
}

enable_services() {
	local b s n c dm
	for b in $(init_service_bases); do
		if ! enable_pkg "$b-$INIT"; then
			warn "No $INIT service found in $b-$INIT; $b does not start by itself."
		fi
	done
	dm=$(desktop_dm)
	if [[ -n $dm ]]; then
		if ! enable_pkg "$(dm_service_pkg)"; then
			warn "The login screen ($dm) has no $INIT service; log in on the console and start your desktop by hand."
		fi
	fi
	while IFS='|' read -r b n c; do
		[[ -n $b ]] || continue
		service_for "$b" "$n" "$c"
	done < <(periph_services | awk 'NF && !seen[$0]++')
	if [[ $OPENLINKHUB_SVC == 1 ]]; then svc_enable openlinkhub && echo "Enabled service: openlinkhub ($INIT)"; fi
	if has "$(gpu_list)" vm; then
		case $(vm_type) in
			virtualbox) service_for virtualbox-guest-utils vboxservice "/usr/bin/VBoxService -f" ;;
			vmware) service_for open-vm-tools vmtoolsd "/usr/bin/vmtoolsd" ;;
		esac
	fi
	# SSD trim once a week, run by cron (cronie).
	mkdir -p "$TARGET/etc/cron.weekly"
	printf '#!/bin/sh\n# artix-install.sh: trim free space on SSDs once a week\nexec fstrim -a\n' >"$TARGET/etc/cron.weekly/fstrim"
	chmod 755 "$TARGET/etc/cron.weekly/fstrim"
	svc_commit
	return 0
}

# ---- desktops: install side ---------------------------------------------------
session_exec() { # desktop id -> command a login-screen session starts
	case $1 in
		qtile) echo "qtile start" ;;
		herbstluftwm) echo "herbstluftwm --locked" ;;
		openbox) echo openbox-session ;;
		fluxbox) echo startfluxbox ;;
		icewm) echo icewm-session ;;
		dwm) echo /usr/local/bin/dwm-session ;;
		niri) echo niri-session ;;
		hyprland) echo Hyprland ;;
		*) echo "$1" ;;
	esac
}

# Without systemd nobody starts a session D-Bus or PipeWire for a bare window
# manager. /usr/local/bin/artix-session does both, then runs the window manager;
# desktop environments get PipeWire from an XDG autostart entry.
write_session_tools() {
	mkdir -p "$TARGET/usr/local/bin" "$TARGET/etc/xdg/autostart"
	cat >"$TARGET/usr/local/bin/artix-pipewire" <<'EOF'
#!/bin/sh
# artix-pipewire (artix-install.sh): start PipeWire, its PulseAudio server and
# WirePlumber for this user, unless they already run. Exits right away.
[ -n "${XDG_RUNTIME_DIR:-}" ] || exit 0
command -v pipewire >/dev/null 2>&1 || exit 0
uid=$(id -u)
if [ ! -S "$XDG_RUNTIME_DIR/pipewire-0" ]; then
	pkill -u "$uid" -x pipewire 2>/dev/null # left over from an earlier login
	pipewire >/dev/null 2>&1 &
	i=0
	while [ ! -S "$XDG_RUNTIME_DIR/pipewire-0" ] && [ $i -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
fi
if command -v wireplumber >/dev/null 2>&1 && ! pgrep -u "$uid" -x wireplumber >/dev/null 2>&1; then
	wireplumber >/dev/null 2>&1 &
fi
if command -v pipewire-pulse >/dev/null 2>&1 && ! pgrep -u "$uid" -x pipewire-pulse >/dev/null 2>&1; then
	pipewire-pulse >/dev/null 2>&1 &
fi
exit 0
EOF
	chmod 755 "$TARGET/usr/local/bin/artix-pipewire"
	printf '[Desktop Entry]\nType=Application\nName=PipeWire\nComment=Sound server (artix-install.sh)\nExec=/usr/local/bin/artix-pipewire\nNoDisplay=true\nX-GNOME-Autostart-Phase=Initialization\nX-KDE-autostart-phase=1\n' \
		>"$TARGET/etc/xdg/autostart/artix-pipewire.desktop"
	cat >"$TARGET/usr/local/bin/artix-session" <<'EOF'
#!/bin/sh
# artix-session <window manager command...>        (written by artix-install.sh)
# Starts a bare window manager the way a desktop environment starts itself:
# inside a D-Bus session (notifications, portals and tray apps need one) and
# with PipeWire running for sound. Used by the "(Artix session)" login
# entries; from the console: artix-session sway
if [ $# -eq 0 ]; then
	echo "usage: artix-session <command> [arguments]" >&2
	exit 2
fi
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-run-session >/dev/null 2>&1; then
	exec dbus-run-session -- "$0" "$@"
fi
# Started by startx or greetd instead of a display manager: load the same
# profile files a display manager would.
if [ -n "${ARTIX_XPROFILE:-}" ]; then
	unset ARTIX_XPROFILE
	for f in /etc/profile "$HOME/.profile" /etc/xprofile "$HOME/.xprofile"; do
		if [ -f "$f" ]; then . "$f"; fi
	done
fi
/usr/local/bin/artix-pipewire
"$@"
rc=$?
# PipeWire and its helpers end with the session.
pkill -u "$(id -u)" -x wireplumber 2>/dev/null
pkill -u "$(id -u)" -x pipewire-pulse 2>/dev/null
pkill -u "$(id -u)" -x pipewire 2>/dev/null
exit "$rc"
EOF
	chmod 755 "$TARGET/usr/local/bin/artix-session"
}

session_file() { # desktop id -> path of its "(Artix session)" file inside the target
	if [[ $(desktop_kind "$1") == x11 ]]; then
		echo "/usr/share/xsessions/artix-install-$1.desktop"
	else
		echo "/usr/share/wayland-sessions/artix-install-$1.desktop"
	fi
}

# Every selected window manager gets a "<name> (Artix session)" login entry
# that starts it through artix-session. Entries shipped by the packages stay.
ensure_sessions() {
	local d kind cmd bin f
	write_session_tools
	if has "$DESKTOP" dwm; then
		mkdir -p "$TARGET/usr/local/bin"
		cat >"$TARGET/usr/local/bin/dwm-session" <<'EOF'
#!/bin/sh
# dwm session (artix-install.sh): status bar, then dwm.
if command -v dwmblocks >/dev/null 2>&1; then dwmblocks &
elif command -v slstatus >/dev/null 2>&1; then slstatus &
fi
exec dwm
EOF
		chmod 755 "$TARGET/usr/local/bin/dwm-session"
	fi
	for d in $DESKTOP; do
		kind=$(desktop_kind "$d")
		[[ $kind == x11 || $kind == wl ]] || continue
		cmd=$(session_exec "$d")
		bin=${cmd%% *}
		bin=${bin##*/}
		if [[ $d == dwm ]]; then bin=dwm; fi
		if [[ ! -x $TARGET/usr/bin/$bin && ! -x $TARGET/usr/local/bin/$bin ]]; then
			warn "$(desktop_field "$d" 3): '$bin' is not installed; no login session for it."
			continue
		fi
		f="$TARGET$(session_file "$d")"
		mkdir -p "${f%/*}"
		printf '[Desktop Entry]\nName=%s (Artix session)\nComment=%s with a D-Bus session and PipeWire sound - written by artix-install.sh\nExec=/usr/local/bin/artix-session %s\nType=Application\nDesktopNames=%s\n' \
			"$(desktop_field "$d" 3)" "$bin" "$cmd" "$d" >"$f"
		echo "Login session: ${f#"$TARGET"}"
	done
}

de_start_cmd() { # desktop environment id -> command that starts it from startx
	case $1 in
		xfce) echo startxfce4 ;;
		plasma) echo startplasma-x11 ;;
		gnome) echo gnome-session ;;
		mate) echo mate-session ;;
		cinnamon) echo cinnamon-session ;;
		lxqt) echo startlxqt ;;
		budgie) echo budgie-desktop ;;
		enlightenment) echo enlightenment_start ;;
	esac
}

# Per-user defaults: the session LightDM preselects, and with no login screen
# an ~/.xinitrc so that "startx" starts the first X11 choice.
session_defaults() {
	local u home d first="" firstx="" line="" dm
	dm=$(desktop_dm)
	for d in $DESKTOP; do
		if [[ -z $first ]]; then first=$d; fi
		if [[ -z $firstx && $(desktop_kind "$d") != wl && $d != cosmic ]]; then firstx=$d; fi
	done
	if [[ -n $firstx ]]; then
		if [[ $(desktop_kind "$firstx") == x11 ]]; then
			line="exec /usr/local/bin/artix-session $(session_exec "$firstx")"
		else
			line="exec dbus-run-session $(de_start_cmd "$firstx")"
		fi
	fi
	for u in "${USERS[@]}"; do
		home="$TARGET/home/$u"
		[[ -d $home ]] || continue
		if [[ $dm == lightdm && $(desktop_kind "$first") != de && -e $TARGET$(session_file "$first") && ! -e $home/.dmrc ]]; then
			printf '[Desktop]\nSession=artix-install-%s\n' "$first" >"$home/.dmrc"
			in_target chown "$u:" "/home/$u/.dmrc"
		fi
		if [[ -z $dm && -n $line && ! -e $home/.xinitrc ]]; then
			printf '#!/bin/sh\n# Written by artix-install.sh: "startx" starts this session.\nexport ARTIX_XPROFILE=1\n%s\n' "$line" >"$home/.xinitrc"
			in_target chown "$u:" "/home/$u/.xinitrc"
			echo "No login screen: 'startx' starts ${line#exec } for $u"
		fi
	done
	if [[ -z $dm ]] && has_kind wl; then
		echo "No login screen: start a Wayland window manager from the console with e.g. 'artix-session sway'."
	fi
}

# bspwm and river start with an empty screen without a config: give each user
# the package's example (dotfile presets may replace it later).
wm_default_configs() {
	local u home src d
	for u in "${USERS[@]}"; do
		home="$TARGET/home/$u"
		[[ -d $home ]] || continue
		if has "$DESKTOP" bspwm && [[ ! -e $home/.config/bspwm/bspwmrc ]]; then
			src=""
			for d in "$TARGET/usr/share/doc/bspwm/examples" "$TARGET/usr/share/doc/bspwm"; do
				if [[ -f $d/bspwmrc ]]; then
					src=$d/bspwmrc
					break
				fi
			done
			if [[ -n $src ]]; then
				mkdir -p "$home/.config/bspwm" "$home/.config/sxhkd"
				install -m 755 "$src" "$home/.config/bspwm/bspwmrc"
				if [[ -f ${src%/*}/sxhkdrc ]]; then sed 's/\burxvt\b/alacritty/' "${src%/*}/sxhkdrc" >"$home/.config/sxhkd/sxhkdrc"; fi
				in_target chown -R "$u:" "/home/$u/.config"
				echo "bspwm: example config for $u"
			else
				warn "bspwm: no example bspwmrc found; create ~/.config/bspwm/bspwmrc."
			fi
		fi
		if has "$DESKTOP" river && [[ ! -e $home/.config/river/init ]]; then
			src=""
			for d in "$TARGET/usr/share/doc/river/examples" "$TARGET/usr/share/doc/river" "$TARGET/usr/share/river"; do
				if [[ -f $d/init ]]; then
					src=$d/init
					break
				fi
			done
			if [[ -n $src ]]; then
				mkdir -p "$home/.config/river"
				install -m 755 "$src" "$home/.config/river/init"
				in_target chown -R "$u:" "/home/$u/.config"
				echo "river: example init for $u"
			fi
		fi
	done
}

write_greetd_config() {
	local x="" cmd="" first=${DESKTOP%% *}
	if has_kind x11 || has_kind de; then x=" --xsessions /usr/share/xsessions --xsession-wrapper 'startx /usr/bin/env ARTIX_XPROFILE=1'"; fi
	# Until a session was chosen once (F2), Enter starts the first Wayland choice.
	if [[ $(desktop_kind "$first") == wl ]]; then cmd=" --cmd '/usr/local/bin/artix-session $(session_exec "$first")'"; fi
	mkdir -p "$TARGET/etc/greetd"
	cat >"$TARGET/etc/greetd/config.toml" <<EOF
# greetd + tuigreet (artix-install.sh). F2 in tuigreet picks the session.
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --remember-session --asterisks --sessions /usr/share/wayland-sessions${x}${cmd}"
user = "greeter"
EOF
	echo "greetd: tuigreet on tty1"
}

# After all desktop packages are in: sessions, starter configs, login screen.
finish_desktop() {
	desktop_on || return 0
	ensure_sessions
	wm_default_configs
	session_defaults
	if [[ $(desktop_dm) == greetd ]]; then write_greetd_config; fi
	if [[ $(desktop_dm) == ly ]]; then ly_tty_free; fi
}

# Ly runs on a console that must not also have a login prompt: read its tty
# from Artix's Ly start script and switch off the getty there.
ly_tty_free() {
	local t f
	f=$(pkg_services "ly-$INIT" | head -n1)
	t=$(grep -rhoE 'tty[0-9]+' "$TARGET$(svc_dir)/${f:-ly}" 2>/dev/null | head -n1) || t=""
	t=${t:-tty2}
	case $INIT in
		openrc) svc_disable "agetty.$t" ;;
		runit) svc_disable "agetty-$t" ;;
		s6) svc_disable "agetty-$t"; svc_disable "$t" ;;
		dinit) svc_disable "$t"; svc_disable "agetty-$t" ;;
	esac
	echo "Ly: login screen on $t (its console login prompt is off)"
}

# ---- dotfile presets: install side ------------------------------------------
write_dots_helper() {
	cat >"$TARGET/tmp/artix-dots.sh" <<'EOF'
#!/bin/sh
# artix-dots.sh <git url> <branch> <how> - run as the user (artix-install.sh)
set -eu
url=$1 branch=$2 how=$3
tmp=$(mktemp -d /tmp/artix-dots.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
git clone -q --depth 1 -b "$branch" "$url" "$tmp/r"
r=$tmp/r
cpb() { cp -a --backup=numbered "$@"; }
case $how in
	skel)
		[ -d "$r/etc/skel" ] || { echo "no etc/skel in $url" >&2; exit 1; }
		cpb "$r/etc/skel/." "$HOME/"
		;;
	dots)
		for f in "$r"/.[!.]* "$r"/..?*; do
			[ -e "$f" ] || continue
			case ${f##*/} in
				.git | .github | .gitignore | .gitmodules | .gitattributes | .editorconfig) continue ;;
			esac
			cpb "$f" "$HOME/"
		done
		;;
	config)
		[ -d "$r/config" ] || { echo "no config/ in $url" >&2; exit 1; }
		mkdir -p "$HOME/.config"
		cpb "$r/config/." "$HOME/.config/"
		;;
	build)
		name=${url##*/}
		name=${name%.git}
		mkdir -p "$HOME/.local/src"
		rm -rf "${HOME:?}/.local/src/$name"
		cp -a "$r" "$HOME/.local/src/$name"
		cd "$HOME/.local/src/$name"
		make
		;;
	fish)
		mkdir -p "$HOME/.config/fish"
		sed '/^source \/usr\/share\/cachyos-fish-config/d' "$r/cachyos-config.fish" >"$HOME/.config/fish/cachyos-config.fish"
		grep -qs cachyos-config.fish "$HOME/.config/fish/config.fish" ||
			echo 'source ~/.config/fish/cachyos-config.fish' >>"$HOME/.config/fish/config.fish"
		;;
	bash)
		cpb "$r/.bashrc" "$HOME/.bashrc"
		mkdir -p "$HOME/.config"
		cpb "$r/starship.toml" "$HOME/.config/starship.toml"
		;;
	*) echo "unknown method $how" >&2; exit 1 ;;
esac
EOF
	chmod 755 "$TARGET/tmp/artix-dots.sh"
}

bs_presets() {
	local id d line label sources pkgs note src url branch how name re_url='^https://[A-Za-z0-9./_-]+$' re_br='^[A-Za-z0-9._/-]+$'
	local -a plist=() wm=()
	in_target pacman -S --needed --noconfirm git || warn "Dotfiles: could not install git."
	write_dots_helper
	for id in $DOTS; do
		label="" sources="" pkgs="" note=""
		line=$(dots_table | awk -F'|' -v i="$id" '$1 == i')
		if [[ -n $line ]]; then IFS='|' read -r _ _ label sources pkgs note <<<"$line"; fi
		if [[ -z $label ]]; then
			warn "Dotfiles: unknown preset '$id' skipped."
			continue
		fi
		echo "==> Dotfiles: $label"
		if [[ -n $note ]]; then echo "    Note: $note"; fi
		read -ra plist <<<"$pkgs"
		if [[ $STANDALONE == 1 ]]; then
			# On an installed system the window manager itself may be missing.
			for d in $(dots_field "$id" 2); do
				if [[ $d != any ]]; then read -ra wm <<<"$(desktop_field "$d" 4) $(desktop_field "$d" 5)"; plist=("${wm[@]}" "${plist[@]}"); fi
			done
		fi
		install_available "packages for $label" "${plist[@]}"
		if [[ $STANDALONE == 1 ]]; then
			for d in $(dots_field "$id" 2); do
				if [[ $d != any ]]; then DESKTOP=$d ensure_sessions; fi
			done
		fi
		for src in $sources; do
			IFS='#' read -r url branch how <<<"$src"
			if ! [[ $url =~ $re_url && $branch =~ $re_br && $how =~ ^[a-z]+$ ]]; then
				warn "Dotfiles: bad source '$src' skipped."
				continue
			fi
			echo "    $url ($branch, $how)"
			if ! as_user "$USER_NAME" sh /tmp/artix-dots.sh "$url" "$branch" "$how"; then
				warn "Dotfiles: $label - $url failed."
				continue
			fi
			if [[ $how == build ]]; then
				name=${url##*/}
				name=${name%.git}
				in_target /bin/sh -c "cd '/home/$USER_NAME/.local/src/$name' && make install" ||
					warn "Dotfiles: $label - 'make install' of $name failed."
			fi
		done
		if [[ $id == larbs ]]; then
			# LARBS sets PATH (status bar scripts) and its environment in
			# ~/.config/shell/profile, read by zsh on a console login. Login screens
			# read ~/.profile instead, so point that at the same file.
			as_user "$USER_NAME" /bin/sh -c '[ -e ~/.profile ] || [ ! -f ~/.config/shell/profile ] || ln -s .config/shell/profile ~/.profile' ||
				warn "Dotfiles: LARBS - could not link ~/.profile."
		fi
	done
	rm -f "$TARGET/tmp/artix-dots.sh"
}

# The daemons and their start scripts for the chosen init.
init_packages() {
	local b
	for b in $(init_service_bases); do
		echo "$b"
		echo "$b-$INIT"
	done
}

step_packages() {
	local -a pkgs=()
	mapfile -t pkgs < <(target_packages | awk 'NF && !seen[$0]++')
	install_required "system packages" "${pkgs[@]}"
	mapfile -t pkgs < <(init_packages | awk 'NF && !seen[$0]++')
	install_available "services for $(lbl_init)" "${pkgs[@]}"
	configure_desktop
	if aur_on && ! aur_setup; then
		warn "The AUR helper $AUR_HELPER could not be installed; AUR packages are skipped."
		AUR_HELPER=none
	fi
	install_software
	finish_desktop
	periph_finish
	configure_network
	configure_zram
	enable_services
	aur_sudo_off
}

# ---- LARBS-style bootstrap ---------------------------------------------------------
bs_install_progs() {
	local csv="$TARGET/tmp/artix-install-progs.csv" tag prog comment n=0 total name need_dev=0 need_pipx=0 need_flatpak=0
	local re_pkg='^[A-Za-z0-9][A-Za-z0-9._+-]*$' re_url='^(https?|git)://[^[:space:]"`$;|&<>]+$'
	if [[ $BS_PROGS =~ ^https?:// ]]; then
		echo "Downloading the programs list: $BS_PROGS"
		if ! curl -fsSL --max-time 120 -o "$csv" "$BS_PROGS"; then
			warn "Bootstrap: could not download $BS_PROGS; programs list skipped."
			return 0
		fi
	else
		cp "$BS_PROGS" "$csv"
	fi
	sed -i 's/\r$//' "$csv"
	total=$(grep -cvE '^[[:space:]]*(#|$)' "$csv" || true)
	grep -qE '^G,' "$csv" && need_dev=1
	grep -qE '^P,' "$csv" && need_pipx=1
	grep -qE '^F,' "$csv" && need_flatpak=1
	if ((need_dev)); then in_target pacman -S --needed --noconfirm git base-devel || warn "Bootstrap: could not install git/base-devel."; fi
	if ((need_pipx)); then in_target pacman -S --needed --noconfirm python-pipx || warn "Bootstrap: could not install pipx."; fi
	if ((need_flatpak)); then
		in_target pacman -S --needed --noconfirm flatpak || warn "Bootstrap: could not install flatpak."
		in_target flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
	fi
	if grep -qE '^A,' "$csv" && ! aur_on; then
		warn "Bootstrap: the programs list has AUR entries (A), but no AUR helper is chosen; they are skipped."
	fi
	echo "Installing $total programs from the list ..."
	while IFS=, read -r -u 9 tag prog comment || [[ -n $tag$prog ]]; do
		tag=$(trim "$tag")
		prog=$(trim "$prog")
		[[ -z $tag && -z $prog ]] && continue
		[[ $tag == \#* ]] && continue
		comment=$(trim "$comment")
		comment=${comment#\"}
		comment=${comment%\"}
		n=$((n + 1))
		case $tag in
			"" | X)
				echo "==> [$n/$total] $prog $comment"
				if ! [[ $prog =~ $re_pkg ]]; then warn "Bootstrap: invalid package name '$prog' skipped."; continue; fi
				install_available "programs list" "$prog"
				;;
			A)
				echo "==> [$n/$total] $prog (AUR) $comment"
				if ! [[ $prog =~ $re_pkg ]]; then warn "Bootstrap: invalid package name '$prog' skipped."; continue; fi
				if aur_on; then aur_install "$prog" || warn "Bootstrap: could not build $prog from the AUR."; fi
				;;
			G)
				name=${prog##*/}
				name=${name%.git}
				echo "==> [$n/$total] $name (git + make) $comment"
				if ! [[ $prog =~ $re_url && $name =~ $re_pkg ]]; then warn "Bootstrap: invalid git URL '$prog' skipped."; continue; fi
				as_user "$USER_NAME" mkdir -p "/home/$USER_NAME/.local/src" || true
				if [[ -d $TARGET/home/$USER_NAME/.local/src/$name/.git ]]; then
					as_user "$USER_NAME" git -C "/home/$USER_NAME/.local/src/$name" pull -q --ff-only || true
				elif ! as_user "$USER_NAME" git clone -q --depth 1 "$prog" "/home/$USER_NAME/.local/src/$name"; then
					warn "Bootstrap: cloning $prog failed."
					continue
				fi
				if ! { as_user "$USER_NAME" make -C "/home/$USER_NAME/.local/src/$name" &&
					in_target make -C "/home/$USER_NAME/.local/src/$name" install; }; then
					warn "Bootstrap: building $name failed."
				fi
				;;
			P)
				echo "==> [$n/$total] $prog (pipx) $comment"
				if ! [[ $prog =~ $re_pkg ]]; then warn "Bootstrap: invalid Python package '$prog' skipped."; continue; fi
				as_user "$USER_NAME" pipx install "$prog" || warn "Bootstrap: pipx install $prog failed."
				;;
			F)
				echo "==> [$n/$total] $prog (Flatpak) $comment"
				if ! [[ $prog =~ $re_pkg ]]; then warn "Bootstrap: invalid Flatpak id '$prog' skipped."; continue; fi
				in_target flatpak install -y --noninteractive flathub "$prog" || warn "Bootstrap: Flatpak $prog failed."
				;;
			*)
				warn "Bootstrap: unknown tag '$tag' for $prog skipped."
				;;
		esac
	done 9<"$csv"
	rm -f "$csv"
}

bs_dotfiles() {
	local tmp=/tmp/artix-install-dotfiles
	local -a br=()
	if [[ -n $BS_BRANCH ]]; then br=(-b "$BS_BRANCH"); fi
	echo "Copying dotfiles from $BS_DOTFILES into ~$USER_NAME ..."
	in_target pacman -S --needed --noconfirm git || true
	rm -rf "$TARGET$tmp"
	if as_user "$USER_NAME" git clone -q --depth 1 "${br[@]}" "$BS_DOTFILES" "$tmp" &&
		as_user "$USER_NAME" /bin/sh -c "tar -C $tmp --exclude=./.git --exclude=./README.md --exclude=./LICENSE --exclude=./FUNDING.yml -cf - . | tar -C ~ -xf -"; then
		echo "Dotfiles installed."
	else
		warn "Bootstrap: installing the dotfiles from $BS_DOTFILES failed."
	fi
	rm -rf "$TARGET$tmp"
}

bs_shell() {
	local path
	case $BS_SHELL in
		zsh) path=/usr/bin/zsh ;;
		fish) path=/usr/bin/fish ;;
		*) return 0 ;;
	esac
	echo "Setting the login shell of $USER_NAME to $BS_SHELL ..."
	if in_target pacman -S --needed --noconfirm "$BS_SHELL"; then
		in_target usermod -s "$path" "$USER_NAME" || warn "Bootstrap: could not set the login shell."
	else
		warn "Bootstrap: could not install $BS_SHELL."
	fi
}

bootstrap_wanted() { [[ -n $BS_PROGS || -n $DOTS || -n $BS_DOTFILES || $BS_SHELL != bash ]]; }

step_bootstrap_user() {
	if [[ -n $BS_PROGS ]]; then bs_install_progs; fi
	if [[ -n $DOTS ]]; then bs_presets; fi
	if [[ -n $BS_DOTFILES ]]; then bs_dotfiles; fi
	bs_shell
	aur_sudo_off
}

# ---- boot loader ------------------------------------------------------------
# Kernel command line. The encrypt hook reads cryptdevice= (and cryptkey= for
# the key file); the keymap is in the initramfs (keymap hook).
crypt_args() { # cryptdevice= (+ cryptkey= when a key file is in the initramfs)
	local c u
	u=$(get_uuid "$ROOT_PART")
	c="cryptdevice=UUID=$u:$CRYPT_NAME"
	if needs_keyfile; then c+=" cryptkey=rootfs:/etc/cryptsetup-keys.d/$CRYPT_NAME.key"; fi
	printf '%s' "$c"
}

boot_cmdline() {
	local c
	if zfs_on; then
		# Passed on by ZFSBootMenu, which adds root=zfs:<boot environment>.
		c=""
		if encrypted; then c="$(crypt_args) "; fi
		c+="rw loglevel=3"
		if [[ -n $(nvidia_driver) ]]; then c+=" nvidia_drm.modeset=1"; fi
		printf '%s\n' "$c"
		return 0
	fi
	if encrypted; then
		c="$(crypt_args) root=/dev/mapper/$CRYPT_NAME"
	else
		c="root=UUID=$(get_uuid "$(root_device)")"
	fi
	c+=" rw"
	if [[ $FS == btrfs ]]; then c+=" rootflags=subvol=/@"; fi
	c+=" loglevel=3"
	if [[ -n $(nvidia_driver) ]]; then c+=" nvidia_drm.modeset=1"; fi
	printf '%s\n' "$c"
}

# /usr/local/bin/artix-kernel-order: the boot order used by every boot loader,
# set by KERNEL_ORDER in /etc/default/kernel-order. Arch names the files after
# the package (/boot/vmlinuz-linux-lts), so each kernel has one entry.
write_kernel_order() { # write_kernel_order <root dir>
	local root=$1
	mkdir -p "$root/usr/local/bin" "$root/etc/default"
	cat >"$root/etc/default/kernel-order" <<EOF
# Boot order of the kernels (artix-install.sh). Package names, first = boots by
# default; the others follow in the boot menu. Installed kernels that are not
# listed come last. After a change, refresh the boot menu:
#   GRUB: grub-mkconfig -o /boot/grub/grub.cfg   Limine: update-limine
#   others: update-boot-menu
KERNEL_ORDER="$KERNELS"
EOF
	cat >"$root/usr/local/bin/artix-kernel-order" <<'EOF'
#!/bin/sh
# artix-kernel-order - list the installed kernels in boot order, one per line:
#     <package> <role>        role: default | lts | other
# Order: KERNEL_ORDER in /etc/default/kernel-order, then any other kernel in
# /boot. Installed by artix-install.sh; used by GRUB, Limine and update-boot-menu.
R="${ROOTDIR:-}"
case $R in
	.) R=$(pwd) ;;
	/) R="" ;;
esac
KERNEL_ORDER="linux linux-lts"
[ -r "$R/etc/default/kernel-order" ] && . "$R/etc/default/kernel-order"

kernels=$(
	for f in "$R"/usr/lib/modules/*/pkgbase; do
		[ -r "$f" ] && cat "$f"
	done | sort -u
)
[ -n "$kernels" ] || exit 0
seen=" "
n=0
emit() {
	case $seen in *" $1 "*) return 0 ;; esac
	seen="$seen$1 "
	n=$((n + 1))
	if [ "$n" = 1 ]; then r=default; elif [ "$1" = linux-lts ]; then r=lts; else r=other; fi
	echo "$1 $r"
}
for p in $KERNEL_ORDER; do
	case " $(echo $kernels) " in *" $p "*) emit "$p" ;; esac
done
for p in $kernels; do emit "$p"; done
EOF
	chmod 755 "$root/usr/local/bin/artix-kernel-order"
}

# pacman hook: run <command> after kernels are installed, updated or removed.
write_kernel_hook() { # write_kernel_hook <root> <name> <description> <command>
	mkdir -p "$1/etc/pacman.d/hooks"
	cat >"$1/etc/pacman.d/hooks/$2.hook" <<EOF
# artix-install.sh: $3
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Operation = Remove
Target = usr/lib/modules/*/vmlinuz

[Action]
Description = $3
When = PostTransaction
Exec = $4
EOF
}

GRUB_SB_MODULES="all_video boot btrfs cat chain configfile echo efifwsetup efinet ext2 fat font gettext gfxmenu gfxterm gfxterm_background gzio halt help iso9660 jpeg keystatus loadenv loopback linux ls lsefi lsefimmap lsefisystab memdisk minicmd normal part_gpt part_msdos password_pbkdf2 png probe reboot regexp search search_fs_uuid search_fs_file search_label serial sleep smbios test tpm true video cryptodisk luks luks2 gcry_rijndael gcry_sha256 gcry_sha512 pbkdf2"

install_grub() {
	local cfg="$TARGET/etc/default/grub" t first
	local -a sb=()
	if encrypted; then
		sed -i -E "s|^GRUB_CMDLINE_LINUX=\"[^\"]*\"|GRUB_CMDLINE_LINUX=\"$(crypt_args)\"|" "$cfg"
	fi
	if [[ -n $(nvidia_driver) ]]; then
		sed -i -E 's|^(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*)"|\1 nvidia_drm.modeset=1"|' "$cfg"
	fi
	if grub_unlocks; then
		if grep -qE '^#?GRUB_ENABLE_CRYPTODISK=' "$cfg"; then
			sed -i -E 's/^#?GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' "$cfg"
		else
			echo 'GRUB_ENABLE_CRYPTODISK=y' >>"$cfg"
		fi
	fi
	# Flat menu (no "Advanced options" submenu), so every kernel is visible;
	# the first kernel of the order on top.
	if grep -qE '^#?GRUB_DISABLE_SUBMENU=' "$cfg"; then
		sed -i -E 's/^#?GRUB_DISABLE_SUBMENU=.*/GRUB_DISABLE_SUBMENU=y/' "$cfg"
	else
		echo 'GRUB_DISABLE_SUBMENU=y' >>"$cfg"
	fi
	first=${KERNELS%% *}
	sed -i '/^GRUB_TOP_LEVEL=/d' "$cfg"
	echo "GRUB_TOP_LEVEL=\"/boot/vmlinuz-$first\"" >>"$cfg"
	write_grub_order "$TARGET"
	write_kernel_hook "$TARGET" 95-grub-menu "Updating the GRUB menu..." "/usr/bin/grub-mkconfig -o /boot/grub/grub.cfg"
	grep -E '^GRUB_(CMDLINE_LINUX|CMDLINE_LINUX_DEFAULT|ENABLE_CRYPTODISK|DISABLE_SUBMENU|TOP_LEVEL)=' "$cfg" || true

	if [[ $FIRMWARE == uefi ]]; then
		t=$(grub_efi_target)
		# With Secure Boot, GRUB cannot load modules from disk: build them in.
		if secureboot_on; then sb=(--modules="$GRUB_SB_MODULES" --disable-shim-lock); fi
		if ! in_target grub-install --target="$t" --efi-directory="$ESP_MOUNT" --bootloader-id=GRUB "${sb[@]}"; then
			warn "grub-install could not register a UEFI boot entry; installed without NVRAM entry (fallback path is used)."
			in_target grub-install --target="$t" --efi-directory="$ESP_MOUNT" --bootloader-id=GRUB --no-nvram "${sb[@]}"
		fi
		# Also install to the firmware fallback path \EFI\BOOT\ for picky firmware.
		in_target grub-install --target="$t" --efi-directory="$ESP_MOUNT" --removable "${sb[@]}"
	else
		in_target grub-install --target=i386-pc "$DISK"
	fi
}

# GRUB: default = first kernel of the order, fallback = the second.
write_grub_order() { # write_grub_order <root dir>
	local root=$1
	write_kernel_order "$root"
	mkdir -p "$root/etc/grub.d"
	cat >"$root/etc/grub.d/99_artix-kernel-order" <<'EOF'
#!/bin/sh
# Installed by artix-install.sh: boot the first kernel of the chosen order
# (/etc/default/kernel-order) by default and fall back to the second one if GRUB
# cannot load it. Never fail: an error here would stop grub-mkconfig.
lib="${pkgdatadir:-/usr/share/grub}/grub-mkconfig_lib"
[ -r "$lib" ] || exit 0
. "$lib"
order=$(ROOTDIR=/ /usr/local/bin/artix-kernel-order 2>/dev/null) || exit 0
[ -n "$order" ] || exit 0
id=$(grub_get_device_id "${GRUB_DEVICE}") || exit 0
[ -n "$id" ] || exit 0
def=$(echo "$order" | awk 'NR == 1 { print $1 }')
fb=$(echo "$order" | awk 'NR == 2 { print $1 }')
echo "# artix-install.sh: kernel order from /etc/default/kernel-order"
echo "if [ -z \"\${boot_once}\" ]; then"
echo "  set default=\"gnulinux-${def}-advanced-${id}\""
echo "fi"
if [ -n "$fb" ] && [ "$fb" != "$def" ]; then
	echo "set fallback=\"gnulinux-${fb}-advanced-${id}\""
fi
exit 0
EOF
	chmod 755 "$root/etc/grub.d/99_artix-kernel-order"
}

partuuid_of() { blkid -c /dev/null -s PARTUUID -o value "$1" 2>/dev/null || true; }

write_limine_tools() { # write_limine_tools <root dir>
	local root=$1 cmdline efi=BOOTX64.EFI bootpart
	cmdline=$(boot_cmdline)
	if [[ $EFI_BITS == 32 ]]; then efi=BOOTIA32.EFI; fi
	bootpart=${ESP_PART:-$BOOT_PART}
	write_kernel_order "$root"
	mkdir -p "$root/usr/local/bin" "$root/etc/default" "$root/etc/pacman.d/hooks"

	cat >"$root/etc/default/limine" <<EOF
# Settings for /usr/local/bin/update-limine, which rewrites
# /boot/limine/limine.conf whenever a kernel is installed or removed.
# After editing, run: update-limine
LIMINE_CMDLINE="$cmdline"
LIMINE_TIMEOUT=5
LIMINE_BRANDING="Artix Linux"

# Used to refresh the boot loader itself after the limine package was updated.
LIMINE_FIRMWARE=$FIRMWARE
LIMINE_EFI=$efi
LIMINE_BOOT_PARTUUID=$(partuuid_of "$bootpart")
LIMINE_BIOS_PART=$BIOSBOOT_NUM
EOF

	cat >"$root/usr/local/bin/update-limine" <<'EOF'
#!/bin/sh
# update-limine - regenerate the Limine boot menu from the installed kernels,
# and refresh the boot loader after a limine package update.
# Installed by artix-install.sh. Settings: /etc/default/limine
set -eu

R="${ROOTDIR:-}"
[ "$R" = "/" ] && R=""

LIMINE_CMDLINE="rw"
LIMINE_TIMEOUT=5
LIMINE_BRANDING="Artix Linux"
LIMINE_FIRMWARE=""
LIMINE_EFI=BOOTX64.EFI
LIMINE_BOOT_PARTUUID=""
LIMINE_BIOS_PART=""
[ -r "$R/etc/default/limine" ] && . "$R/etc/default/limine"

conf="$R/boot/limine/limine.conf"
mkdir -p "$R/boot/limine"

order=$(ROOTDIR="${R:-/}" "$R/usr/local/bin/artix-kernel-order" 2>/dev/null) || order=""
if [ -z "$order" ]; then
	echo "update-limine: no installed kernel found; $conf left unchanged" >&2
	exit 0
fi

{
	echo "# Generated by update-limine. Edit /etc/default/limine, then run update-limine."
	echo "# The first entry boots by default."
	echo "timeout: $LIMINE_TIMEOUT"
	echo "interface_branding: $LIMINE_BRANDING"
	echo "$order" | while read -r k role; do
		[ -e "$R/boot/vmlinuz-$k" ] || continue
		echo
		echo "/$LIMINE_BRANDING ($k)"
		echo "    protocol: linux"
		echo "    path: boot():/vmlinuz-$k"
		echo "    module_path: boot():/initramfs-$k.img"
		echo "    cmdline: $LIMINE_CMDLINE"
	done
} >"$conf.tmp"
mv -f "$conf.tmp" "$conf"
echo "update-limine: wrote $conf ($(echo "$order" | wc -l) entries)"

# Keep the boot loader itself current: after a limine update the copies on /boot
# (and, on BIOS, the boot code on the disk) are still the old version.
refresh_loader() {
	src="$R/usr/share/limine"
	case $LIMINE_FIRMWARE in
		uefi)
			[ -f "$src/$LIMINE_EFI" ] || return 0
			main="$R/boot/EFI/limine/$LIMINE_EFI"
			fb="$R/boot/EFI/BOOT/$LIMINE_EFI"
			[ -f "$main" ] || return 0
			cmp -s "$src/$LIMINE_EFI" "$main" && return 0
			if [ -f "$fb" ] && cmp -s "$main" "$fb"; then
				cp -f "$src/$LIMINE_EFI" "$fb"
				echo "update-limine: refreshed ${fb#"$R"}"
			fi
			cp -f "$src/$LIMINE_EFI" "$main"
			echo "update-limine: refreshed ${main#"$R"}"
			;;
		bios)
			[ -f "$src/limine-bios.sys" ] || return 0
			sys="$R/boot/limine/limine-bios.sys"
			if [ -f "$sys" ] && cmp -s "$src/limine-bios.sys" "$sys"; then return 0; fi
			if [ -n "$R" ]; then
				echo "update-limine: the boot loader on the disk is out of date; run update-limine inside the system" >&2
				return 0
			fi
			pk=""
			if [ -n "$LIMINE_BOOT_PARTUUID" ] && [ -e "/dev/disk/by-partuuid/$LIMINE_BOOT_PARTUUID" ]; then
				pk=$(lsblk -no PKNAME "$(readlink -f "/dev/disk/by-partuuid/$LIMINE_BOOT_PARTUUID")" 2>/dev/null | head -n 1)
			fi
			if [ -z "$pk" ] || [ -z "$LIMINE_BIOS_PART" ]; then
				echo "update-limine: cannot find the boot disk; run: limine bios-install <disk> <BIOS boot partition number> && cp $src/limine-bios.sys /boot/limine/" >&2
				return 0
			fi
			cp -f "$src/limine-bios.sys" "$sys.new"
			if limine bios-install "/dev/$pk" "$LIMINE_BIOS_PART"; then
				mv -f "$sys.new" "$sys"
				echo "update-limine: refreshed the BIOS boot code on /dev/$pk and limine-bios.sys"
			else
				rm -f "$sys.new"
				echo "update-limine: 'limine bios-install /dev/$pk $LIMINE_BIOS_PART' failed; the old boot loader was kept" >&2
				return 1
			fi
			;;
	esac
}
refresh_loader
EOF
	chmod 755 "$root/usr/local/bin/update-limine"

	write_kernel_hook "$root" 95-limine-menu "Updating the Limine menu..." /usr/local/bin/update-limine
	# pacman can watch a package: refresh Limine itself when it is updated.
	cat >"$root/etc/pacman.d/hooks/95-limine-refresh.hook" <<'EOF'
# artix-install.sh: copy the updated Limine boot loader to /boot.
[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Target = limine

[Action]
Description = Refreshing the Limine boot loader...
When = PostTransaction
Exec = /usr/local/bin/update-limine
EOF
}

# register_efi "<label>" '\EFI\dir\file.efi' - (re)create one UEFI boot entry.
register_efi() { # register_efi "<label>" '<loader>' ["<kernel arguments>"]
	in_target /bin/bash -s -- "$DISK" "$ESP_NUM" "$1" "$2" "${3:-}" <<'EOS'
disk=$1 part=$2 label=$3 loader=$4 args=$5
efibootmgr 2>/dev/null | while IFS= read -r line; do
	if [[ $line =~ ^Boot([0-9A-Fa-f]{4})\*?[[:space:]](.*)$ ]]; then
		num=${BASH_REMATCH[1]} name=${BASH_REMATCH[2]%%$'\t'*}
		if [[ $name == "$label" ]]; then efibootmgr -q -b "$num" -B || true; fi
	fi
done
if [[ -n $args ]]; then
	efibootmgr -q -c -d "$disk" -p "$part" -L "$label" -l "$loader" -u "$args"
else
	efibootmgr -q -c -d "$disk" -p "$part" -L "$label" -l "$loader"
fi
EOS
}

efi_entry() { # efi_entry "<label>" '<loader>' '<fallback path>' ["<kernel arguments>"]
	if register_efi "$1" "$2" "${4:-}"; then
		echo "UEFI boot entry '$1' created."
	else
		warn "Could not create the UEFI boot entry '$1'; the firmware fallback $3 will be used."
	fi
}

# Settings, /usr/local/bin/update-boot-menu and its pacman hook, for
# rEFInd, EFISTUB and SYSLINUX.
write_boot_tools() { # write_boot_tools <root dir>
	local root=$1 partuuid="" esp=/boot
	write_kernel_order "$root"
	if [[ -n $ESP_PART ]]; then
		partuuid=$(partuuid_of "$ESP_PART")
		esp=$ESP_MOUNT
	fi
	mkdir -p "$root/usr/local/bin" "$root/etc/default"

	cat >"$root/etc/default/artix-boot" <<EOF
# Settings for /usr/local/bin/update-boot-menu, which rewrites the boot entries
# whenever a kernel is installed, updated or removed. After editing, run:
#     update-boot-menu
BOOT_METHOD=$BOOTLOADER
BOOT_CMDLINE="$(boot_cmdline)"
BOOT_TIMEOUT=5
BOOT_BRAND="Artix Linux"
ESP=$esp
ESP_PARTUUID=$partuuid
ESP_DISK=$DISK
ESP_PARTNUM=$ESP_NUM
EFI_ARCH=$(efi_arch)
EOF

	cat >"$root/usr/local/bin/update-boot-menu" <<'EOF'
#!/bin/sh
# update-boot-menu - regenerate the boot entries for rEFInd, EFISTUB or
# SYSLINUX in the kernel order (/etc/default/kernel-order).
# Installed by artix-install.sh. Settings: /etc/default/artix-boot
set -eu

R="${ROOTDIR:-}"
case $R in .) R=$(pwd) ;; esac
[ "$R" = "/" ] && R=""

BOOT_METHOD=""
BOOT_CMDLINE="rw"
BOOT_TIMEOUT=5
BOOT_BRAND="Artix Linux"
ESP=/boot
ESP_PARTUUID=""
ESP_DISK=""
ESP_PARTNUM=""
EFI_ARCH=x64
[ -r "$R/etc/default/artix-boot" ] && . "$R/etc/default/artix-boot"
E="$R$ESP"

say() { echo "update-boot-menu: $*"; }

order=$(ROOTDIR="${R:-/}" "$R/usr/local/bin/artix-kernel-order" 2>/dev/null) || order=""
if [ -z "$order" ]; then
	say "no installed kernel found; nothing changed" >&2
	exit 0
fi
def=$(echo "$order" | awk 'NR == 1 { print $1 }')

title_of() { echo "$BOOT_BRAND ($1)"; }


# ---- rEFInd: manual stanzas in artix-entries.conf (included by refind.conf) --
refind_menu() {
	found=0
	for d in "$E/EFI/refind" "$E/EFI/BOOT"; do
		[ -f "$d/refind.conf" ] || continue
		found=1
		icon=""
		if [ -f "$d/icons/os_arch.png" ]; then icon="${d#"$E"}/icons/os_arch.png"; fi
		{
			echo "# Generated by update-boot-menu. Settings: /etc/default/artix-boot"
			while read -r k role; do
				[ -e "$R/boot/vmlinuz-$k" ] || continue
				echo
				echo "menuentry \"$(title_of "$k")\" {"
				if [ -n "$icon" ]; then echo "    icon    $icon"; fi
				echo "    loader  /vmlinuz-$k"
				echo "    initrd  /initramfs-$k.img"
				echo "    options \"$BOOT_CMDLINE\""
				echo "}"
			done <<EOT
$order
EOT
		} >"$d/artix-entries.conf.tmp"
		mv -f "$d/artix-entries.conf.tmp" "$d/artix-entries.conf"
	done
	if [ "$found" = 0 ]; then
		say "no refind.conf in $E/EFI/refind or $E/EFI/BOOT" >&2
		exit 1
	fi
}

# ---- UEFI boot entries (EFISTUB) --------------------------------------------
esp_target() { # sets ESP_DISK and ESP_PARTNUM
	if [ -n "$ESP_PARTUUID" ] && [ -e "/dev/disk/by-partuuid/$ESP_PARTUUID" ]; then
		dev=$(readlink -f "/dev/disk/by-partuuid/$ESP_PARTUUID")
		name=${dev##*/}
		pk=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -n 1)
		if [ -n "$pk" ] && [ -r "/sys/class/block/$name/partition" ]; then
			ESP_DISK=/dev/$pk
			ESP_PARTNUM=$(cat "/sys/class/block/$name/partition")
		fi
	fi
	if [ -z "$ESP_DISK" ] || [ -z "$ESP_PARTNUM" ]; then
		say "cannot find the EFI system partition (ESP_PARTUUID=$ESP_PARTUUID)" >&2
		return 1
	fi
}

efi_list() { # "<num> <label>" for every UEFI boot entry
	efibootmgr | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\)\*\{0,1\}[[:space:]]\{1,\}\(.*\)$/\1 \2/p' | cut -f 1
}

efi_entries() { # efi_entries stub
	esp_target || return 1
	old=$(efi_list) || return 1
	echo "$old" | while read -r num lbl; do
		case $lbl in
			"$BOOT_BRAND (linux"*) efibootmgr -q -b "$num" -B || exit 1 ;;
		esac
	done || return 1
	ours=""
	while read -r k role; do
		lbl=$(title_of "$k")
		[ -e "$R/boot/vmlinuz-$k" ] || continue
		efibootmgr -q -c -d "$ESP_DISK" -p "$ESP_PARTNUM" -L "$lbl" -l "\\vmlinuz-$k" \
			-u "initrd=\\initramfs-$k.img $BOOT_CMDLINE" || return 1
		num=$(efi_list | awk -v l="$lbl" '{ n = $1; sub(/^[^ ]+ /, ""); if ($0 == l) print n }' | tail -n 1)
		if [ -n "$num" ]; then ours="$ours${ours:+,}$num"; fi
	done <<EOT
$order
EOT
	cur=$(efibootmgr | sed -n 's/^BootOrder:[[:space:]]*//p')
	new=$ours
	for b in $(echo "$cur" | tr ',' ' '); do
		case ",$ours," in
			*",$b,"*) ;;
			*) new="$new${new:+,}$b" ;;
		esac
	done
	if [ -n "$new" ]; then efibootmgr -q -o "$new" || return 1; fi
	say "UEFI boot order: $new"
}


# ---- SYSLINUX / EXTLINUX -----------------------------------------------------
syslinux_menu() {
	d="$R/boot/syslinux"
	mkdir -p "$d"
	t=$((BOOT_TIMEOUT * 10))
	[ "$t" -gt 0 ] || t=1
	{
		echo "# Generated by update-boot-menu. Settings: /etc/default/artix-boot"
		if [ -f "$d/menu.c32" ]; then
			echo "UI menu.c32"
			echo "MENU TITLE $BOOT_BRAND"
		else
			echo "PROMPT 1"
		fi
		echo "TIMEOUT $t"
		echo "DEFAULT arch1"
		n=0
		while read -r k role; do
			[ -e "$R/boot/vmlinuz-$k" ] || continue
			n=$((n + 1))
			echo
			echo "LABEL arch$n"
			echo "    MENU LABEL $(title_of "$k")"
			echo "    LINUX /vmlinuz-$k"
			echo "    INITRD /initramfs-$k.img"
			echo "    APPEND $BOOT_CMDLINE"
		done <<EOT
$order
EOT
	} >"$d/syslinux.cfg.tmp"
	mv -f "$d/syslinux.cfg.tmp" "$d/syslinux.cfg"
}

case $BOOT_METHOD in
	refind) refind_menu ;;
	efistub) efi_entries stub ;;
	syslinux) syslinux_menu ;;
	*)
		say "unknown BOOT_METHOD '$BOOT_METHOD' in /etc/default/artix-boot" >&2
		exit 1
		;;
esac
say "$BOOT_METHOD: $(echo "$order" | wc -l) kernel(s), default $def"
EOF
	chmod 755 "$root/usr/local/bin/update-boot-menu"
	write_kernel_hook "$root" 95-boot-menu "Updating the boot menu..." /usr/local/bin/update-boot-menu
}

# ---- Secure Boot (sbctl) -----------------------------------------------------------
SB_ENROLLED=0

sb_setup_mode() { # (output captured first: "cmd | grep -q" can fail under pipefail)
	local out
	out=$(in_target sbctl status --json 2>/dev/null) || true
	grep -Eq '"setup_mode": *true' <<<"$out"
}

# Keys first, then the boot loader and kernels are signed once installed.
sb_prepare() {
	secureboot_on || return 0
	echo "Secure Boot: creating your own keys (sbctl) ..."
	in_target sbctl create-keys
}

# Sign everything the firmware loads, register it for re-signing (-s), enroll.
sb_sign_all() {
	local e="$ESP_MOUNT" k f
	local -a files=()
	secureboot_on || return 0
	case $BOOTLOADER in
		refind) files+=("$e/EFI/refind/refind_x64.efi" "$e/EFI/BOOT/BOOTX64.EFI") ;;
		grub) files+=("$e/EFI/GRUB/grubx64.efi" "$e/EFI/BOOT/BOOTX64.EFI") ;;
	esac
	for k in $KERNELS; do files+=("/boot/vmlinuz-$k"); done
	for f in "${files[@]}"; do
		if [[ -e $TARGET$f ]]; then
			in_target sbctl sign -s "$f" || warn "Secure Boot: could not sign $f"
		fi
	done
	if sb_setup_mode; then
		echo "Secure Boot: the firmware is in Setup Mode; enrolling your keys (with Microsoft's, for option ROMs) ..."
		if in_target sbctl enroll-keys -m; then
			SB_ENROLLED=1
		else
			warn "Secure Boot: enrolling the keys failed. After booting, run: sudo sbctl enroll-keys -m"
		fi
	else
		warn "Secure Boot: the firmware is not in Setup Mode, so your keys were made and everything is signed, but not enrolled. Put Secure Boot in Setup Mode in the firmware settings, boot the new system, run: sudo sbctl enroll-keys -m   then turn Secure Boot on."
	fi
	in_target sbctl verify || true
	if [[ $SB_ENROLLED == 1 ]]; then
		echo "Secure Boot: keys enrolled. Turn Secure Boot on in the firmware settings after the first boot."
	fi
}

# ---- snapper ---------------------------------------------------------------------
# snapper's create-config makes its own /.snapshots subvolume inside @; use the
# @snapshots subvolume instead (mounted at /.snapshots by fstab), so rolling
# back @ keeps the snapshots.
# snapper's timeline and cleanup are systemd timers upstream; on Artix cron
# runs them (cronie). Skipped if the snapper package brought its own cron jobs.
write_snapper_cron() { # write_snapper_cron <root dir>
	local root=$1
	if compgen -G "$root/etc/cron.hourly/*snapper*" >/dev/null; then
		echo "snapper: its own cron jobs are installed."
		return 0
	fi
	mkdir -p "$root/etc/cron.hourly" "$root/etc/cron.daily"
	printf '#!/bin/sh\n# artix-install.sh: hourly snapper timeline snapshot (instead of snapper-timeline.timer)\nexec snapper --no-dbus -c root create -c timeline -d timeline\n' \
		>"$root/etc/cron.hourly/artix-snapper-timeline"
	# shellcheck disable=SC2016  # $a is for the cron script
	printf '#!/bin/sh\n# artix-install.sh: daily snapper cleanup (instead of snapper-cleanup.timer)\nfor a in number timeline empty-pre-post; do snapper --no-dbus -c root cleanup "$a"; done\n' \
		>"$root/etc/cron.daily/artix-snapper-cleanup"
	chmod 755 "$root/etc/cron.hourly/artix-snapper-timeline" "$root/etc/cron.daily/artix-snapper-cleanup"
}

setup_snapper() {
	local rootdev cfg="$TARGET/etc/snapper/configs/root"
	snapper_on || return 0
	rootdev=$(root_device)
	echo "Setting up snapper for / ..."
	umount "$TARGET/.snapshots"
	rmdir "$TARGET/.snapshots"
	in_target snapper --no-dbus -c root create-config /
	btrfs subvolume delete "$TARGET/.snapshots"
	mkdir "$TARGET/.snapshots"
	mount -o "$BTRFS_OPTS,subvol=@snapshots" "$rootdev" "$TARGET/.snapshots"
	chmod 750 "$TARGET/.snapshots"
	sed -i -E \
		-e 's/^ALLOW_GROUPS=.*/ALLOW_GROUPS="wheel"/' \
		-e 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="10"/' \
		-e 's/^NUMBER_LIMIT_IMPORTANT=.*/NUMBER_LIMIT_IMPORTANT="5"/' \
		-e 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/' \
		-e 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' \
		-e 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="0"/' \
		-e 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="0"/' \
		-e 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' "$cfg"
	write_snapper_cron "$TARGET"
	if [[ $BOOTLOADER == grub ]]; then
		# grub-btrfsd adds new snapshots to GRUB's menu as they appear.
		service_for grub-btrfs grub-btrfsd "/usr/bin/grub-btrfsd --syslog /.snapshots"
		svc_commit
	fi
	echo "snapper: snapshots before/after every pacman transaction (snap-pac), hourly timeline (cron)."
}

# ---- ZFSBootMenu -----------------------------------------------------------------
# Its release images cannot unlock LUKS, so it is built on the new system from
# the pinned release, with mkinitcpio's encrypt hook: it asks for the
# passphrase, imports the pool, lists the boot environments and snapshots, and
# starts the chosen kernel (kexec). The system's initramfs unlocks the disk
# again with the key file (it lies inside the encrypted pool, unlike
# ZFSBootMenu's initramfs on the EFI system partition, which holds no key).
# Artix has no systemd EFI stub to bundle one EFI file, so ZFSBootMenu is a
# kernel + initramfs pair that the firmware starts directly (EFISTUB).
ZBM_DIR='\EFI\zbm'

zbm_kernel() {
	if has "$KERNELS" linux-lts; then echo linux-lts; else echo "${KERNELS%% *}"; fi
}

zbm_cmdline() {
	local c="quiet loglevel=0"
	if encrypted; then c="cryptdevice=UUID=$(get_uuid "$ROOT_PART"):$CRYPT_NAME $c"; fi
	printf '%s\n' "$c"
}

write_zbm_config() { # write_zbm_config <root dir>
	local root=$1 hooks="base udev modconf block keyboard keymap"
	if encrypted; then hooks+=" encrypt"; fi
	hooks+=" filesystems"
	mkdir -p "$root/etc/zfsbootmenu/generate-zbm.post.d"
	cat >"$root/etc/zfsbootmenu/config.yaml" <<EOF
# Written by artix-install.sh. After editing, run: generate-zbm
Global:
  ManageImages: true
  BootMountPoint: $ESP_MOUNT
  InitCPIO: true
  InitCPIOConfig: /etc/zfsbootmenu/mkinitcpio.conf
  PostHooksDir: /etc/zfsbootmenu/generate-zbm.post.d
Components:
  ImageDir: $ESP_MOUNT/EFI/zbm
  Versions: false
  Enabled: true
EFI:
  Enabled: false
Kernel:
  Path: /boot/vmlinuz-$(zbm_kernel)
  Prefix: vmlinuz
EOF
	# Not /etc/mkinitcpio.conf: ZFSBootMenu's image must not get the system's
	# FILES (the key file). mkinitcpio --config reads no drop-in directory.
	cat >"$root/etc/zfsbootmenu/mkinitcpio.conf" <<EOF
# Written by artix-install.sh: the initramfs of ZFSBootMenu itself. Holds no
# key: it lies on the unencrypted EFI system partition. (generate-zbm adds
# the zfsbootmenu hook.)
MODULES=()
BINARIES=()
FILES=()
HOOKS=($hooks)
COMPRESSION=zstd
EOF
	mkdir -p "$root/etc/pacman.d/hooks"
	cat >"$root/etc/pacman.d/hooks/95-zfsbootmenu.hook" <<'EOF'
# artix-install.sh: rebuild ZFSBootMenu after kernel or ZFS updates
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/modules/*/vmlinuz

[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Target = zfs-utils
Target = zfs-dkms
Target = zfs-linux*

[Action]
Description = Rebuilding ZFSBootMenu...
When = PostTransaction
Exec = /usr/bin/generate-zbm
EOF
}

install_zfsbootmenu() {
	local src=/var/tmp/zfsbootmenu-src head first
	echo "Building ZFSBootMenu $ZBM_VERSION ..."
	rm -rf "$TARGET$src"
	in_target git clone -q --depth 1 --branch "v$ZBM_VERSION" "$ZBM_GIT" "$src"
	head=$(in_target git -C "$src" rev-parse HEAD)
	if [[ $head != "$ZBM_COMMIT" ]]; then
		echo "ZFSBootMenu v$ZBM_VERSION is commit $head, expected $ZBM_COMMIT; not installing it." >&2
		return 1
	fi
	tools_add make
	in_target make -C "$src" install
	rm -rf "$TARGET$src"
	tools_remove
	write_zbm_config "$TARGET"
	first=${KERNELS%% *}
	# What ZFSBootMenu passes to the system's kernel; it adds root=zfs:<dataset>.
	# Set on zroot/ROOT, so every boot environment and snapshot clone inherits it.
	zfs set org.zfsbootmenu:commandline="$(boot_cmdline)" "$ZPOOL/ROOT"
	zfs set org.zfsbootmenu:kernel="vmlinuz-$first" "$ZPOOL/ROOT"
	in_target generate-zbm
	# The kernel arguments travel in the boot entry (the firmware passes them).
	if ! register_efi "ZFSBootMenu" "$ZBM_DIR\\vmlinuz-bootmenu" "$(zbm_cmdline) initrd=$ZBM_DIR\\initramfs-bootmenu.img"; then
		echo "Could not create the UEFI boot entry for ZFSBootMenu; without it the computer cannot start." >&2
		return 1
	fi
	echo "UEFI boot entry 'ZFSBootMenu' created."
	echo "ZFSBootMenu: boots $ZFS_BE with $first; other kernels and snapshots from its menu."
}

verify_zfsbootmenu() {
	local d="$ESP_MOUNT/EFI/zbm" listing f
	for f in "$d/vmlinuz-bootmenu" "$d/initramfs-bootmenu.img"; do
		if [[ ! -s $TARGET$f ]]; then
			echo "ZFSBootMenu: $f was not built" >&2
			return 1
		fi
	done
	f=$(in_target efibootmgr 2>/dev/null) || true
	if ! grep -q 'ZFSBootMenu' <<<"$f"; then
		echo "ZFSBootMenu: no UEFI boot entry" >&2
		return 1
	fi
	if [[ $(zpool get -H -o value bootfs "$ZPOOL") != "$ZFS_BE" ]]; then
		echo "ZFS: bootfs of $ZPOOL is not $ZFS_BE" >&2
		return 1
	fi
	if [[ ! -s $TARGET/etc/hostid ]]; then
		echo "ZFS: /etc/hostid is missing" >&2
		return 1
	fi
	if encrypted; then
		# The initramfs on the unencrypted EFI partition must not hold the key file.
		if ! listing=$(in_target lsinitcpio "$d/initramfs-bootmenu.img" 2>/dev/null); then
			warn "Could not look inside ZFSBootMenu's initramfs."
		elif grep -q 'cryptsetup-keys.d' <<<"$listing"; then
			rm -f "$TARGET$d/initramfs-bootmenu.img" "$TARGET$d/vmlinuz-bootmenu"
			echo "ZFSBootMenu: its initramfs contains the disk key file; removed it" >&2
			return 1
		elif ! grep -q 'cryptsetup' <<<"$listing"; then
			echo "ZFSBootMenu: its initramfs has no cryptsetup (encrypt hook)" >&2
			return 1
		else
			echo "OK: ZFSBootMenu unlocks LUKS and holds no key file"
		fi
	fi
	echo "OK: ZFSBootMenu ($d), boot environment $ZFS_BE"
}


install_refind() {
	local a src d e="$TARGET$ESP_MOUNT"
	a=$(efi_arch)
	src="$TARGET/usr/share/refind/refind_$a.efi"
	if [[ ! -f $src ]]; then
		echo "refind_$a.efi is missing from the refind package." >&2
		return 1
	fi
	write_boot_tools "$TARGET"
	for d in refind BOOT; do
		mkdir -p "$e/EFI/$d"
		if [[ -d $TARGET/usr/share/refind/icons ]]; then
			rm -rf "$e/EFI/$d/icons"
			cp -r "$TARGET/usr/share/refind/icons" "$e/EFI/$d/icons"
		fi
		cat >"$e/EFI/$d/refind.conf" <<'EOF'
# rEFInd configuration - written by artix-install.sh.
# The kernels are listed in artix-entries.conf, which update-boot-menu
# rewrites on every kernel change, in the order of /etc/default/kernel-order.
# Options: /usr/share/refind/refind.conf-sample
timeout 5
scanfor manual,external,optical
default_selection 1
include artix-entries.conf
EOF
	done
	cp "$src" "$e/EFI/refind/refind_$a.efi"
	cp "$src" "$e/EFI/BOOT/BOOT${a^^}.EFI"   # firmware fallback path
	efi_entry "Artix Linux (rEFInd)" "\\EFI\\refind\\refind_$a.efi" "\\EFI\\BOOT\\BOOT${a^^}.EFI"
	in_target /usr/local/bin/update-boot-menu
}

install_efistub() {
	write_boot_tools "$TARGET"
	echo "Creating one UEFI boot entry per kernel ..."
	in_target /usr/local/bin/update-boot-menu
}



syslinux_dir() { # directory holding the BIOS files of the syslinux package
	local d
	for d in "$TARGET/usr/lib/syslinux/bios" "$TARGET/usr/lib/syslinux"; do
		if [[ -f $d/gptmbr.bin ]]; then
			printf '%s\n' "$d"
			return 0
		fi
	done
	return 1
}

install_syslinux() {
	local d m
	if ! d=$(syslinux_dir); then
		echo "gptmbr.bin was not found in the syslinux package." >&2
		return 1
	fi
	write_boot_tools "$TARGET"
	mkdir -p "$TARGET/boot/syslinux"
	in_target extlinux --install /boot/syslinux
	for m in menu.c32 libutil.c32 libcom32.c32; do
		if [[ -f $d/$m ]]; then cp "$d/$m" "$TARGET/boot/syslinux/$m"; fi
	done
	echo "Writing SYSLINUX's GPT boot code (gptmbr.bin) to $DISK ..."
	dd bs=440 count=1 conv=notrunc if="$d/gptmbr.bin" of="$DISK" status=none
	in_target /usr/local/bin/update-boot-menu
}

install_limine() {
	local efi
	write_limine_tools "$TARGET"
	mkdir -p "$TARGET/boot/limine"
	if [[ $FIRMWARE == uefi ]]; then
		efi=BOOTX64.EFI
		if [[ $EFI_BITS == 32 ]]; then efi=BOOTIA32.EFI; fi
		if [[ ! -f $TARGET/usr/share/limine/$efi ]]; then
			echo "$efi is missing from the limine package." >&2
			return 1
		fi
		mkdir -p "$TARGET/boot/EFI/limine" "$TARGET/boot/EFI/BOOT"
		cp "$TARGET/usr/share/limine/$efi" "$TARGET/boot/EFI/limine/$efi"
		cp "$TARGET/usr/share/limine/$efi" "$TARGET/boot/EFI/BOOT/$efi"   # firmware fallback path
		efi_entry "Artix Linux (Limine)" "\\EFI\\limine\\$efi" "\\EFI\\BOOT\\$efi"
	else
		cp "$TARGET/usr/share/limine/limine-bios.sys" "$TARGET/boot/limine/limine-bios.sys"
		in_target limine bios-install "$DISK" "$BIOSBOOT_NUM"
	fi
	in_target /usr/local/bin/update-limine
}

step_bootloader() {
	write_mkinitcpio_conf
	trim_mkinitcpio_presets
	sb_prepare
	echo "Building the initramfs ..."
	in_target mkinitcpio -P
	case $BOOTLOADER in
		grub) install_grub ;;
		limine) install_limine ;;
		refind) install_refind ;;
		efistub) install_efistub ;;
		syslinux) install_syslinux ;;
		zfsbootmenu) install_zfsbootmenu ;;
	esac
	sb_sign_all
}

# ---- finish -------------------------------------------------------------------
verify_boot_menu() {
	local e="$TARGET${ESP_MOUNT:-/boot}" f
	case $BOOTLOADER in
		refind)
			if ! grep -q '^menuentry' "$e/EFI/refind/artix-entries.conf" 2>/dev/null; then
				echo "rEFInd: artix-entries.conf has no entries" >&2
				return 1
			fi
			echo "OK: rEFInd, $(grep -c '^menuentry' "$e/EFI/refind/artix-entries.conf") entries"
			;;
		efistub)
			f=$(in_target efibootmgr 2>/dev/null) || true
			if ! grep -q 'Artix Linux (linux' <<<"$f"; then
				echo "EFISTUB: no 'Artix Linux (<kernel>)' UEFI boot entry exists" >&2
				return 1
			fi
			echo "OK: EFISTUB boot entries"
			;;
		syslinux)
			if ! grep -q '^ *LINUX /vmlinuz-' "$TARGET/boot/syslinux/syslinux.cfg" 2>/dev/null; then
				echo "SYSLINUX: syslinux.cfg has no entries" >&2
				return 1
			fi
			if [[ ! -f $TARGET/boot/syslinux/ldlinux.sys ]]; then
				echo "SYSLINUX: extlinux did not install ldlinux.sys" >&2
				return 1
			fi
			echo "OK: /boot/syslinux/syslinux.cfg"
			;;
	esac
}

verify_install() {
	local k img listing
	for k in $KERNELS; do
		if [[ ! -s $TARGET/boot/vmlinuz-$k ]]; then
			echo "Kernel $k is missing from /boot" >&2
			return 1
		fi
		img="/boot/initramfs-$k.img"
		if [[ ! -s $TARGET$img ]]; then
			echo "Missing $img for kernel $k" >&2
			return 1
		fi
		if zfs_on; then
			listing=$(in_target lsinitcpio "$img")
			if ! grep -q 'hooks/zfs' <<<"$listing"; then
				echo "$img does not contain the zfs hook" >&2
				return 1
			fi
			if encrypted && ! grep -q 'hooks/encrypt' <<<"$listing"; then
				echo "$img does not contain the encrypt hook" >&2
				return 1
			fi
			if needs_keyfile && ! grep -q "etc/cryptsetup-keys.d/$CRYPT_NAME.key" <<<"$listing"; then
				echo "$img does not contain the LUKS key file" >&2
				return 1
			fi
		elif encrypted; then
			listing=$(in_target lsinitcpio "$img")
			if ! grep -q 'hooks/encrypt' <<<"$listing"; then
				echo "$img does not contain the encrypt hook" >&2
				return 1
			fi
			if grub_unlocks && ! grep -q "etc/cryptsetup-keys.d/$CRYPT_NAME.key" <<<"$listing"; then
				echo "$img does not contain the LUKS key file" >&2
				return 1
			fi
		fi
		echo "OK: kernel $k with ${img##*/}"
	done
	case $BOOTLOADER in
		grub)
			if ! grep -q 'vmlinuz' "$TARGET/boot/grub/grub.cfg"; then
				echo "grub.cfg contains no kernel entries" >&2
				return 1
			fi
			if grub_unlocks && ! grep -q 'cryptomount' "$TARGET/boot/grub/grub.cfg"; then
				echo "grub.cfg does not unlock the encrypted disk (cryptomount missing)" >&2
				return 1
			fi
			echo "OK: /boot/grub/grub.cfg"
			;;
		limine)
			if ! grep -q 'protocol: linux' "$TARGET/boot/limine/limine.conf"; then
				echo "limine.conf contains no entries" >&2
				return 1
			fi
			echo "OK: /boot/limine/limine.conf"
			;;
		zfsbootmenu) verify_zfsbootmenu ;;
		*) verify_boot_menu ;;
	esac
}

step_finalize() {
	setup_snapper
	echo "Refreshing the boot menu ..."
	case $BOOTLOADER in
		grub) in_target grub-mkconfig -o /boot/grub/grub.cfg ;;
		limine) in_target /usr/local/bin/update-limine ;;
		zfsbootmenu) : ;; # built by install_zfsbootmenu; finds the kernels itself
		*) in_target /usr/local/bin/update-boot-menu ;;
	esac
	verify_install
	echo "Boot order (first = default):"
	in_target /usr/local/bin/artix-kernel-order | awk '{ printf "    %d. %s%s\n", NR, $1, (NR == 1 ? "  <- default" : "") }' || true
	rm -f "$TARGET$AUR_SUDOERS"
	if snapper_on; then
		in_target snapper --no-dbus -c root create -d "after artix-install.sh" || true
	fi
	if zfs_on; then
		if zfs_snap_on; then zfs_snapshot_hook "$TARGET"; fi
		# The freshly installed system, bootable from ZFSBootMenu's snapshot list.
		zfs snapshot "$ZFS_BE@install" || warn "Could not snapshot $ZFS_BE."
	fi
	cp "$LOG" "$TARGET/var/log/artix-install.log" 2>/dev/null || true
	# The settings of this install as a preset, to install the same system again.
	if [[ -d $TARGET/root ]]; then
		preset_write "$TARGET/root/artix-install.preset" "${PRESET_LABEL:-$(printf '%s' "${HOST_NAME,,}" | tr -c 'a-z0-9._-' '-')}" 2>/dev/null || true
	fi
	chmod 600 "$TARGET/var/log/artix-install.log" 2>/dev/null || true
	sync
}

# =============================================================================
#  Installation driver
# =============================================================================
cleanup_target() {
	sync
	if mountpoint -q "$TARGET" 2>/dev/null; then
		umount -R "$TARGET" 2>/dev/null || umount -Rl "$TARGET" 2>/dev/null || true
	fi
	if zfs_on && command -v zpool >/dev/null && zpool list "$ZPOOL" >/dev/null 2>&1; then
		zpool export "$ZPOOL" 2>/dev/null || zpool export -f "$ZPOOL" 2>/dev/null || true
	fi
	if [[ -e /dev/mapper/$CRYPT_NAME ]]; then
		local i
		for i in 1 2 3 4 5; do
			cryptsetup close "$CRYPT_NAME" 2>/dev/null && break
			sleep 1
		done
	fi
	INSTALL_STARTED=0
}

# Run one installation step in a subshell with strict error handling, showing
# its output live in a dialog progress box and appending it to $LOG.
# Must be called as a plain command (never inside if/while/&&/||), or bash
# disables "set -e" inside the step.
run_step() { # run_step "title" function
	local title=$1 fn=$2 rows=24 cols=80 size
	size=$(stty size </dev/tty 2>/dev/null) || size=""
	if [[ $size =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
		rows=${BASH_REMATCH[1]}
		cols=${BASH_REMATCH[2]}
	fi
	((rows >= 12)) || rows=24
	((cols >= 50)) || cols=80
	printf '\n===== %s =====\n' "$title" >>"$LOG"
	(
		set -Eeuo pipefail
		shopt -s inherit_errexit
		trap 'echo "ERROR: \"$BASH_COMMAND\" failed with exit status $? (line $LINENO)" >&2' ERR
		"$fn"
	) </dev/null 2>&1 | mask_secrets | tee -a "$LOG" |
		{
			dialog --backtitle "$BACKTITLE" --title " $title " --progressbox $((rows - 4)) $((cols - 4)) >/dev/tty 2>&1
			cat >/dev/null
		}
	return "${PIPESTATUS[0]}"
}

log_settings() {
	{
		echo "artix-install.sh $SCRIPT_VERSION - $(date)"
		echo "firmware=$FIRMWARE efi_bits=$EFI_BITS disk=$DISK fs=$FS enc=$ENC bootloader=$BOOTLOADER grub_boot=$GRUB_BOOT secureboot=$SECUREBOOT snapper=$SNAPPER"
		echo "swap=$SWAP swap_size=$SWAP_SIZE kernels=${KERNELS// /,} mirror=$MIRROR aur_helper=$AUR_HELPER aur=$AUR_PKGS"
		echo "hostname=$HOST_NAME keymap=$KEYMAP locale=$LOCALE timezone=$TIMEZONE user=$USER_NAME"
		echo "net=$NET desktop=$DESKTOP dm=$(desktop_dm) dotfiles=$DOTS extras=$EXTRA_PKGS"
		echo "gpu=$GPU (effective: $(gpu_list)) apps=$APPS gaming=$GAMING peripherals=$PERIPH"
		local u
		for u in "${USERS[@]}"; do echo "user=$u sudo=${U_SUDO[$u]}"; done
		echo "bootstrap: progs=$BS_PROGS dotfiles=$BS_DOTFILES branch=$BS_BRANCH shell=$BS_SHELL power=$BS_POWER"
		echo "partitions: ${ALL_PARTS[*]} (esp=$ESP_PART#$ESP_NUM biosboot=$BIOSBOOT_PART#$BIOSBOOT_NUM boot=$BOOT_PART#$BOOT_NUM root=$ROOT_PART#$ROOT_NUM)"
	} | mask_secrets >>"$LOG"
}

install_failed() {
	local title=$1 tailf c
	tailf=$(mktemp)
	tail -n 80 "$LOG" >"$tailf"
	dialog --backtitle "$BACKTITLE" --title " Failed: $title " --exit-label "Continue" \
		--textbox "$tailf" 0 0 >/dev/tty 2>&1 || true
	rm -f "$tailf"
	while true; do
		c=$(ui --title " Installation failed " --cancel-label "Exit" --menu \
			"The installation stopped during:\n  $title\n\nFull log: $LOG" 15 74 3 \
			shell "Open a shell to investigate ('exit' comes back)" \
			menu "Unmount, back to the main menu (settings are kept)" \
			exit "Unmount everything and exit") || c="exit"
		case $c in
			shell)
				clear
				echo "The new system is mounted at $TARGET. Log: $LOG. Type 'exit' when done."
				run_shell bash -i
				;;
			menu)
				cleanup_target
				return 0
				;;
			*)
				cleanup_target
				clear
				echo "Installation failed during: $title"
				echo "See $LOG for details."
				exit 1
				;;
		esac
	done
}

install_done() {
	local c warnings=""
	if [[ -s $WARN_FILE ]]; then
		warnings="\n\n\Z3Warnings:\Zn\n$(sed 's/$/\\n/' "$WARN_FILE" | tr -d '\n')"
	fi
	while true; do
		c=$(ui --title " Installation complete " --cancel-label "Exit" --menu \
			"Artix Linux is installed on $DISK.\nRemove the installation medium before booting the new system.${warnings}" 0 0 4 \
			reboot "Unmount and reboot" \
			poweroff "Unmount and power off" \
			chroot "Open a shell inside the new system" \
			exit "Unmount and return to the live system") || c="exit"
		case $c in
			chroot)
				clear
				echo "You are inside the new system. Type 'exit' to return to the installer."
				run_shell chroot "$TARGET" /usr/bin/env -i HOME=/root TERM="${TERM:-linux}" \
					PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /bin/bash -l
				;;
			reboot) cleanup_target; clear; reboot; exit 0 ;;
			poweroff) cleanup_target; clear; poweroff; exit 0 ;;
			*)
				cleanup_target
				clear
				echo "Done. The installation log was saved to /var/log/artix-install.log on the new system,"
				echo "and these settings as a preset to /root/artix-install.preset (load it with --preset)."
				exit 0
				;;
		esac
	done
}

do_install() {
	local -a titles=() funcs=()
	local i n rc

	titles+=("Preparing the live system") funcs+=(step_prepare_live)
	titles+=("Partitioning $DISK") funcs+=(step_partition)
	if encrypted; then titles+=("Setting up $(enc_desc) encryption") funcs+=(step_encrypt); fi
	titles+=("Creating filesystems") funcs+=(step_filesystems)
	titles+=("Installing the base system") funcs+=(step_bootstrap)
	titles+=("Configuring the system") funcs+=(step_configure)
	titles+=("Installing packages") funcs+=(step_packages)
	if bootstrap_wanted; then titles+=("Bootstrap: programs, dotfiles, shell") funcs+=(step_bootstrap_user); fi
	titles+=("Building the initramfs, installing the boot loader ($BOOTLOADER)$(secureboot_on && echo ', Secure Boot')") funcs+=(step_bootloader)
	titles+=("Finishing$({ snapper_on || zfs_on; } && echo ': snapshots,') boot menu, checks") funcs+=(step_finalize)

	: >"$WARN_FILE"
	log_settings
	INSTALL_STARTED=1
	n=${#funcs[@]}
	for ((i = 0; i < n; i++)); do
		# Do NOT call run_step inside "if"/"||": bash would then silently disable
		# "set -e" inside the step and a failing command would go unnoticed.
		run_step "[$((i + 1))/$n] ${titles[i]}" "${funcs[i]}"
		rc=$?
		if ((rc != 0)); then
			install_failed "${titles[i]}"
			return 1
		fi
	done
	install_done
}

# =============================================================================
#  Presets: every setting except the disk, passwords and users
# =============================================================================
# A preset is a text file:
#     # artix-install preset v1
#     # name: my-desktop
#     FS=btrfs
#     DESKTOP=xfce sway
# It is never run or sourced. Only the keys in PRESET_KEYS are accepted, each
# value must pass preset_check, and anything else rejects the whole file.
# Its ID is <name>@<first 16 hex digits of the SHA-256 of its settings>; loading
# "<file, link or name>@<ID digits>" refuses a preset whose settings differ.
PRESET_KEYS=(INIT FS ENC GRUB_BOOT BOOTLOADER SECUREBOOT SNAPPER SWAP SWAP_SIZE KERNELS MIRROR ARCH_REPOS HOST_NAME KEYMAP
	LOCALE TIMEZONE NET DESKTOP DM DOTS GPU APPS GAMING PERIPH EXTRA_PKGS AUR_HELPER AUR_PKGS
	BS_PROGS BS_DOTFILES BS_BRANCH BS_SHELL BS_POWER)
PRESET_REPO=${ARTIX_INSTALL_PRESETS:-https://raw.githubusercontent.com/aranmi-git/artix-install/main/presets}
PRESET_MAX_BYTES=65536
PRESET_ID=""      # ID of the loaded preset (shown in the main menu)
PRESET_LABEL=""   # its name
PRESET_ERR=""     # why the last load failed
PRESET_SKIPPED="" # keys left out by preset_write
MENU_JUMP=""      # main menu item to highlight next
declare -A PRESET_NEW=() PRESET_OLD=()

one_of() { # one_of <value> <option>...
	local v=$1 o
	shift
	for o in "$@"; do [[ $v == "$o" ]] && return 0; done
	return 1
}

all_of() { # all_of "<words>" <option>... : every word is an option, none twice
	local w seen=" "
	[[ $1 =~ ^[A-Za-z0-9._+\ -]*$ ]] || return 1 # no glob characters before splitting
	for w in $1; do
		one_of "$w" "${@:2}" || return 1
		[[ $seen != *" $w "* ]] || return 1
		seen+="$w "
	done
}

pkg_words_ok() { # package names: each starts with a letter or digit (no options)
	local w
	[[ $1 =~ ^[A-Za-z0-9._+\ -]*$ ]] || return 1
	for w in $1; do [[ $w =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || return 1; done
}

# Is <value> allowed for <key> in a preset?
preset_check() { # preset_check <key> <value>
	local k=$1 v=$2 w seen=" "
	local re_host='[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?'
	local re_path='(/[A-Za-z0-9._~%+=-]*)*'
	case $k in
		FS) one_of "$v" ext4 btrfs zfs ;;
		ENC) one_of "$v" none luks1 luks2 ;;
		GRUB_BOOT) one_of "$v" encrypted separate ;;
		INIT)
			# shellcheck disable=SC2086  # the init names are single words
			one_of "$v" $ALL_INITS
			;;
		BOOTLOADER) one_of "$v" grub limine refind efistub syslinux zfsbootmenu ;;
		SWAP) one_of "$v" none zram file ;;
		SWAP_SIZE) [[ $v =~ ^[1-9][0-9]{0,2}$ ]] && ((v <= 128)) ;;
		SECUREBOOT | SNAPPER) one_of "$v" 0 1 ;;
		KERNELS)
			[[ -n $v ]] || return 1
			# shellcheck disable=SC2086  # the kernel names are single words
			all_of "$v" $ALL_KERNELS
			;;
		MIRROR) one_of "$v" auto rank ;;
		ARCH_REPOS) one_of "$v" 0 1 ;;
		HOST_NAME) [[ $v =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] ;;
		KEYMAP) [[ $v =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$ ]] ;;
		LOCALE) [[ $v =~ ^[A-Za-z_]+\.UTF-8(@[A-Za-z]+)?$ ]] ;;
		TIMEZONE)
			[[ $v == UTC ]] && return 0
			[[ $v =~ ^[A-Z][A-Za-z_]+(/[A-Za-z0-9_+-]+){1,2}$ ]] || return 1
			[[ ! -d /usr/share/zoneinfo || -f /usr/share/zoneinfo/$v ]]
			;;
		NET) one_of "$v" nm connman dhcpcd none ;;
		DESKTOP)
			[[ $v == none ]] && return 0
			[[ -n $v ]] || return 1
			# shellcheck disable=SC2046  # ids are single words
			all_of "$v" $(desktop_table | cut -d'|' -f1)
			;;
		DM) one_of "$v" auto lightdm sddm gdm greetd ly none ;;
		DOTS)
			# shellcheck disable=SC2046
			all_of "$v" $(dots_table | cut -d'|' -f1)
			;;
		GPU)
			one_of "$v" auto none && return 0
			[[ -n $v ]] && all_of "$v" intel amd nouveau nvidia nvidia580 nvidia470 vm
			;;
		APPS)
			all_of "$v" firefox chromium thunderbird vlc mpv libreoffice gimp obs keepassxc \
				telegram-desktop discord flatpak git htop neovim openssh cups
			;;
		GAMING) all_of "$v" multilib steam wine winetricks lutris gamemode ;;
		PERIPH)
			# shellcheck disable=SC2046  # ids are single words
			all_of "$v" $(periph_ids) && ! { has "$v" openlinkhub && has "$v" ckb-next; }
			;;
		EXTRA_PKGS | AUR_PKGS) pkg_words_ok "$v" ;;
		AUR_HELPER) one_of "$v" none yay paru ;;
		BS_POWER) one_of "$v" 0 1 ;;
		BS_PROGS) [[ -z $v || $v =~ ^https://${re_host}${re_path}$ ]] ;;
		BS_DOTFILES)
			[[ -z $v || $v =~ ^https://${re_host}${re_path}$ ||
				$v =~ ^git@[A-Za-z0-9.-]+:[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*$ ]]
			;;
		BS_BRANCH) [[ -z $v || $v =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]{0,99}$ ]] ;;
		BS_SHELL) one_of "$v" bash zsh fish ;;
		*) return 1 ;;
	esac
}

preset_norm() { # one value with runs of blanks collapsed
	local -a w=()
	read -r -a w <<<"$1" || true
	printf '%s' "${w[*]}"
}

# The settings in a fixed order; the ID is computed from exactly this text.
preset_canon() {
	local k
	for k in "${PRESET_KEYS[@]}"; do
		if [[ -n ${PRESET_NEW[$k]+x} ]]; then printf '%s=%s\n' "$k" "${PRESET_NEW[$k]}"; fi
	done
}

preset_hash() { preset_canon | sha256sum | cut -c1-16; }
preset_hash_full() { preset_canon | sha256sum | cut -d' ' -f1; }

valid_preset_name() { [[ $1 =~ ^[a-z0-9][a-z0-9._-]{0,39}$ ]]; }

# Read a preset file into PRESET_NEW. Nothing is applied. 1 + PRESET_ERR on error.
preset_parse() { # preset_parse <file>
	local f=$1 line t k v n=0 bytes
	PRESET_NEW=() PRESET_ERR="" PRESET_LABEL=""
	bytes=$(wc -c <"$f" 2>/dev/null) || bytes=-1
	if ((bytes < 0 || bytes > PRESET_MAX_BYTES)); then
		PRESET_ERR="The file is missing or larger than $((PRESET_MAX_BYTES / 1024)) KiB."
		return 1
	fi
	if LC_ALL=C grep -q $'[\x01-\x08\x0b\x0e-\x1f\x7f]' "$f" || [[ $(tr -d '\000' <"$f" | wc -c) != "$bytes" ]]; then
		PRESET_ERR="The file contains control characters; it is not a preset."
		return 1
	fi
	# A preset never holds secrets. Refuse a file that looks like it does (in a
	# setting or a comment), so a password is not shared by accident.
	t=$(grep -niE '(^|[^a-z])(pass(word|wd|phrase)?|pw|secret|token|api[_-]?key|private[_-]?key|luks[_-]?key)[a-z_]*[[:space:]]*[=:]' "$f" | head -n 1 | cut -d: -f1)
	if [[ -n $t ]]; then
		PRESET_ERR="Line $t looks like a password or other secret. A preset never holds passwords (root, users, encryption) or keys; remove that line."
		return 1
	fi
	while IFS= read -r line || [[ -n $line ]]; do
		n=$((n + 1))
		line=${line%$'\r'}
		if ((n == 1)); then
			if [[ ! $line =~ ^#\ artix-install\ preset\ v1[[:space:]]*$ ]]; then
				PRESET_ERR="The first line must be: # artix-install preset v1"
				return 1
			fi
			continue
		fi
		t=$(trim "$line")
		[[ -z $t ]] && continue
		if [[ $t == \#* ]]; then
			if [[ $t =~ ^#\ *name:\ *([a-z0-9][a-z0-9._-]{0,39})$ ]]; then PRESET_LABEL=${BASH_REMATCH[1]}; fi
			continue
		fi
		if [[ ! $t =~ ^([A-Z_]+)=(.*)$ ]]; then
			PRESET_ERR="Line $n is not KEY=value."
			return 1
		fi
		k=${BASH_REMATCH[1]}
		v=$(preset_norm "${BASH_REMATCH[2]}")
		if ! one_of "$k" "${PRESET_KEYS[@]}"; then
			case $k in
				DISK | ROOT_PASS | LUKS_PASS | USER_NAME | USERS | U_*) PRESET_ERR="Line $n: $k must not be in a preset; the installer always asks for it." ;;
				*) PRESET_ERR="Line $n: unknown setting $k." ;;
			esac
			return 1
		fi
		if [[ -n ${PRESET_NEW[$k]+x} ]]; then
			PRESET_ERR="Line $n: $k is set twice."
			return 1
		fi
		if ! preset_check "$k" "$v"; then
			v=${v//\\/}
			PRESET_ERR="Line $n: invalid value for $k: ${v:0:60}"
			return 1
		fi
		PRESET_NEW[$k]=$v
	done <"$f"
	if ((n == 0)); then
		PRESET_ERR="The file is empty."
		return 1
	fi
	if ((${#PRESET_NEW[@]} == 0)); then
		PRESET_ERR="The file holds no settings."
		return 1
	fi
	return 0
}

# Get a preset to <dest>: a local file, an https:// link, or a name from PRESET_REPO.
preset_fetch() { # preset_fetch <spec> <dest>; sets PRESET_SRC
	local spec=$1 dest=$2 url
	PRESET_SRC=""
	if [[ $spec == https://* ]]; then
		url=$spec
	elif [[ $spec =~ ^[a-z][a-z0-9+.-]*:// ]]; then
		PRESET_ERR="Only https:// links are accepted for presets."
		return 1
	elif [[ -e $spec || $spec == */* ]]; then
		if [[ ! -f $spec || ! -r $spec ]]; then
			PRESET_ERR="File not found: $spec"
			return 1
		fi
		cp -- "$spec" "$dest" || { PRESET_ERR="Cannot read $spec"; return 1; }
		PRESET_SRC=$(readlink -f -- "$spec")
		return 0
	elif valid_preset_name "$spec"; then
		if [[ $PRESET_REPO != https://* ]]; then
			PRESET_ERR="VOID_INSTALL_PRESETS must be an https:// address."
			return 1
		fi
		url="${PRESET_REPO%/}/$spec.preset"
	else
		PRESET_ERR="Not a file, an https:// link or a preset name: $spec"
		return 1
	fi
	if [[ $url =~ ^https://[^/]*@ || $url =~ [[:space:]] ]]; then
		PRESET_ERR="Links with a user name, token or spaces are not accepted."
		return 1
	fi
	PRESET_SRC=$url
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --proto '=https' --proto-redir '=https' --max-time 60 \
			--max-filesize "$PRESET_MAX_BYTES" -o "$dest" -- "$url" >/dev/null 2>&1 ||
			{ PRESET_ERR="Could not download $url"; return 1; }
	else
		PRESET_ERR="curl is not available to download $url"
		return 1
	fi
	return 0
}

preset_backup() {
	local k
	PRESET_OLD=()
	for k in "${PRESET_KEYS[@]}"; do PRESET_OLD[$k]=${!k}; done
}

preset_restore() {
	local k
	for k in "${PRESET_KEYS[@]}"; do printf -v "$k" '%s' "${PRESET_OLD[$k]}"; done
}

# Apply PRESET_NEW; settings it does not name are reset to the defaults.
preset_apply() {
	local k
	INIT=openrc FS=ext4 ENC=luks2 BOOTLOADER=grub GRUB_BOOT=encrypted SECUREBOOT=0 SNAPPER=0 SWAP=zram SWAP_SIZE=4
	KERNELS="linux linux-lts" MIRROR=auto ARCH_REPOS=0 HOST_NAME=artix KEYMAP=us
	LOCALE=en_US.UTF-8 TIMEZONE=UTC NET=nm DESKTOP=none DM=auto DOTS="" GPU=auto APPS=""
	GAMING="" PERIPH="" EXTRA_PKGS="" AUR_HELPER=none AUR_PKGS="" BS_PROGS="" BS_DOTFILES="" BS_BRANCH=""
	BS_SHELL=bash BS_POWER=0
	for k in "${PRESET_KEYS[@]}"; do
		if [[ -n ${PRESET_NEW[$k]+x} ]]; then printf -v "$k" '%s' "${PRESET_NEW[$k]}"; fi
	done
	prune_dots
}

# Problems of the applied preset on this computer (empty: none).
preset_notes() {
	if uefi_only && [[ $FIRMWARE != uefi || $EFI_BITS != 64 ]]; then
		printf '\\Z1%s needs 64-bit UEFI; this computer started with %s. Choose another boot loader.\\Zn\\n' "$(lbl_boot)" "${FIRMWARE^^}"
	fi
	if bios_only && [[ $FIRMWARE != bios ]]; then
		printf '\\Z1%s is for BIOS computers; this one uses UEFI. Choose another boot loader.\\Zn\\n' "$(lbl_boot)"
	fi
	if [[ $FS == zfs && $BOOTLOADER != zfsbootmenu ]] || [[ $FS != zfs && $BOOTLOADER == zfsbootmenu ]]; then
		printf '\\Z1ZFS and ZFSBootMenu go together; this preset has FS=%s with %s.\\Zn\\n' "$FS" "$(lbl_boot)"
	fi
	if [[ -n $PRUNED ]]; then
		printf 'Dotfile presets dropped (their desktop is not in the preset): %s\\n' "$PRUNED"
	fi
}

preset_summary() { # preset_summary <id> <verified: 0/1/2> -> dialog text
	local id=$1 ver=$2 ext=""
	case $ver in
		1) printf 'Preset   \\Zb%s\\Zn  \\Z2(fingerprint verified)\\Zn\\n' "$id" ;;
		*) printf 'Preset   \\Zb%s\\Zn\\n         \\Z3Not verified: load it as %s to check it next time.\\Zn\\n' "$id" "$id" ;;
	esac
	printf 'From     %s\n\n' "$(printf '%s' "$PRESET_SRC" | mask_secrets)"
	printf 'Init     %s%s\n' "$(lbl_init)" "$(arch_repos_on && printf ', with Arch repositories')"
	printf 'Disk     %s, encryption: %s\n' "$FS" "$(enc_desc)"
	printf 'Boot     %s; swap: %s\n' "$(lbl_boot)" "$(lbl_swap)"
	printf 'Kernels  %s\n' "$(lbl_kernels)"
	printf 'Boot+    Secure Boot: %s; snapshots: %s\n' "$(lbl_sb)" "$(lbl_snapper)"
	printf 'Mirrors  %s\n' "$(lbl_mirror)"
	printf 'Host     %s, keymap %s, %s, %s\n' "$HOST_NAME" "$KEYMAP" "$(lbl_locale)" "$TIMEZONE"
	printf 'Network  %s\n' "$(lbl_net)"
	printf 'Desktop  %s; login: %s\n' "$(lbl_desktop)" "$(lbl_dm)"
	printf 'Dotfiles %s\n' "$(lbl_dots)"
	printf 'GPU      %s\n' "$(lbl_gpu)"
	printf 'Apps     %s\n' "$(lbl_list "$APPS")"
	printf 'Gaming   %s\n' "$(lbl_list "$GAMING")"
	printf 'Devices  %s\n' "$(lbl_periph)"
	printf 'Packages %s\n' "${EXTRA_PKGS:-(none)}"
	printf 'AUR      %s\n' "$(lbl_aur)"
	if [[ -n $BS_PROGS ]]; then ext+="  programs list: $BS_PROGS\\n"; fi
	if [[ -n $AUR_PKGS ]]; then ext+="  AUR packages: $AUR_PKGS\\n"; fi
	if has "$PERIPH" openlogi; then ext+="  OpenLogi (Logitech): $(aur_on && echo 'AUR' || echo 'github.com/AprilNEA/OpenLogi, pinned release')\\n"; fi
	if has "$PERIPH" openlinkhub; then ext+="  OpenLinkHub (Corsair): $(aur_on && echo 'AUR' || echo 'github.com/jurkovic-nikola/OpenLinkHub, pinned release')\\n"; fi

	if [[ -n $BS_DOTFILES ]]; then ext+="  dotfiles: $BS_DOTFILES${BS_BRANCH:+ ($BS_BRANCH)}\\n"; fi
	if [[ -n $ext ]]; then
		printf '\n\\Z3\\ZbThis preset installs programs and files from outside the Artix repositories:\\Zn\n%s\\Z3Load it only if you trust these sources.\\Zn\n' "$ext"
	fi
	printf '\nNot in a preset (asked next): disk, root password, users%s.\n' "$(encrypted && printf ', encryption passphrase')"
}

# Fetch, check, show and (if confirmed) apply a preset. 0 = applied.
preset_load() { # preset_load <file | https link | name>[@ID]
	local spec expect="" tmp full id ver=0 notes
	spec=$(trim "$1")
	if [[ $spec =~ ^(.+)@([0-9A-Fa-f]{16,64})$ ]]; then
		spec=${BASH_REMATCH[1]}
		expect=${BASH_REMATCH[2],,}
	fi
	tmp=$(mktemp /tmp/artix-preset.XXXXXX) || return 1
	if ! preset_fetch "$spec" "$tmp" || ! preset_parse "$tmp"; then
		rm -f -- "$tmp"
		msg "This preset was not loaded:\n\n$(printf '%s' "$PRESET_ERR" | mask_secrets)\n\nNo setting was changed." "Preset" 12 74
		return 1
	fi
	rm -f -- "$tmp"
	full=$(preset_hash_full)
	if [[ -n $expect ]]; then
		if [[ ${full:0:${#expect}} != "$expect" ]]; then
			msg "\Z1\ZbThe preset does not match its ID.\Zn\n\nExpected: $expect\nFound:    ${full:0:${#expect}}\n\nIt was changed after the ID was made, or it is a different preset. It was not loaded and no setting was changed." "Preset: wrong fingerprint" 13 74
			return 1
		fi
		ver=1
	fi
	if [[ -z $PRESET_LABEL ]]; then
		PRESET_LABEL=$(basename -- "$spec" .preset)
		valid_preset_name "$PRESET_LABEL" || PRESET_LABEL=preset
	fi
	id="$PRESET_LABEL@${full:0:16}"
	preset_backup
	preset_apply
	notes=$(preset_notes)
	if ! dialog --backtitle "$BACKTITLE" --colors --cr-wrap --no-collapse --title " Load this preset? " --scrollbar \
		--yes-label "Load" --no-label "Cancel" --yesno "$(preset_summary "$id" "$ver")${notes:+\n\n$notes}" 0 0 >/dev/tty 2>&1; then
		preset_restore
		prune_dots
		return 1
	fi
	PRESET_ID=$id
	if arch_repos_on && ! grep -q '^\[extra\]' /etc/pacman.conf 2>/dev/null; then
		arch_repos_setup live >>"$LOG" 2>&1 || warn "Arch's repositories could not be added to the live system yet; the installer tries again when it starts."
		official_refresh
	fi
	printf 'Loaded preset %s from %s (verified: %s)\n' "$id" "$PRESET_SRC" "$ver" | mask_secrets >>"$LOG" 2>/dev/null || true
	if [[ -n $notes && $notes == *Z1* ]]; then MENU_JUMP=Bootloader; else MENU_JUMP=Install; fi
	return 0
}

# Write the current settings as a preset. Values a preset cannot hold
# (a local programs list, a link with credentials) are left out: PRESET_SKIPPED.
preset_write() { # preset_write <file> <name>
	local f=$1 name=$2 k v
	PRESET_NEW=() PRESET_SKIPPED=""
	for k in "${PRESET_KEYS[@]}"; do
		v=$(preset_norm "${!k}")
		if preset_check "$k" "$v"; then PRESET_NEW[$k]=$v; else PRESET_SKIPPED+="${PRESET_SKIPPED:+ }$k"; fi
	done
	(
		umask 022
		{
			echo "# artix-install preset v1"
			echo "# name: $name"
			echo "# id: $name@$(preset_hash)"
			echo "# Made by artix-install.sh $SCRIPT_VERSION on $(date +%F)."
			echo "# Load it with:  bash artix-install.sh --preset <this file, an https link or a name>"
			echo "# Disk, passwords and users are never stored here; the installer asks for them."
			preset_canon
		} >"$f"
	)
}

# Ask for what a preset never contains, then show the main menu.
preset_quick() {
	msg "Preset loaded: \Zb$PRESET_ID\Zn\n\nNow the parts a preset never contains: the disk, the root password, the users$(encrypted && printf ' and the encryption passphrase').\n\nAfterwards the main menu opens with \ZbInstall\Zn selected. Every setting can still be changed there." "Preset" 13 70
	menu_disk || true
	if [[ -z $ROOT_PASS ]]; then menu_rootpass || true; fi
	if ((${#USERS[@]} == 0)); then user_dialog || true; fi
	if encrypted && [[ -z $LUKS_PASS ]]; then ask_luks_pass || true; fi
	return 0
}

lbl_preset() {
	if [[ -n $PRESET_ID ]]; then printf '%s' "$PRESET_ID"; else printf '(none) - load or save all settings'; fi
}

menu_preset() {
	local c v name f def
	c=$(ui --title " Preset " --menu \
		"A preset holds every setting except the disk, the passwords and the users, so the same system can be installed again with a few answers. Its ID ends in a fingerprint of the settings." \
		13 78 3 \
		load "Load a preset: file, https:// link or name" \
		save "Save the current settings as a preset" \
		id "Show the ID of the current settings") || return 1
	case $c in
		load)
			v=$(ui --title " Load a preset " --inputbox \
				"Enter one of:\n  a file:   /mnt/usb/desktop.preset\n  a link:   https://example.org/desktop.preset\n  a name:   xfce-desktop  (from the presets folder of the repository)\n\nAdd @ and the ID's digits to verify it:  xfce-desktop@1a2b3c4d5e6f7a8b" \
				15 78) || return 1
			[[ -n $(trim "$v") ]] || return 1
			preset_load "$v" || return 1
			preset_quick
			;;
		save)
			def=${PRESET_LABEL:-$(printf '%s' "${HOST_NAME,,}" | tr -c 'a-z0-9._-' '-')}
			valid_preset_name "$def" || def=my-preset
			name=$(ui --title " Save a preset " --inputbox "Name (lowercase letters, digits, '.', '_', '-'):" 9 64 "$def") || return 1
			if ! valid_preset_name "$name"; then
				msg "Use 1-40 lowercase letters, digits, '.', '_' or '-', starting with a letter or digit." "Preset"
				return 1
			fi
			f=$(ui --title " Save a preset " --inputbox "Save to (a USB stick keeps it; /root is lost when the live system shuts down):" 9 78 "/root/$name.preset") || return 1
			f=$(trim "$f")
			if [[ -z $f || -d $f ]]; then msg "Enter a file name, not a folder." "Preset"; return 1; fi
			if [[ -e $f ]] && ! yesno "$f exists.\n\nReplace it?" "Preset" 1; then return 1; fi
			if ! preset_write "$f" "$name" 2>/dev/null; then
				msg "Cannot write $f" "Preset"
				return 1
			fi
			PRESET_LABEL=$name PRESET_ID="$name@$(preset_hash)"
			msg "Saved: $f\n\nID: \Zb$PRESET_ID\Zn\n\nInstall the same system elsewhere with:\n  bash artix-install.sh --preset $f@${PRESET_ID#*@}\n\nOr add the file to the presets/ folder of the repository as $name.preset and use:\n  bash artix-install.sh --preset $PRESET_ID${PRESET_SKIPPED:+\n\n\Z3Left out (a preset cannot hold them): $PRESET_SKIPPED\Zn}" "Preset saved" 19 78
			;;
		id)
			preset_write /dev/null "${PRESET_LABEL:-preset}"
			msg "ID of the current settings:\n\n  \Zb${PRESET_LABEL:-preset}@$(preset_hash)\Zn\n\nIt changes whenever a setting changes. The disk, passwords and users are not part of it.${PRESET_SKIPPED:+\n\n\Z3Not part of a preset: $PRESET_SKIPPED\Zn}" "Preset ID" 13 74
			;;
	esac
	return 0
}

# =============================================================================
#  Main menu
# =============================================================================
MENU_ORDER=(Preset Disk Init Filesystem Encryption Bootloader Secure-Boot Snapshots Swap Kernel Mirrors Arch-repos Hostname
	Keyboard Locale Timezone Root-password Users Network Desktop Login Dotfiles GPU Apps Gaming Peripherals Packages AUR Bootstrap Install)

next_item() {
	local i
	for i in "${!MENU_ORDER[@]}"; do
		if [[ ${MENU_ORDER[i]} == "$1" ]]; then
			echo "${MENU_ORDER[i + 1]:-Install}"
			return 0
		fi
	done
	echo Install
}

main_menu() {
	local choice next=${1:-Disk} fw ok
	fw=${FIRMWARE^^}
	[[ $FIRMWARE == uefi ]] && fw+=" ${EFI_BITS}-bit"
	while true; do
		choice=$(ui --title " Artix Linux installation " --default-item "$next" --cancel-label "Exit" \
			--menu "Set the options, then choose \ZbInstall\Zn. Firmware: \Zb$fw\Zn" 0 0 0 \
			Preset "$(lbl_preset)" \
			Disk "$(lbl_disk)" \
			Init "$(lbl_init)" \
			Filesystem "$FS" \
			Encryption "$(lbl_enc)" \
			Bootloader "$(lbl_boot)" \
			Secure-Boot "$(lbl_sb)" \
			Snapshots "$(lbl_snapper)" \
			Swap "$(lbl_swap)" \
			Kernel "$(lbl_kernels)" \
			Mirrors "$(lbl_mirror)" \
			Arch-repos "$(lbl_arch_repos)" \
			Hostname "$HOST_NAME" \
			Keyboard "$KEYMAP" \
			Locale "$(lbl_locale)" \
			Timezone "$TIMEZONE" \
			Root-password "$(lbl_set "$ROOT_PASS")" \
			Users "$(lbl_user)" \
			Network "$(lbl_net)" \
			Desktop "$(lbl_desktop)" \
			Login "$(lbl_dm)" \
			Dotfiles "$(lbl_dots)" \
			GPU "$(lbl_gpu)" \
			Apps "$(lbl_list "$APPS")" \
			Gaming "$(lbl_list "$GAMING")" \
			Peripherals "$(lbl_periph)" \
			Packages "${EXTRA_PKGS:-(none)}" \
			AUR "$(lbl_aur)" \
			Bootstrap "$(lbl_bootstrap)" \
			Install "\Zb>>> Start the installation\Zn")
		ok=$?
		if ((ok != 0)); then
			if yesno "Exit the installer? Nothing has been written to disk." "Exit" 1; then
				clear
				exit 0
			fi
			continue
		fi
		ok=0
		case $choice in
			Preset) menu_preset || ok=1 ;;
			Disk) menu_disk || ok=1 ;;
			Init) menu_init || ok=1 ;;
			Filesystem) menu_fs || ok=1 ;;
			Encryption) menu_enc || ok=1 ;;
			Bootloader) menu_bootloader || ok=1 ;;
			Secure-Boot) menu_secureboot || ok=1 ;;
			Snapshots) menu_snapper || ok=1 ;;
			Swap) menu_swap || ok=1 ;;
			Kernel) menu_kernel || ok=1 ;;
			Mirrors) menu_mirror || ok=1 ;;
			Arch-repos) menu_arch_repos || ok=1 ;;
			Hostname) menu_hostname || ok=1 ;;
			Keyboard) menu_keymap || ok=1 ;;
			Locale) menu_locale || ok=1 ;;
			Timezone) menu_timezone || ok=1 ;;
			Root-password) menu_rootpass || ok=1 ;;
			Users) menu_user || ok=1 ;;
			Network) menu_network || ok=1 ;;
			Desktop) menu_desktop || ok=1 ;;
			Login) menu_dm || ok=1 ;;
			Dotfiles) menu_dotfiles || ok=1 ;;
			GPU) menu_gpu || ok=1 ;;
			Apps) menu_apps || ok=1 ;;
			Gaming) menu_gaming || ok=1 ;;
			Peripherals) menu_periph || ok=1 ;;
			Packages) menu_extras || ok=1 ;;
			AUR) menu_aur || ok=1 ;;
			Bootstrap) menu_bootstrap || ok=1 ;;
			Install)
				if validate && confirm_install; then
					do_install
				fi
				ok=1
				;;
		esac
		if ((ok == 0)); then next=$(next_item "$choice"); else next=$choice; fi
		if [[ -n $MENU_JUMP ]]; then
			next=$MENU_JUMP
			MENU_JUMP=""
		fi
	done
}

usage() {
	cat <<EOF
artix-install.sh $SCRIPT_VERSION - menu-driven Artix Linux installer

Run as root from the official Artix Linux ISO (x86_64) with internet access:
    bash artix-install.sh

Install from a preset (asks only for the disk, passwords and users):
    bash artix-install.sh --preset kde-openrc
    bash artix-install.sh --preset /mnt/usb/my.preset@1a2b3c4d5e6f7a8b

LARBS-style post-install on an ALREADY INSTALLED Artix system (no disk changes):
    bash artix-install.sh --bootstrap

Options:
    -p, --preset P   load a preset: a file, an https:// link, or a name from
                     $PRESET_REPO
                     Add @ID (16+ hex digits) to refuse a changed preset.
    -b, --bootstrap  only create/update a user and run the bootstrap
    -h, --help       show this help
    -V, --version    show the version
EOF
}

# ---- --bootstrap: LARBS-like flow on a running system --------------------------------
bootstrap_main() {
	local u n p lvl c rc
	[[ $EUID -eq 0 ]] || die "Run this as root."
	command -v pacman >/dev/null 2>&1 || die "This mode needs Artix Linux (pacman not found)."
	[[ -t 0 && -t 1 ]] || die "Run this from an interactive terminal."
	if [[ -d /run/artix || -d /run/archiso ]]; then
		die "This looks like the live ISO. --bootstrap is for an installed system; run the installer without options instead."
	fi
	: >"$LOG" || die "Cannot write $LOG"
	: >"$WARN_FILE"
	STANDALONE=1
	TARGET=/
	BACKTITLE="Artix Linux bootstrap ${SCRIPT_VERSION}"
	ensure_dialog
	ensure_network
	# An AUR helper the user already has is used for A entries.
	if command -v paru >/dev/null 2>&1; then AUR_HELPER=paru; elif command -v yay >/dev/null 2>&1; then AUR_HELPER=yay; fi

	msg "Welcome!\n\nThis sets up a user and installs your programs list and dotfiles, LARBS-style, on this Artix system. The disk is not changed.\n\nLog: $LOG" "Welcome" 14 70
	while true; do
		u=$(ui --title " User " --inputbox "Login name of the user to create or update:" 9 64 "${USERS[0]:-}") || { clear; exit 0; }
		valid_login "$u" 1 && break
	done
	if id "$u" >/dev/null 2>&1; then
		yesno "The user '$u' already exists. Its files stay; its password will be changed, it is added to the groups below, and the dotfiles may overwrite files in its home.\n\nContinue?" "Existing user" 1 || { clear; exit 0; }
	fi
	n=$(ui --title " User $u " --inputbox "Full name (optional):" 9 64) || { clear; exit 0; }
	[[ $n != *:* ]] || die "The full name must not contain ':'."
	p=$(ask_password "Password for $u" "the password for $u") || { clear; exit 0; }
	U_SUDO[$u]=sudo
	lvl=$(menu_sudo_level "$u") || { clear; exit 0; }
	USERS=("$u")
	U_FULL[$u]=$n U_PASS[$u]=$p U_SUDO[$u]=$lvl
	sync_primary
	menu_bootstrap

	c="User:       $u ($(sudo_word "$u"))\nPrograms:   ${BS_PROGS:-(none)}\nPresets:    ${DOTS:-(none)}\nDotfiles:   ${BS_DOTFILES:-(none)}${BS_BRANCH:+ ($BS_BRANCH)}\nShell:      $BS_SHELL\nPower cmds: $([[ $BS_POWER == 1 ]] && echo 'without password' || echo 'normal')"
	yesno "$c\n\nStart?" "Let's go" 0 15 70 || { clear; exit 0; }

	run_step "[1/2] Setting up user $u" setup_users
	rc=$?
	if ((rc == 0)); then
		run_step "[2/2] Bootstrap: programs, dotfiles, shell" step_bootstrap_user
		rc=$?
	fi
	if ((rc != 0)); then
		dialog --backtitle "$BACKTITLE" --title " Failed " --textbox "$LOG" 0 0 >/dev/tty 2>&1 || true
		clear
		echo "The bootstrap stopped with an error. See $LOG"
		exit 1
	fi
	c="All done. Log out and log in as $u."
	if [[ -s $WARN_FILE ]]; then c+="\n\n\Z3Warnings:\Zn\n$(sed 's/$/\\n/' "$WARN_FILE" | tr -d '\n')"; fi
	msg "$c" "All done!" 18 74
	clear
	exit 0
}

main() {
	local preset="" start=Disk
	case ${1:-} in
		-h | --help) usage; exit 0 ;;
		-V | --version) echo "$SCRIPT_VERSION"; exit 0 ;;
		-b | --bootstrap) bootstrap_main ;;
		-p | --preset)
			[[ -n ${2:-} && $# -eq 2 ]] || { usage >&2; exit 2; }
			preset=$2
			;;
		--preset=?*)
			[[ $# -eq 1 ]] || { usage >&2; exit 2; }
			preset=${1#--preset=}
			;;
		"") ;;
		*) usage >&2; exit 2 ;;
	esac
	preflight
	trap '[[ $INSTALL_STARTED == 1 ]] && cleanup_target' EXIT
	trap 'exit 130' INT TERM
	ensure_network_text
	ensure_keyring
	ensure_dialog
	enable_multilib /etc/pacman.conf
	ensure_network
	official_refresh
	msg "This installer puts Artix Linux on a whole disk.\n\n  * OpenRC, runit, s6 or dinit\n  * UEFI or BIOS, GPT partitioning\n  * ext4, btrfs (snapper) or ZFS (ZFSBootMenu)\n  * no encryption, LUKS1 or LUKS2; Secure Boot (sbctl)\n  * GRUB, Limine, rEFInd, EFISTUB or SYSLINUX\n  * linux, linux-lts, linux-zen, linux-hardened\n  * desktops and window managers (pick several,\n    Hyprland too) with dotfile presets\n  * GPU drivers, apps, gaming, peripherals, AUR (yay/paru)\n  * several users with sudo levels, LARBS-style bootstrap\n\nNothing is written until you confirm the summary and type the disk name.\nLog file: $LOG" \
		"Welcome" 21 74
	if [[ -n $preset ]] && preset_load "$preset"; then
		preset_quick
		start=$MENU_JUMP
		MENU_JUMP=""
	fi
	main_menu "$start"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
fi
