#!/bin/bash

set -e
set -o pipefail

prompt(){
  echo -e -n "\033[0;33m$1\033[0m " >&2
  read -r out < /dev/tty # so piping works
  echo "$out"
}

log(){
  echo -e "\033[0;34m$1\033[0m"
}

err(){
  echo -e "\033[0;31m$1\033[0m"
}

log "This script will prompt for a few things then it's fully unattended\n"

_hostname=$(prompt 'Hostname:')

#just use dpkg-reconfigure for timezone and locale, it's a pain to prompt
echo > /etc/locale.gen # reset first
dpkg-reconfigure locales
dpkg-reconfigure tzdata

_user=$(prompt 'Username:')
_pass=$(prompt 'Password:')

log 'Install disk selection'
echo
lsblk -d -I 8,259 -o name,size,model
echo
while true; do
  _disk=$(prompt 'Install disk path:')

  if lsblk -nd -I 8,259 -o name | grep -q "^$_disk$"; then
    break
  else
    err 'Invalid selection, try again'
  fi
done
_disk="/dev/$_disk"

while true; do
  _codename=$(prompt 'Debian version:')

  case "$_codename" in
    stable|bookworm|sid|unstable)
      break
      ;;
    *)
      err 'Invalid version, must be one of: stable,bookworm,unstable,sid'
      ;;
  esac
done

case "$_codename" in
  stable|bookworm)
    _codename_stable=true
esac

log 'Unattended installation start, grab a drink while you wait'
sleep 5

# TODO: revise this setup
_vols=() # "<name> <path>"
_vols+=('home /home')
_vols+=('tmp /tmp')
_vols+=('var /var')
_vols+=('log /var/log')

# btrfs mount options
_opts='rw,noatime,space_cache=v2,compress=zstd,ssd,discard=async'

# base packages (excluding debootstrap) for a working gnome setup
_pkgs=(
  # base tools
  apparmor
  bolt
  bluetooth
  command-not-found
  curl
  gdb-minimal
  gpg
  moreutils
  pciutils
  sudo
  systemd-timesyncd
  systemd-resolved # works well with networkmanager
  usbutils
  wget
  zstd # required for compression, e.g. for initramfs

  # file system tools
  btrfs-progs
  dosfstools
  ntfs-3g
  usb-modeswitch

  # efi
  dracut
  efibootmgr
  systemd-boot

  # video drivers
  mesa-vulkan-drivers
  va-driver-all
  vdpau-driver-all

  # wifi drivers
  firmware-linux
  firmware-iwlwifi # intel
  firmware-realtek

  # desktop
  desktop-base
  file-roller # archive app
  fwupd
  gnome-clocks
  gnome-color-manager
  gnome-core
  gnome-shell-extension-appindicator
  gnome-shell-extension-manager
  gnome-software-plugin-flatpak
  gnome-tweaks
  gstreamer1.0-libav # codecs
  gstreamer1.0-plugins-ugly # codecs
  libgdk-pixbuf2.0-bin # thumbnails in nautilus
  libproxy1-plugin-networkmanager
  network-manager-gnome
  wireless-regdb
  wpasupplicant
  xdg-user-dirs-gtk
)

# cpu-specific packages
if grep 'vendor_id' /proc/cpuinfo | grep -q 'AMD'; then
  _pkgs+=('amd64-microcode')
fi
if grep 'vendor_id' /proc/cpuinfo | grep -q 'Intel'; then
  _pkgs+=('intel-microcode')
fi

log 'Partitioning install disk'
parted -a optimal -s "$_disk" mklabel gpt
parted -a optimal -s "$_disk" mkpart "" vfat 0% 1G
parted -a optimal -s "$_disk" mkpart "" btrfs 1G 100%
parted -a optimal -s "$_disk" set 1 esp on

log 'Formatting partitions'
mkfs.vfat -F 32 "${_disk}1"
mkfs.btrfs -f "${_disk}2"

log 'Mounting btrfs partition'
mount "${_disk}2" /mnt

log 'Creating btrfs subvolumes'
(
  cd /mnt
  btrfs subvolume create @

  for i in "${!_vols[@]}"; do
    while read -r name path; do
      btrfs subvolume create "@${name}"
    done <<< "${_vols[$i]}"
  done

  btrfs subvolume set-default @
)

log 'Dismounting btrfs partition'
umount /mnt

log 'Mounting btrfs subvolumes'
mount -o "$_opts,subvol=@" "${_disk}2" /mnt

