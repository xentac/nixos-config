# NixOS configuration for donatello (Framework Laptop 13 Pro)

This repo is the complete, declarative description of donatello, the
Framework Laptop 13 with the AMD Ryzen AI 300 mainboard: bootloader,
kernel, desktop, services, users, and every installed package. The
machine has been running from it since 2026-09-08. Rebuilding from it
produces the same system every time.

Dotfiles are **not** in here. They stay in chezmoi
(<https://github.com/xentac/dotfiles>). See
[Dotfiles and chezmoi](#dotfiles-and-chezmoi) for how the two repos
divide the work.

Historical docs: [docs/install.md](docs/install.md) is the from-scratch
(re)install walkthrough; [docs/migration.md](docs/migration.md) records
the Ubuntu ("baxter") → NixOS migration this config came from.
Design notes: [docs/backups.md](docs/backups.md) records the
one-restic-repo-per-host decision for when a second machine joins.

## Status

- Installed and running since 2026-09-08; the system tracks this repo.
- LUKS unlock via TPM is enrolled (passphrase stays as fallback).
- btrbk local snapshots run daily and are verified working.
- **TODO — offsite backup**: the restic block in `backups.nix` is still
  commented out pending a repository decision. Local snapshots are not
  a backup.
- **TODO — hibernation untested**: `boot.resumeDevice` is set, but it
  becomes a `resume=` kernel parameter, so it only takes effect on the
  next boot — a switch is not enough. Reboot, then test
  `systemctl hibernate` at the laptop: expect a full power-off, then
  resume through the LUKS unlock with the session intact.

## Layout

```text
flake.nix                       entry point: inputs (nixpkgs, nixos-hardware), the system, nix fmt formatter
flake.lock                      exact commits of every input; commit it
hosts/donatello/
  default.nix                   this machine: hardware variant, hostname, kernel, hibernate, TPM, stateVersion
  hardware-configuration.nix    disks/filesystems/LUKS, synced from the booted system
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
  shell.nix                     zsh + starship (machinery only; config is in chezmoi)
  apps.nix                      GUI applications, syncthing, flatpak
  gaming.nix                    steam
  backups.nix                   btrbk snapshots, restic skeleton (TODO)
justfile                        `just switch`, `just update`, `just gc`, ...
docs/                           install walkthrough, migration record
.github/workflows/check.yml     CI: evaluate the config + check formatting on push
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

`nixos-rebuild switch --flake .#donatello` evaluates `flake.nix`, which
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

`system.stateVersion` in `hosts/donatello/default.nix` is not "which
version you run". It tells stateful services which on-disk format they
were created with. It was set at install and never gets bumped.

## How the pieces connect

```text
nixos-rebuild switch --flake .#donatello
  └─ flake.nix: nixosConfigurations.donatello
       └─ hosts/donatello/default.nix
            ├─ inputs.nixos-hardware.nixosModules.framework-amd-ai-300-series
            ├─ hosts/donatello/hardware-configuration.nix   (disks, kernel modules)
            └─ modules/nixos/default.nix
                 ├─ nix-settings.nix   boot.nix   locale-keyboard.nix
                 ├─ networking.nix     desktop.nix   audio.nix
                 ├─ hardware-extras.nix   virtualisation.nix   development.nix
                 └─ fonts.nix   users.nix   shell.nix   apps.nix   gaming.nix   backups.nix
```

`specialArgs = { inherit inputs; }` in `flake.nix` is what lets
`hosts/donatello/default.nix` refer to `inputs.nixos-hardware`. Every module
receives `pkgs` (the package set) and `lib` (helper functions) as arguments
automatically.

## Daily use

| Task | Command |
| --- | --- |
| Apply a change | `just switch` (or `sudo nixos-rebuild switch --flake .#donatello`) |
| Check for errors without activating | `just check` |
| Try a change until next reboot | `just test` |
| Undo the last switch | `sudo nixos-rebuild switch --rollback` |
| Update all packages | `just update && just switch` |
| Free disk space | `just gc` |
| Format the .nix files | `just fmt` (runs `nix fmt`; CI enforces it) |
| Run a program once without installing | `nix run nixpkgs#cowsay` |
| Shell with extra tools | `nix shell nixpkgs#hugo nixpkgs#go` |
| Search packages | `nix search nixpkgs foo` or <https://search.nixos.org> |
| Why is X installed? | `nix-tree /run/current-system` |

Editing workflow: change a file, `git add` it if new, `just switch`. A
typo produces an evaluation error before anything touches the system;
read the last few lines, they name the file and option. CI runs the same
evaluation (plus a format check) on every push.

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

The split: NixOS installs programs and enables machinery; chezmoi
configures them. `shell.nix` enables zsh, autosuggestions, syntax
highlighting, and the starship prompt system-wide, but aliases,
functions, `~/.zshrc`, and `~/.config/starship.toml` come from chezmoi
(zsh reads `/etc/zshrc` — this config — before `~/.zshrc`, and starship
prefers the user config when it exists). The custom Dvorak variant in
`~/.config/xkb/symbols/custom` is also chezmoi's; libxkbcommon reads
that directory on every distro.

After a change that looks wrong on the desktop: it is usually dotfiles,
not NixOS. `chezmoi diff` first.

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

## Remote access

SSH comes in over tailscale: `tailscale0` is a trusted interface in
`networking.nix`, sshd allows keys only (no passwords), and
`~/.ssh/authorized_keys` is chezmoi-managed. No key lives in this repo.

## Secrets

`/nix/store` is world-readable, so a secret written into any `.nix` file
is readable by every user and process on the machine, and by anyone with
the repo. Never put tokens here.

For secrets a *service* needs (restic password, wireguard keys), the
pattern used here is a root-only file under `/etc` referenced by path, for
example `passwordFile = "/etc/restic/password"`. When you outgrow that,
look at `sops-nix` or `agenix`, which encrypt secrets into the repo and
decrypt at activation. User-level secrets live in a file chezmoi does not
track (`~/.config/secrets.sh`) that the shell rc sources if present.

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
- Suspend/graphics oddities on the Ryzen AI 300: check the nixos-hardware
  issues for `framework-amd-ai-300-series`.
