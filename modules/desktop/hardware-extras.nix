# Bluetooth, printing, firmware updates, fingerprint, YubiKey, power.
{ pkgs, lib, ... }:
{
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };
  services.blueman.enable = true;

  # Printing. Canon UFR II (`cncups*` on Ubuntu) is NOT in nixpkgs; use
  # driverless/IPP Everywhere for the Canon (most imageRUNNER support it).
  services.printing = {
    enable = true;
    drivers = with pkgs; [
      epson-escpr
      gutenprint
    ];
  };

  # Framework ships firmware via LVFS. `fwupdmgr update` after install.
  services.fwupd.enable = true;

  # Fingerprint reader (nixos-hardware enables this too). Enroll with
  # `fprintd-enroll`. Note: swaylock does NOT support fingerprint by default.
  services.fprintd.enable = lib.mkDefault true;

  # YubiKey: smartcard daemon + udev rules so ykman works as your user.
  services.pcscd.enable = true;
  services.udev.packages = with pkgs; [ yubikey-personalization ];

  # Power. nixos-hardware's framework module already enables
  # power-profiles-daemon; don't ALSO enable TLP (they conflict).
  services.power-profiles-daemon.enable = lib.mkDefault true;
  # Low battery while in use: upower runs the action itself (no DE needed on
  # sway). Hibernate at 7% — the default (HybridSleep at 2%) is too late to
  # write 64G of RAM to disk, which is how the battery-death happened.
  services.upower = {
    enable = true;
    percentageLow = 15;
    percentageCritical = 10;
    percentageAction = 7;
    criticalPowerAction = "Hibernate";
  };

  # Lid: suspend-then-hibernate on battery, ignore when docked (external
  # monitor at the desk). With no HibernateDelaySec set, systemd estimates the
  # discharge rate during suspend and converts to hibernate before the battery
  # runs out (AMD is s2idle-only, so closed-lid drain is real).
  services.logind.settings.Login = {
    HandleLidSwitch = "suspend-then-hibernate";
    HandleLidSwitchDocked = "ignore";
  };
  systemd.sleep.settings.Sleep.SuspendEstimationSec = "1h";

  services.smartd.enable = true;

  environment.systemPackages = with pkgs; [
    yubikey-manager
    lm_sensors
    nvme-cli
    smartmontools
    usbutils
    pciutils
    acpi
    powertop
    exfatprogs
    ntfs3g
    btrfs-progs
    gparted
  ];
}
