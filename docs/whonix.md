# Whonix on donatello (KVM)

Whonix-Gateway + Whonix-Workstation as libvirt VMs on donatello, for
Tor work where a compromised app must not learn the real IP. Follows
<https://www.whonix.org/wiki/KVM> (checked 2026-10-10): the images run
as the user (`qemu:///session`) with passt networking, so there are no
`Whonix-External`/`Whonix-Internal` networks to `net-define`.

## Threat model in one table

| Layer | Protects against | Doesn't protect against |
|---|---|---|
| Whonix Gateway/Workstation split | a compromised app learning the real IP | anything on donatello itself |
| `sysmaint` password in each VM | malware in a VM silently gaining root | anyone who can read the qcow2s or use the VM console (GRUB recovery mode = passwordless root) |
| LIVE mode for the Workstation | session leftovers piling up on disk | the running session (RAM) |
| LUKS container for the VM disks (§2) | the disks being read while Whonix isn't running, even with donatello on and you logged in | a running VM: the host sees all of it |
| Host LUKS with TPM + PIN (§8) | a stolen laptop | a laptop stolen while unlocked |

Whonix's docs call full-disk encryption *inside* the VM "unsupported and
does not provide any additional protection"; encryption belongs on the
host, which is what §2 and §8 do. The VMs always trust donatello. For
"no trace on the machine at all", boot Tails from USB on bare metal.

## What the repos provide

- **nixos-config**: `modules/desktop/virtualisation.nix` enables
  libvirtd and virt-manager. `modules/desktop/whonix.nix` installs
  `passt` and the `whonix up|down|status` script.
  `modules/desktop/hardware-extras.nix` has `e2fsprogs` (`chattr`).
  `just tpm-enroll` handles §8.
- **chezmoi**: `private_dot_config/libvirt/qemu.conf` sets
  `max_core`/`max_processes`/`max_files = 0` for session-mode QEMU, as
  the Whonix guide requires.

## 1. Get the images

1. `just switch` once, if `which whonix passt chattr` doesn't find all three.
2. From the wiki's download section, fetch the libvirt image (LXQt for
   a desktop, CLI for headless), e.g.
   `Whonix-LXQt-<version>.Intel_AMD64.qcow2.libvirt.xz`, plus its `.asc`.
3. Verify (import Patrick Schleizer's signing key per the wiki first):

   ```sh
   gpg --verify Whonix-*.libvirt.xz.asc Whonix-*.libvirt.xz
   tar -xSvf Whonix*.libvirt.xz          # -S keeps the qcow2s sparse
   more WHONIX_BINARY_LICENSE_AGREEMENT
   touch WHONIX_BINARY_LICENSE_AGREEMENT_accepted
   ```

## 2. The encrypted container

The VM disks live in a LUKS container file, opened only while Whonix
runs. The layers, top to bottom:

```
qcow2 files (Gateway, Workstation, Workstation-data)
  ext4                              ~/.local/share/whonix   (mounted while open)
  dm-crypt (LUKS)                   /dev/mapper/whonix
  loop device                       (cryptsetup attaches it itself)
  whonix.luks, sparse, NOCOW        ~/.local/share/images/
  btrfs subvolume, not snapshotted  ~/.local/share/images
  @home on host LUKS
```

How this fits btrfs and qcow2:

- **No CoW on CoW.** The qcow2s sit on ext4, as they would on any
  plain Linux host. btrfs only sees one big file, and it's NOCOW (`+C`
  on the directory), so random writes overwrite in place.
- **Never snapshotted.** btrfs snapshots don't descend into nested
  subvolumes, so btrbk (daily, kept up to 6 months) and restic → B2
  (a snapshot of `/home`) both skip `images/`. That also keeps NOCOW
  intact: a snapshot forces CoW on the next write to each shared block.
- **Sparse both ways.** The container is a 256 GB sparse file that only
  uses what ext4 has written. `--allow-discards` plus the `discard`
  mount option (both in `whonix up`) hand freed blocks back to btrfs as
  holes. The qcow2s themselves only grow, never shrink: deleting files
  in the guest doesn't shrink them. LIVE mode (§5) keeps the
  Workstation's system disk from growing much.
- **Costs.** NOCOW files get no btrfs checksums or compression, and
  nothing in the container is backed up. Copy anything you want to keep
  out deliberately. The system qcow2s are re-downloadable.
