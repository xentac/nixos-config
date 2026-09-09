# NixOS configuration for the Framework Laptop 13 Pro

This repo is the complete, declarative description of the new laptop:
bootloader, kernel, desktop, services, users, and every installed package.
Rebuilding from it produces the same system every time. It was drafted from
a survey of the Ubuntu 26.04 / sway install on the ThinkPad ("baxter") so
the new machine starts out feeling like the old one.

Dotfiles are **not** in here. They stay in chezmoi
(<https://github.com/xentac/dotfiles>) and get applied the normal way after
first boot. See [Dotfiles and chezmoi](#dotfiles-and-chezmoi) for the few
lines in that repo that need NixOS-specific tweaks.

## Layout

```text
flake.nix                       entry point: inputs (nixpkgs, nixos-hardware) + the one system
flake.lock                      exact commits of every input; commit it
hosts/framework/
  default.nix                   this machine: hardware variant, hostname, kernel, stateVersion
  hardware-configuration.nix    STUB — replace with nixos-generate-config output
modules/nixos/
  default.nix                   imports every module below
  nix-settings.nix              flakes on, GC, allowUnfree
  boot.nix                      systemd-boot, initrd, plymouth
  locale-keyboard.nix           timezone, locale, Dvorak in console + GDM
  networking.nix                NetworkManager, tailscale, ssh, mosh, avahi, samba client
  desktop.nix                   sway + GDM + portals + keyring + thunar
  audio.nix                     pipewire
  hardware-extras.nix           bluetooth, printing, fwupd, fprintd, yubikey, power
  virtualisation.nix            docker, podman, libvirt/virt-manager
  development.nix               toolchains, LSPs, nix-ld, direnv
  fonts.nix
  users.nix                     the xentac account and its groups
  apps.nix                      GUI applications, syncthing, flatpak
  gaming.nix                    steam
  backups.nix                   btrbk snapshots, restic skeleton
justfile                        `just switch`, `just update`, `just gc`, ...
```

## Nix in ten minutes

You don't need to learn the Nix language to use this repo. You need five
ideas.

### 1. Everything lives in the store

Every package is built into an immutable directory under `/nix/store/`,
named by a hash of all its inputs, for example
`/nix/store/abc123...-firefox-155.0`. Two versions of the same program can
coexist because they have different hashes. There is no `/usr/bin` full of
mutable files; `/run/current-system/sw/bin` is a tree of symlinks into the
store that gets swapped atomically when you rebuild.

Consequence: prebuilt binaries from the internet often fail with
`No such file or directory` because they look for `/lib64/ld-linux...`.
The `programs.nix-ld` setting in `development.nix` papers over that for most
of them. Prefer the nixpkgs version of a tool when one exists.

### 2. The system is a function of this repo

`nixos-rebuild switch --flake .#framework` evaluates `flake.nix`, which
builds one big attribute set describing the whole OS, then builds it, then
activates it. Nothing you do with `apt`-style imperative commands exists;
you edit a file and rebuild. Want a package? Add it to a list in a module
and run `just switch`.

### 3. Generations and rollback

Each rebuild creates a new *generation* and adds it to the systemd-boot
menu. If a rebuild breaks something, reboot and pick the previous entry, or
run `sudo nixos-rebuild switch --rollback`. Old generations keep their
store paths on disk until `nix-collect-garbage` deletes them.
`nix-settings.nix` does that weekly for anything older than 30 days.

### 4. Modules and options

Every `.nix` file under `modules/` is a *module*: a function that returns
settings like `services.tailscale.enable = true`. NixOS merges all modules
together. Lists (like `environment.systemPackages`) are concatenated, so it
is fine for several files to add packages. Booleans and strings must agree
or you get a conflict error; `lib.mkDefault` marks a value as overridable,
`lib.mkForce` wins over everything. `nixos-hardware` is just more modules
written by other people.

Every option is documented with its type and default at
<https://search.nixos.org/options>. Packages are at
<https://search.nixos.org/packages>. Both are searchable and are the first
place to look for anything.

### 5. Flakes and the lock file

`flake.nix` declares *inputs* (nixpkgs on the `nixos-26.05` branch,
nixos-hardware). `flake.lock` records the exact git commit of each. Your
system will not change under you until you run `nix flake update`, which
moves the pins forward. Commit both files. **Flakes only see files that
git knows about**: after creating a new `.nix` file, `git add` it or the
build will say the file does not exist.

`system.stateVersion` in `hosts/framework/default.nix` is not "which
version you run". It tells stateful services which on-disk format they
were created with. Set it once at install and never bump it.

## How the pieces connect

```text
nixos-rebuild switch --flake .#framework
  └─ flake.nix: nixosConfigurations.framework
       └─ hosts/framework/default.nix
            ├─ inputs.nixos-hardware.nixosModules.framework-intel-core-ultra-series3
            ├─ hosts/framework/hardware-configuration.nix   (disks, kernel modules)
            └─ modules/nixos/default.nix
                 ├─ nix-settings.nix   boot.nix   locale-keyboard.nix
                 ├─ networking.nix     desktop.nix   audio.nix
                 ├─ hardware-extras.nix   virtualisation.nix   development.nix
                 └─ fonts.nix   users.nix   apps.nix   gaming.nix   backups.nix
```

`specialArgs = { inherit inputs; }` in `flake.nix` is what lets
`hosts/framework/default.nix` refer to `inputs.nixos-hardware`. Every module
receives `pkgs` (the package set) and `lib` (helper functions) as arguments
automatically.

## Decisions to make before installing

1. **Mainboard variant.** The 13 Pro ships as Intel Core Ultra Series 3
   or AMD Ryzen AI 300. `hosts/framework/default.nix` defaults to Intel.
   Change the single import line for AMD, and swap `kvm-intel` for
   `kvm-amd` plus the microcode line in `hardware-configuration.nix`.
1. **Encryption and swap are one decision.** The Ubuntu install is
   unencrypted btrfs. The stub `hardware-configuration.nix` assumes LUKS on
   both root and swap; encrypting root but not swap is pointless because
   hibernation writes all of RAM to swap. Delete both `boot.initrd.luks`
   blocks if you decide against encryption. With 64 GB RAM, make swap
   64 GB if you want hibernation, 8 GB if you don't.
1. **VirtualBox.** Recommended: drop it and run the `win10` VM under
   libvirt (copy the qcow2 and XML). It is left commented out.

## Install walkthrough

1. Download the minimal or graphical NixOS 26.05 ISO from
   <https://nixos.org/download> and write it to a USB stick.
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
      /mnt/etc/nixos-config/hosts/framework/hardware-configuration.nix
   ```

   Re-add the `options = [ "subvol=..." "compress=zstd:1" ... ]` lines to the
   generated file; the generator drops mount options. It will name the LUKS
   devices by the mapper names you used (`cryptroot`, `cryptswap`) and put
   the real UUIDs in. Then `git add` it.
1. Install and reboot:

   ```bash
   cd /mnt/etc/nixos-config
   nixos-install --flake .#framework
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

## Daily use

| Task | Command |
| --- | --- |
| Apply a change | `just switch` (or `sudo nixos-rebuild switch --flake .#framework`) |
| Check for errors without activating | `just check` |
| Try a change until next reboot | `just test` |
| Undo the last switch | `sudo nixos-rebuild switch --rollback` |
| Update all packages | `just update && just switch` |
| Free disk space | `just gc` |
| Run a program once without installing | `nix run nixpkgs#cowsay` |
| Shell with extra tools | `nix shell nixpkgs#hugo nixpkgs#go` |
| Search packages | `nix search nixpkgs foo` or <https://search.nixos.org> |
| Why is X installed? | `nix-tree /run/current-system` |

Editing workflow: change a file, `git add` it if new, `just switch`. A
typo produces an evaluation error before anything touches the system;
read the last few lines, they name the file and option.

### Per-project tools instead of global installs

`pip install --user`, `npm -g`, and `cargo install` still work (into
`~/.local`), but the idiomatic way is a dev shell per project. With
`direnv` enabled in `development.nix`, add a `flake.nix` with a
`devShells.default` to a project and `echo "use flake" > .envrc`; entering
the directory loads exactly that project's compilers and tools.

### One-off packages

Add a package to `environment.systemPackages` (everyone) or
`users.users.xentac.packages` (just you) and rebuild. Both lists are in
`modules/nixos/*.nix`; pick the file whose name fits.

## Dotfiles and chezmoi

`chezmoi init --apply xentac` works unchanged. A few things in that repo
assume Ubuntu paths and will need edits (do them in the chezmoi source, not
here):

- `.bashrc`: `source /etc/bash_completion` does not exist on NixOS. Delete
  it; `programs.bash.completion.enable` in `users.nix` wires completion
  in automatically. Also drop the `~/.local/kitty.app/bin` PATH entry and
  the nvm block (nvm's downloaded node works via nix-ld but `nodejs` from
  nixpkgs is already on PATH).
- `.config/sway/config`: replace the three
  `/home/xentac/.local/kitty.app/bin/kitty` with `kitty`, and
  `/home/xentac/.local/bin/rofimoji` with `rofimoji`. Remove the
  `ThinkPad_Extra_Buttons` input block and the
  `1:1:AT_Translated_Set_2_keyboard` identifier will likely differ; run
  `swaymsg -t get_inputs` on the new machine. The i3 leftovers
  (`i3-input`, `i3-msg exit`, `dex -ae i3`, `xset -dpms`) do nothing under
  sway. `dispwin $HOME/.icc/display.cal` is the ThinkPad panel's
  calibration; comment it out. Output names `DP-3`/`eDP-1` may change.
  Consider adding `input type:keyboard { xkb_layout custom }` so external
  keyboards get your layout too.
- `.config/xkb/symbols/custom` needs no change; libxkbcommon reads
  `~/.config/xkb` on every distro.
- `.Xmodmap` is dead weight under Wayland.
- `run_once-install-tmux-modules.sh` (TPM) still works on NixOS because
  tmux plugins are shell scripts. `run_once-install-vim-modules.sh` is
  superseded by LazyVim.
- `bin/kb-toggle` and the waybar `custom/keyboard` module reference the
  same keyboard identifier as sway; update together.

### LazyVim on NixOS

Lazy.nvim (plugin manager) works fine: it git-clones plugins into
`~/.local/share/nvim`, and `gcc` is installed so treesitter can compile
parsers. Mason is the problem: it downloads prebuilt LSP binaries. Most
will run thanks to nix-ld, but not reliably. `development.nix` already
installs every LSP, formatter, and linter your `lazyvim.json` extras use
(gopls, basedpyright, typescript-language-server, terraform-ls,
beancount-language-server, markdownlint-cli2, prettier, biome, stylua,
lua-language-server, and so on). LazyVim's documented way to say "this
server comes from the system, not Mason" is `mason = false` per server in
the lspconfig opts, for example in `lua/plugins/lsp.lua`:

```lua
{
  "neovim/nvim-lspconfig",
  opts = {
    servers = {
      gopls = { mason = false },
      basedpyright = { mason = false },
      ts_ls = { mason = false },
      -- one entry per server you use
    },
  },
},
```

Any tool still listed under Mason's `ensure_installed` by an extra will be
downloaded to `~/.local/share/nvim/mason`; check `:Mason` after first
launch and disable what fails. If LazyVim reports a missing tool, add it
to `development.nix`.
Also add `nil` to your LSP config for editing this repo (already installed).

## Migration table

What the survey found on Ubuntu and where it went.

| Ubuntu (apt/snap/flatpak) | NixOS | Notes |
| --- | --- | --- |
| GDM + sway session | `desktop.nix` | `programs.sway` also registers swaylock's PAM entry |
| waybar, mako, rofi, grim, slurp, swayidle, swaylock, wl-clipboard | `desktop.nix` | `bemenu`, `kanshi`, `playerctl` were referenced by sway config but not installed; added |
| kitty from `~/.local/kitty.app` | `pkgs.kitty` | Fix the sway binding paths |
| Dvorak via `/etc/default/keyboard` | `locale-keyboard.nix` | Console, GDM, and sway each configured |
| pipewire, pulseaudio-utils, pavucontrol | `audio.nix` | `pactl` still works |
| NetworkManager, tailscale, mosh, openssh-server | `networking.nix` | |
| NordVPN client | not packaged | Use `wireguard-tools` + NetworkManager with generated configs |
| docker-ce, podman, libvirt, virt-manager, qemu | `virtualisation.nix` | |
| virtualbox | commented out | Conflicts with KVM; prefer libvirt |
| cups + Canon UFR II (`cncups*`) | `hardware-extras.nix` | Canon UFR II not in nixpkgs; use driverless IPP |
| bluez, blueman | `hardware-extras.nix` | |
| yubikey-manager, pcscd | `hardware-extras.nix` | |
| snap: firefox, chromium, thunderbird, discord, steam, go, rustup, rclone, bw, subsurface, google-cloud-cli | nixpkgs | All present |
| flatpak: Slack, Obsidian, Anki, Element, Bruno, RustDesk, Nextcloud, Shotcut, OpenCPN | nixpkgs | All present |
| flatpak: Sober (Roblox), Flatseal, Emote, Smile, SteamLink | flatpak | Keep on flathub; `services.flatpak` stays enabled |
| AppImages (OpenAudible, koreader) | `appimage-run` | koreader is also in nixpkgs |
| nvm + node 25, npm globals | `nodejs`, `pnpm`, `claude-code`, `gemini-cli`, `devcontainer`, `markdownlint-cli2` | |
| cargo: jj, cargo-audit, cargo-binstall | `jujutsu`, `cargo-audit`, `cargo-binstall` | |
| pipx: rofimoji, thunar-plugins | `rofimoji`, thunar plugins | |
| btrbk, restic, resticprofile, borgbackup | `backups.nix` + `apps.nix` | Restic repo config was root-only; fill in the TODO |
| syncthing + syncthingtray | `apps.nix` | System service running as your user |
| ollama | `services.ollama` (off) | Was inactive on Ubuntu |
| unattended-upgrades, snapd, timeshift | gone | Rebuild + generations replace all three |
| autokey, xautolock, xss-lock, compton, i3, maim | dropped | X11-only |
| hyprland | commented out | `programs.hyprland.enable = true` if you still want it |
| texlive-fonts-extra, R | `R` installed; TeX not | Add `texliveMedium` if you need LaTeX |

## Secrets

`/nix/store` is world-readable, so a secret written into any `.nix` file
is readable by every user and process on the machine, and by anyone with
the repo. Never put tokens here.

The Ubuntu `.bashrc` exports a GitHub personal access token, an Alpha
Vantage key, and an admin token in plaintext. Those got printed while
surveying the machine. Rotate them, and move them into a file chezmoi does
not track (for example `~/.config/secrets.sh`) that `.bashrc` sources if
present.

For secrets a *service* needs (restic password, wireguard keys), the
pattern used here is a root-only file under `/etc` referenced by path, for
example `passwordFile = "/etc/restic/password"`. When you outgrow that,
look at `sops-nix` or `agenix`, which encrypt secrets into the repo and
decrypt at activation.

## Verified

- The whole configuration evaluates end to end against nixpkgs 26.05
  (`nix eval ...system.build.toplevel`), so every option and package name
  resolves. It has not been booted.
- The Dvorak keymap reaches the LUKS prompt: with the systemd initrd,
  `console.keyMap` is written into the initrd's `vconsole.conf` and applied
  by `systemd-vconsole-setup` (checked in the locked nixpkgs source,
  `nixos/modules/config/console.nix`).

## Not verified

- `hardware-configuration.nix` is a stub with placeholder UUIDs; the real
  one comes from the new machine.
- Which mainboard you have. Intel is assumed.
- Restic repositories and retention; the Ubuntu profiles were unreadable
  without sudo.
- Sway input and output identifiers on the Framework.
- `nixos-hardware`'s Panther Lake module is new; if graphics or suspend
  misbehave, check its open issues and try `boot.kernelPackages =
  pkgs.linuxPackages_testing`.

## Troubleshooting

- `error: attribute 'foo' missing` or `undefined variable 'foo'`: a
  package or option name is wrong. Search it on search.nixos.org; names
  drift between releases.
- `getting status of '/nix/store/...-source/modules/x.nix': No such file`:
  you forgot `git add` on a new file.
- `The option 'x' is defined multiple times`: two modules set the same
  scalar. Wrap one in `lib.mkDefault` or `lib.mkForce`.
- A downloaded binary says `No such file or directory` even though it
  exists: it needs the dynamic loader. nix-ld is on; if it still fails,
  the program needs a library nix-ld does not provide by default. Add it
  to `programs.nix-ld.libraries`, or find the nixpkgs version.
- Collision between two packages providing the same file: use
  `lib.hiPrio` on the one you want, or remove the other.
- Rebuild succeeded but the desktop looks wrong: dotfiles, not NixOS.
  `chezmoi diff`.
