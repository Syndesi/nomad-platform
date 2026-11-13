# Full disk encryption and reboots

**Not part of the platform.** Encrypting the disk is part of the OS installation, before ansible gets to the node; this repo does not install,
configure or test it. This page is the contract between the two, and notes for choosing a method. Nothing here was tried on a VM or a real node;
statements about tools are from their documentation and marked "check" where they should be verified before you rely on them.

## Why it matters here

The platform reboots nodes by itself at night when a kernel update wants it (`docs/reference.md`, "Reboots"). A node with an encrypted disk only
comes back from that if its disk **unlocks without a person**. Full disk encryption protects a disk that is switched off (a stolen or recycled
disk, a provider that copies volumes). It does not protect against anything running on the node, a kernel exploit included.

## The contract

* The OS is installed and bootable, ssh works, `scripts/node-bootstrap.sh` has run. How the disk is encrypted is not the platform's business.
* A node that unlocks itself at boot (see below) is a normal node: nothing to configure.
* A node that waits for a passphrase (typed on a console, sent over ssh into the initramfs) gets `cluster_reboot_requires_unlock: true` in its `host_vars`.
  It never reboots by itself, `task maintenance` skips it and lists it, and you reboot and unlock it when the list says so.
* **VPS (e.g. OVH):** pre-installed images, no encryption (decided). Nothing to do except updates and nightly reboots, which work as on any node.
  An unencrypted node that reboots itself needs no unlock, so `cluster_reboot_requires_unlock` stays `false`.

## Ways to unlock without a person

| Method | How it works | Needs | Notes |
|---|---|---|---|
| **Clevis + Tang** | the LUKS key is bound to a Tang server; at boot the initramfs asks Tang over the network and derives the key. Tang keeps no keys of the clients and never sees the disk key | a Tang server that is up and reachable at boot, network in the initramfs | Debian: `clevis-luks`, `clevis-initramfs` (check the trixie versions). Alpine: the `clevis` package exists, the initramfs integration does not: a hook of your own (check) |
| **Clevis `sss` (Shamir)** | combines pins: e.g. Tang **and** TPM2 (both needed), or Tang A **or** Tang B (any one: a Tang outage does not lock you out) | as above, a TPM2 for that pin | the answer to "Tang must not be a single point of failure" and to "Tang is reachable by a thief" (below) |
| **TPM2 only** | key sealed to the TPM and the boot state (PCRs) | a TPM (a VM needs a virtual one) | no network needed; a firmware or bootloader update changes the PCRs and the key no longer unseals (re-enroll). Check how well trixie's initramfs handles it |
| **ZFS `keylocation=https://...`** | the dataset's key is fetched from a URL when it is loaded (`zfs load-key`) | ZFS native encryption, a key server, network at that moment | simple to run and to understand, but see the notes below |
| **Passphrase** | typed on the console, or over ssh into the initramfs (dropbear) | a person | = `cluster_reboot_requires_unlock: true`. Check what the initramfs sshd offers for key exchange: the platform requires `mlkem768x25519-sha256` for the running system, that was not looked at for the initramfs |

### Tang: what it does and does not protect

Tang answers anyone who asks. The security is that **the key can only be recovered while Tang is reachable**: a disk that leaves the building (or the network
Tang is on) cannot be unlocked. A thief who also reaches the Tang server can unlock it. So Tang is only as good as the network it sits on:

* On a LAN or a VPN that the disk never sees outside: fine. This is the homelab case.
* Reachable from the internet: the disk is protected against nobody who has the disk and an internet connection. Put a second factor beside it
  (`sss` with a TPM2 pin) or do not use it.
* A provider's private network is not an alternative for a VPS (extra cost, regular VMs only): this is one more reason a VPS stays unencrypted.
* **Do not run Tang (or the key server) as a job on the cluster it unlocks.** After a full outage nothing could boot. Run it on a separate small always-on
  machine, or two (`sss` 1-of-2).

### ZFS `keylocation=https://`

The key is fetched over TLS, so the server is authenticated by its certificate and anything that reaches the server and passes its access rules gets the
key. Compared to Tang the key server **has the key** (escrow: you protect it like the disk itself), but access control can be real (client
certificates, a VPN, a token) instead of "whoever is on the network". Points to check before choosing it:

* Which client authentication `zfs load-key` can do (client certificate, basic auth in the URL, headers); the first version of this page does not know.
* When it runs at boot (initramfs of a ZFS root, or a unit after the network for a data pool), and that the network is configured by then.
* The pool of a root filesystem needs the initramfs to know ZFS; on Debian that is the `zfs-initramfs` package (DKMS or a prebuilt module for the kernel,
  which a kernel update must rebuild: do it before the nightly reboot, not after).
* What happens if the server is down at boot (the node waits; with `cluster_reboot_requires_unlock: false` the nightly job has then taken it down for a
  longer time than planned).

## Whichever you pick

1. Test a reboot **by hand** first, with the key server up, then down (the node must wait and then finish booting once it is back, not stay locked).
2. Check that everything the platform needs starts after the unlock: sshd, nomad, consul, docker (`task smoke -- connect` after the reboot).
3. Keep a break-glass passphrase (a second LUKS key slot, or a second ZFS key) offline.
4. Then `cluster_reboot_requires_unlock: false` and let the nightly job do it, or `true` if a person has to be there.