- **Size.** Gateway and Workstation are 100 GB *virtual* each, plus 20 GB
  for the data disk in §6. That's 220 GB worst case, inside 256 GB. If
  the container fills, the VMs get I/O errors, so don't grow the qcow2s
  past it.

Create it (one time; the passphrase is the Whonix-at-rest secret, so
make it different from the host LUKS one):

```sh
btrfs subvolume create ~/.local/share/images  # skip if it already exists
chattr +C ~/.local/share/images               # while empty; new files inherit it
truncate -s 256G ~/.local/share/images/whonix.luks
sudo cryptsetup luksFormat ~/.local/share/images/whonix.luks
sudo cryptsetup open --allow-discards ~/.local/share/images/whonix.luks whonix
sudo mkfs.ext4 -L whonix -m 0 /dev/mapper/whonix
mkdir -p ~/.local/share/whonix
sudo mount /dev/mapper/whonix ~/.local/share/whonix
sudo chown "$USER:" ~/.local/share/whonix
```

## 3. Import

With the container open (as §2 leaves it; later, `whonix up` opens it
first):

```sh
mv Whonix-Gateway*.qcow2     ~/.local/share/whonix/Whonix-Gateway.qcow2
mv Whonix-Workstation*.qcow2 ~/.local/share/whonix/Whonix-Workstation.qcow2

# The XMLs reference their disks as volumes in pool "default", which a
# fresh session doesn't have. No autostart: the directory is empty
# while the container is locked; `whonix up` starts the pool.
virsh -c qemu:///session pool-define-as default dir --target ~/.local/share/whonix
virsh -c qemu:///session pool-start default

virsh -c qemu:///session define Whonix-Gateway*.xml
virsh -c qemu:///session define Whonix-Workstation*.xml
whonix down    # lock the container until first use
```

If `define` or `start` complains about `/usr/bin/qemu-system-x86_64` or
a Debian OVMF path, the XML hardcodes Debian locations:
`virsh -c qemu:///session edit <vm>` and drop the `<emulator>` line
(libvirt finds QEMU itself) or point the path into the Nix store.

### Migrating from the earlier plain layout

The first version of this doc kept the qcow2s directly in
`~/.local/share/images` with a pool pointing there. To move them in:

```sh
virsh -c qemu:///session shutdown Whonix-Workstation
virsh -c qemu:///session shutdown Whonix-Gateway   # wait until both are "shut off"
# §2's create block, minus the subvolume/chattr lines (already done)
mv ~/.local/share/images/Whonix-*.qcow2 ~/.local/share/whonix/
rm ~/.local/share/images/.nobackup
virsh -c qemu:///session pool-destroy default
virsh -c qemu:///session pool-undefine default
virsh -c qemu:///session pool-define-as default dir --target ~/.local/share/whonix
whonix down    # locks the container; `whonix up` from now on
```

The blocks the old plaintext qcow2s used are freed on btrfs but stay
under the host LUKS until reused or trimmed: the same protection as
before, nothing worse.

## 4. Run

```sh
whonix up        # sudo + container passphrase, pool, Gateway, then Workstation
whonix down      # clean shutdown of both, pool stopped, container locked
whonix status
```

Open the consoles in virt-manager: add a "QEMU/KVM User session"
connection (File → Add Connection); it defaults to the system one, where
these VMs don't exist. `whonix down` waits 90 s per VM. If a VM won't
shut down cleanly, it stops and leaves the container open.

## 5. Accounts, passwords, boot modes

Each VM has three accounts:

- **`user`**: daily use. It can't use `sudo`, `su` or `pkexec` at all.
- **`sysmaint`**: updates and installing packages. Reached by picking
  the SYSMAINT entry in the VM's GRUB menu; it gets a minimal desktop.
- **`root`**: locked. Leave it.

All log in without a password by default. Set passwords in **both**
VMs, Gateway included. The Gateway holds no personal data, but it's
the one VM every packet trusts: a root compromise there (e.g. via a
Tor bug) can redirect or watch everything, and a `sysmaint` password
stops a non-root foothold escalating silently. In a PERSISTENT
SYSMAINT session:

```sh
sudo -n true && echo "sudo was passwordless"   # just to know the default
sudo passwd sysmaint
sudo passwd user                               # also guards the screen lock
```

Which boot entry to pick:

