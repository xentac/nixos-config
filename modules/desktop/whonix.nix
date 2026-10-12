# Whonix Gateway/Workstation VMs (qemu:///session). Setup and the why:
# docs/whonix.md. The VM disks live in a LUKS container file that is only
# open while Whonix runs; `whonix up` / `whonix down` wrap that.
{ pkgs, ... }:
let
  whonix = pkgs.writeShellApplication {
    name = "whonix";
    runtimeInputs = with pkgs; [
      cryptsetup
      libvirt
      util-linux
    ];
    text = ''
      img="$HOME/.local/share/images/whonix.luks"
      mnt="$HOME/.local/share/whonix"
      map=whonix
      virsh() { command virsh -c qemu:///session "$@"; }

      running() { [ "$(virsh domstate "$1" 2>/dev/null)" = running ]; }

      open() {
        mountpoint -q "$mnt" && return
        mkdir -p "$mnt"
        # Full store paths: sudo's secure_path need not contain them.
        # cryptsetup attaches the loop device itself (autoclear on close).
        # --allow-discards + the discard mount option hand freed blocks back
        # to btrfs as holes, so the sparse container file can shrink.
        [ -e "/dev/mapper/$map" ] || sudo ${pkgs.cryptsetup}/bin/cryptsetup open --allow-discards "$img" "$map"
        sudo ${pkgs.util-linux}/bin/mount -o noatime,discard "/dev/mapper/$map" "$mnt"
      }

      close() {
        if mountpoint -q "$mnt"; then sudo ${pkgs.util-linux}/bin/umount "$mnt"; fi
        if [ -e "/dev/mapper/$map" ]; then sudo ${pkgs.cryptsetup}/bin/cryptsetup close "$map"; fi
      }

      stop_vm() {
        running "$1" || return 0
        virsh shutdown "$1" >/dev/null
        for _ in $(seq 90); do
          running "$1" || return 0
          sleep 1
        done
        echo "$1 still running after 90s; shut it down from inside, then rerun." >&2
        exit 1
      }

      case "''${1:-}" in
        up)
          open
          if ! virsh pool-info default | grep -q 'State:.*running'; then
            virsh pool-start default >/dev/null
          fi
          shift
          # Gateway first: the Workstation has no network without it.
          for vm in Whonix-Gateway "''${@:-Whonix-Workstation}"; do
            running "$vm" || virsh start "$vm"
          done
          ;;
        down)
          stop_vm Whonix-Workstation
          stop_vm Whonix-Gateway
          if virsh pool-info default 2>/dev/null | grep -q 'State:.*running'; then
            virsh pool-destroy default >/dev/null
          fi
          close
          echo "Whonix stopped and container locked."
          ;;
        status)
          virsh list --all
          if mountpoint -q "$mnt"; then echo "container: open at $mnt"; else echo "container: locked"; fi
          ;;
        *)
          echo "usage: whonix up [vm...] | down | status" >&2
          exit 2
          ;;
      esac
    '';
  };
in
{
  environment.systemPackages = [
    whonix
    pkgs.passt # user-mode networking for the session VMs
  ];
}