for i in "${!_vols[@]}"; do
  while read -r name path; do
    mkdir -p "/mnt${path}"
    mount -o "$_opts,subvol=@${name}" "${_disk}2" "/mnt${path}"
  done <<< "${_vols[$i]}"
done

log "Bootstrapping $_codename"
debootstrap --include=dbus,locales,tzdata "$_codename" /mnt 'http://deb.debian.org/debian'

log 'Mounting EFI partition'
mkdir -p /mnt/boot/efi
mount "${_disk}1" /mnt/boot/efi

log 'Generating fstab'
_btrfs_uuid="$(blkid -s UUID -o value "${_disk}2")"
echo "UUID=$_btrfs_uuid / btrfs $_opts,subvol=@ 0 0" > /mnt/etc/fstab
echo "UUID=$(blkid -s UUID -o value "${_disk}1") /boot/efi vfat umask=0077 0 1" >> /mnt/etc/fstab

for i in "${!_vols[@]}"; do
  while read -r name path; do
    echo "UUID=$_btrfs_uuid $path btrfs $_opts,subvol=@${name} 0 0" >> /mnt/etc/fstab
  done <<< "${_vols[$i]}"
done

log 'Setting cmdline so UEFI finds the disk'
echo "root=UUID=$_btrfs_uuid" > /mnt/etc/kernel/cmdline

log 'Setting system parameters'
cat /etc/timezone > /mnt/etc/timezone
cat > /mnt/etc/locale.gen << EOF
$(grep -v '^# ' /etc/locale.gen)
EOF

# ref section D.3.4.4: https://www.debian.org/releases/stable/amd64/apds03.en.html
echo "$_hostname" > /mnt/etc/hostname
cat > /mnt/etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 $_hostname

# The following lines are desirable for IPv6 capable hosts
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
EOF

log 'Updating timezone and locale'
grml-chroot /mnt /bin/bash << EOT
dpkg-reconfigure -f noninteractive tzdata
dpkg-reconfigure -f noninteractive locales
update-locale
EOT

log 'Enable additional repo suites and components'
echo > /mnt/etc/apt/sources.list

if $_codename_stable; then
  cat > /mnt/etc/apt/sources.list.d/debian.sources << EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: $_codename ${_codename}-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian-security
Suites: ${_codename}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
else
  cat > /mnt/etc/apt/sources.list.d/debian.sources << EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: $_codename
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
fi

log 'Adding xanmod repo and key'
wget -qO- https://dl.xanmod.org/archive.key | gpg --dearmor -vo /mnt/etc/apt/keyrings/xanmod.gpg
cat > /mnt/etc/apt/sources.list.d/xanmod.sources << EOF
Types: deb
URIs: http://deb.xanmod.org
Suites: releases
Components: main
Signed-By: /etc/apt/keyrings/xanmod.gpg
EOF

log 'Detecting xanmod kernel package version'
wget -qO /tmp/check https://dl.xanmod.org/check_x86-64_psabi.sh
_xancheck="$(awk -f /tmp/check || true)"
if [ -z "$_xancheck" ]; then
  err 'Unsupported CPU'
  exit 1
fi
_pkgs+=("${_xancheck//CPU supports x86-64-/linux-xanmod-x64}")

log 'Installing packages'
grml-chroot /mnt /bin/bash << EOT
apt update
apt install -y --no-install-recommends --no-install-suggests ${_pkgs[@]}
EOT

log 'Creating user and disabling root'
grml-chroot /mnt /bin/bash << EOT
useradd -mG sudo -s /bin/bash $_user
echo -e "$_pass\n$_pass" | passwd "$_user"
passwd -d root
passwd -l root
EOT

log 'Enabling flatpak repo (flathub)'
wget -qO /mnt/tmp/flathub.flatpakrepo https://flathub.org/repo/flathub.flatpakrepo
grml-chroot /mnt /bin/bash << EOT
flatpak remote-add flathub /tmp/flathub.flatpakrepo
EOT
rm /mnt/tmp/flathub.flatpakrepo

log 'Reconfigure kernel package'
# TODO: there's some weirdness if this is not a separate step, need to do more tests later
#       maybe try out bootctl update
grml-chroot /mnt /bin/bash << EOT
dpkg-reconfigure -f noninteractive \$(apt list -i | awk -F'/' '/^linux-image/{print \$1}')
EOT

log 'Unmounting'
sync
umount /mnt/boot/efi
umount -A /mnt

log 'Done!'

_reboot="$(prompt 'Reboot now? (Y/n)')"
case $_reboot in
  [nN]) exit 0 ;;
  *) ;;
esac

log 'Rebooting...'
reboot