| VM | Daily | Maintenance |
|---|---|---|
| Gateway | PERSISTENT mode USER | PERSISTENT mode SYSMAINT |
| Workstation | **LIVE mode USER** | PERSISTENT mode SYSMAINT |

Keep the Gateway persistent: Tor's entry guards are kept on its disk,
and a fresh guard set every boot is worse for anonymity. LIVE mode on
the Workstation sends all writes to RAM and drops them at power-off
(the closest thing to Tails' amnesia). The Workstation has 8 GB, which
also limits how much you can download in one session. Updates
(`upgrade-nonroot`, or the updater in SYSMAINT) have to run in
PERSISTENT SYSMAINT, or they're lost at shutdown.

## 6. Persistent data: a second disk

LIVE mode throws away `/home/user` too. For files that should survive
(the rough equivalent of Tails' Persistent Storage), give the
Workstation a second disk. It lives inside the container, so it's
already encrypted at rest. With the container open (`whonix up`, then
shut the Workstation down; the pool must be running):

```sh
virsh -c qemu:///session vol-create-as default Whonix-Workstation-data.qcow2 20G --format qcow2
virsh -c qemu:///session attach-disk Whonix-Workstation \
  ~/.local/share/whonix/Whonix-Workstation-data.qcow2 vdb \
  --driver qemu --subdriver qcow2 --config
```

Then boot it in PERSISTENT SYSMAINT (so the fstab edit sticks):

```sh
lsblk                                  # the new empty 20G disk, normally vdb
sudo mkfs.ext4 -L persist /dev/vdb
sudo mkdir /home/user/Persistent
echo 'LABEL=persist /home/user/Persistent ext4 defaults,noatime,nofail 0 2' | sudo tee -a /etc/fstab
sudo mount /home/user/Persistent && sudo chown user:user /home/user/Persistent
```

**Not yet verified:** that LIVE mode leaves additional disks writable
(it's documented as overlaying the system disk, but not explicitly
other disks). First LIVE USER boot: `findmnt /home/user/Persistent`
should show it `rw`. Create a file, reboot into LIVE USER again, and
check it's still there.

Why no LUKS inside the guest on top: the container already covers the
disk at rest, and while the VM runs donatello can read it regardless.
Also, `user` can't run `cryptsetup`, so unlocking would mean booting
SYSMAINT every time, which defeats LIVE mode. If you want a
separately-locked compartment anyway, a VeraCrypt/zuluCrypt container
file on this disk works, but check first that `user` can open one.

## 7. Updating

- Workstation and Gateway: boot PERSISTENT SYSMAINT and update there.
  No re-downloading images.
- Domain XML lives in `~/.config/libvirt/qemu/`, UEFI vars in
  `~/.config/libvirt/qemu/nvram/`, the pool in `~/.config/libvirt/storage/`.
  These are small, in the normal home backups, and contain nothing
  sensitive.
- Remove a VM: `virsh -c qemu:///session undefine <vm> --nvram`, then
  delete its qcow2 with the container open.

## 8. Host: TPM + PIN

`hosts/donatello/default.nix` unlocks `cryptroot` and `cryptswap` from
the TPM, bound to PCR 7 only. Secure Boot is off on donatello
(`bootctl status`), so PCR 7 reads the same whatever boots. TPM-only
unlock therefore protected little: an OS booted from USB could unseal
the key. Adding a PIN fixes that. Without it the TPM won't release the
key, and its lockout rate-limits guessing.

```sh
just tpm-enroll   # per device: LUKS passphrase, then the new PIN (same PIN for both)
```

It enrolls the new TPM2+PIN token, then wipes the old TPM2-only one.
The passphrase keeps working as a fallback. Check: `sudo cryptsetup luksDump /dev/disk/by-uuid/<uuid>` should show
one `systemd-tpm2` token with `tpm2-pin: true`. Reboot to test (have the
passphrase at hand). Expect one
PIN prompt, maybe two if systemd doesn't reuse the PIN for the second
device, and test resume from hibernate the same way. If the TPM ever
refuses (firmware update, lockout), use the passphrase and rerun
`just tpm-enroll`.

The PIN prompt comes from the systemd initrd
(`boot.initrd.systemd.enable` in `modules/desktop/boot.nix`). The
older scripted initrd doesn't do TPM tokens, so keep that on.

Later improvement: Secure Boot via lanzaboote, then bind PCR 7 with
Secure Boot actually on.
