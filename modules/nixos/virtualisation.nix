# Containers and VMs. On Ubuntu you run docker + podman + libvirt + VirtualBox.
{ pkgs, ... }:
{
  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
  };

  virtualisation.podman = {
    enable = true;
    dockerCompat = false; # docker is present, so no `docker` shim
    defaultNetwork.settings.dns_enabled = true;
  };

  # libvirt/KVM + virt-manager (your "win10" VM: copy the qcow2 + XML over).
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      swtpm.enable = true; # TPM emulation, needed for Windows 11
    };
  };
  programs.virt-manager.enable = true;
  virtualisation.spiceUSBRedirection.enable = true;

  environment.systemPackages = with pkgs; [
    docker-compose
    podman-compose
    dive
    kubectl
    kubernetes-helm
    vagrant
  ];
}
