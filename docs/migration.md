# Migration from baxter (Ubuntu 26.04 / ThinkPad)

Historical record. The config was drafted from a survey of the Ubuntu
26.04 sway install on the ThinkPad ("baxter") so donatello would start
out feeling like the old machine. The migration completed in September
2026; everything below is done, kept for reference.

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
| virtualbox | dropped | Conflicts with KVM; the `win10` VM runs under libvirt |
| cups + Canon UFR II (`cncups*`) | `hardware-extras.nix` | Canon UFR II not in nixpkgs; use driverless IPP |
| bluez, blueman | `hardware-extras.nix` | |
| yubikey-manager, pcscd | `hardware-extras.nix` | |
| snap: firefox, chromium, thunderbird, discord, steam, go, rustup, rclone, bw, subsurface, google-cloud-cli | nixpkgs | All present |
| flatpak: Slack, Obsidian, Anki, Element, Bruno, Nextcloud, Shotcut, OpenCPN | nixpkgs | All present |
| flatpak: RustDesk, Sober (Roblox), Flatseal, Emote, Smile, SteamLink | flatpak | Keep on flathub; `services.flatpak` stays enabled |
| AppImages (OpenAudible, koreader) | `appimage-run` | koreader is also in nixpkgs |
| nvm + node 25, npm globals | `nodejs`, `pnpm`, `claude-code`, `gemini-cli`, `devcontainer`, `markdownlint-cli2` | |
| cargo: jj, cargo-audit, cargo-binstall | `jujutsu`, `cargo-audit`, `cargo-binstall` | |
| pipx: rofimoji, thunar-plugins | `rofimoji`, thunar plugins | pipx itself is dropped; use `uv tool install` |
| btrbk, restic, resticprofile, borgbackup | `backups.nix` + `apps.nix` | `services.restic.backups` replaces resticprofile; repo config was root-only, fill in the TODO |
| syncthing + syncthingtray | `apps.nix` | System service running as your user |
| ollama | `services.ollama` (off) | Was inactive on Ubuntu |
| unattended-upgrades, snapd, timeshift | gone | Rebuild + generations replace all three |
| autokey, xautolock, xss-lock, compton, i3, maim | dropped | X11-only |
| hyprland | dropped | Was installed on Ubuntu, never adopted |
| texlive-fonts-extra, R | `R` installed; TeX not | Add `texliveMedium` if you need LaTeX |

## Dotfile edits the migration needed

These were done in the chezmoi source at the time:

- `.bashrc`: `source /etc/bash_completion` does not exist on NixOS;
  `programs.bash.completion.enable` wires completion in automatically.
  Dropped the `~/.local/kitty.app/bin` PATH entry and the nvm block.
  (The interactive shell later moved to zsh entirely — `shell.nix`.)
- `.config/sway/config`: replaced the three
  `/home/xentac/.local/kitty.app/bin/kitty` with `kitty`, and
  `/home/xentac/.local/bin/rofimoji` with `rofimoji`. Removed the
  `ThinkPad_Extra_Buttons` input block; keyboard/output identifiers
  re-checked with `swaymsg -t get_inputs` on the Framework. The i3
  leftovers (`i3-input`, `i3-msg exit`, `dex -ae i3`, `xset -dpms`) did
  nothing under sway. `dispwin $HOME/.icc/display.cal` was the ThinkPad
  panel's calibration.
- `.config/xkb/symbols/custom` needed no change; libxkbcommon reads
  `~/.config/xkb` on every distro.
- `.Xmodmap` is dead weight under Wayland.
- `run_once-install-tmux-modules.sh` (TPM) still works on NixOS because
  tmux plugins are shell scripts. `run_once-install-vim-modules.sh` is
  superseded by LazyVim.
- `bin/kb-toggle` and the waybar `custom/keyboard` module reference the
  same keyboard identifier as sway; update together.

## Secrets found during the survey

The Ubuntu `.bashrc` exported a GitHub personal access token, an Alpha
Vantage key, and an admin token in plaintext, and they got printed while
surveying the machine. They needed rotating, and secrets now live in a
file chezmoi does not track (e.g. `~/.config/secrets.sh`) that the shell
rc sources if present.
