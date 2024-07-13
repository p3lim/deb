# Debian bootstrap

This is a script to bootstrap Debian 12/bookworm using debootstrap.

Features:

- btrfs with subvolumes suitable for snapshots
- systemd-boot instead of GRUB
- xanmod kernel
- minified/debloated Gnome

It doesn't cover everything, especially firmware, but it works on my machines.  
It also takes a long time to run compared to the official ISO, but that's fine by me.

## Usage

The script must be run on a Live ISO variant of Debian, and parts of the script is depending on a specific one; [Grml](https://grml.org/). Download the latest Grml64 full ISO from their site, boot it, then download and run the setup script:

```bash
wget -qO- https://github.com/p3lim/deb/raw/master/setup.sh | bash
# shorthand variant, it's just a redirect:
wget -qO- p3l.im/deb | bash
```
