# Installing from scratch

This is the walkthrough used for the original September 2026 install,
kept as the reinstall guide. The decisions it used to list are made and
baked into the config: AMD Ryzen AI 300 mainboard, LUKS on both root and
swap, 64 GB swap (= RAM) for hibernation, no VirtualBox.

1. Download the minimal or graphical NixOS ISO matching the release in
   `flake.nix` from <https://nixos.org/download> and write it to a USB
   stick.
1. Boot it. If you use the graphical ISO, skip the Calamares installer
   entirely and open a terminal; the steps below replace it. The console
   is QWERTY until `loadkeys dvorak`.
1. Partition the NVMe: a 1 GB EFI partition, a 64 GB swap partition, and
   the rest for the encrypted root. Check the device name with `lsblk`
   first; it is `nvme0n1` on most Frameworks.

   ```bash
   sudo -i
   loadkeys dvorak
   parted /dev/nvme0n1 -- mklabel gpt
   parted /dev/nvme0n1 -- mkpart ESP fat32 1MiB 1GiB
   parted /dev/nvme0n1 -- set 1 esp on
   parted /dev/nvme0n1 -- mkpart swap 1GiB 65GiB
   parted /dev/nvme0n1 -- mkpart root 65GiB 100%
   ```

   Then encrypt, format, and create the btrfs subvolumes that
   `hardware-configuration.nix` expects:

   ```bash
   cryptsetup luksFormat /dev/nvme0n1p2      # swap
   cryptsetup luksFormat /dev/nvme0n1p3      # root (use the SAME passphrase)
   cryptsetup open /dev/nvme0n1p2 cryptswap
   cryptsetup open /dev/nvme0n1p3 cryptroot
   mkfs.btrfs -L nixos /dev/mapper/cryptroot
   mount /dev/mapper/cryptroot /mnt
   btrfs subvolume create /mnt/@
   btrfs subvolume create /mnt/@home
   btrfs subvolume create /mnt/@nix
   umount /mnt
   O=compress=zstd:1,noatime,ssd,discard=async,space_cache=v2
   mount -o subvol=@,$O /dev/mapper/cryptroot /mnt
   mkdir -p /mnt/{home,nix,boot}
   mount -o subvol=@home,$O /dev/mapper/cryptroot /mnt/home
   mount -o subvol=@nix,$O /dev/mapper/cryptroot /mnt/nix
   mkfs.fat -F32 /dev/nvme0n1p1 && mount /dev/nvme0n1p1 /mnt/boot
   mkswap /dev/mapper/cryptswap && swapon /dev/mapper/cryptswap
   ```

1. Generate the real hardware file and bring this repo in:

   ```bash
   nixos-generate-config --root /mnt
   nix-shell -p git   # git is not on the ISO by default
   git clone https://github.com/xentac/nixos-config /mnt/etc/nixos-config
   cp /mnt/etc/nixos/hardware-configuration.nix \
      /mnt/etc/nixos-config/hosts/donatello/hardware-configuration.nix
   ```

   Re-add the `options = [ "subvol=..." "compress=zstd:1" ... ]` lines to the
   generated file; the generator drops mount options. It will name the LUKS
   devices by the mapper names you used (`cryptroot`, `cryptswap`) and put
   the real UUIDs in. Then `git add` it.
1. Install and reboot:

   ```bash
   cd /mnt/etc/nixos-config
   nixos-install --flake .#donatello
   ```

   It asks for the root password. GDM refuses root logins, so on first
   boot switch to a TTY (Ctrl-Alt-F2), log in as root, and run
   `passwd xentac`. Then log in as yourself at GDM.

1. First boot checklist:

   ```bash
   sudo mv /etc/nixos-config ~/coding/nixos-config   # or clone fresh
   sudo tailscale up
   chezmoi init --apply xentac                        # dotfiles
   fprintd-enroll                                     # fingerprint
   fwupdmgr refresh && fwupdmgr update                # Framework firmware
   flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
   rustup default stable
   sudo btrfs subvolume create /.snapshots            # btrbk target
   ```

   Then re-enroll the TPM for passphrase-free LUKS unlock (see the
   comment in `hosts/donatello/default.nix`):

   ```bash
   sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-uuid/<uuid>
   ```
