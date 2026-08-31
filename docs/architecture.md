# Homelab Infrastructure — Architecture & Build Log

## Overview
A version-controlled home lab running on a Hyper-V host, provisioned with
Terraform and configured with Ansible. Goal: reproducible infrastructure
that can be rebuilt from code rather than manual clicking.

## Stack
- **Hypervisor:** Hyper-V (Windows Server)
- **Provisioning:** Terraform (taliesins/hyperv provider)
- **Remote access:** Tailscale (encrypted tunnel, no public port exposure)
- **Remote management:** WinRM
- **First VM:** ubuntu-node1 — Ubuntu Server 24.04, 1 vCPU, 1GB RAM, 20GB disk

## Network Topology

### The path a Terraform command takes
1. **My PC** runs `terraform apply`.
2. Terraform connects over **WinRM (port 5985)** — but not directly over
   the LAN or the internet. It connects through a **Tailscale** tunnel.
3. **Tailscale** gives both my PC and the Hyper-V host a private
   `100.x.x.x` address that only devices on my personal Tailnet can
   reach. Traffic is encrypted end-to-end and never touches the public
   internet, even though I'm often not on the same physical network as
   the server.
4. WinRM, running on the **Hyper-V host**, receives the command and
   talks to the **Hyper-V API** locally to create/modify VMs.
5. The VM itself (e.g. `ubuntu-node1`) sits on a virtual switch
   (`WTS-External`) bridged to the host's physical network, so it gets
   its own IP on the LAN once it boots.

### Why Tailscale instead of a port-forward
My first instinct was to forward WinRM's port through the router the
same way RDP already was. I backed away from that once I understood
the actual risk: WinRM was configured with `AllowUnencrypted = true`
and Basic auth for lab simplicity — meaning credentials would travel
in near-plaintext. RDP is hardened for internet exposure by design;
WinRM in this configuration is not. Exposing it publicly would mean
automated internet scanners could realistically find and attempt to
authenticate against a control channel for the hypervisor itself.

Tailscale solves this without giving up remote access: it creates a
private mesh network between only my own devices, so WinRM is never
reachable from the open internet at all, regardless of what auth
settings it uses locally.

### Diagram
```
My PC ──(Tailscale tunnel, encrypted)──▶ Hyper-V Host ──(WinRM)──▶ Hyper-V API ──▶ VM (WTS-External vSwitch) ──▶ Home LAN
```

## Build Log: Issues Hit and How They Were Resolved

### 1. Terraform not found after install
**Problem:** `terraform --version` returned "not recognized" after
`winget install`.
**Diagnosis:** winget installed the binary but didn't add it to PATH
in the current shell session.
**Fix:** Located the install path with `Get-ChildItem`, added it to
the user PATH manually via `[Environment]::SetEnvironmentVariable`,
and opened a fresh terminal (PATH changes don't apply retroactively
to open sessions).

### 2. Public port-forward instead of a private tunnel
**Problem:** Initial WinRM setup pointed at the server's public IP,
reachable via the same port-forward already used for RDP.
**Diagnosis:** WinRM was configured with `AllowUnencrypted = true`
and Basic auth for lab convenience — safe on a private LAN, not safe
exposed to the open internet, where automated scanners actively probe
for exactly this kind of misconfigured endpoint.
**Fix:** Installed Tailscale on both the PC and the server, and
pointed Terraform at the private Tailscale IP instead. WinRM traffic
now never leaves an encrypted private tunnel between my own devices.

### 3. Windows path format causing a provider error
**Problem:** `terraform apply` failed with "Provider produced
inconsistent final plan" after successfully creating the VHD.
**Diagnosis:** The config used forward slashes (`C:/VMs/...`), but
Windows/Hyper-V returned the actual path with backslashes
(`C:\VMs\...`). Terraform's plan/apply consistency check caught the
mismatch and refused to proceed rather than silently guessing.
**Fix:** Rewrote the path using escaped backslashes
(`C:\\VMs\\...`) to match what Windows actually returns.

### 4. DVD drives silently not attaching
**Problem:** `terraform apply` reported success, but
`Get-VMDvdDrive` on the actual VM showed zero drives attached.
**Diagnosis:** `terraform state show` confirmed Terraform's own
recorded state also had no `dvd_drives` block — the resource was
silently dropped rather than erroring, tracing back to a malformed
block in `main.tf`.
**Fix:** Corrected the `dvd_drives` block syntax and re-applied;
confirmed via `terraform state show` that the drives were actually
recorded this time before trusting `apply`'s "success" output again.

### 5. Secure Boot blocking the Linux installer
**Problem:** VM would only boot to network (PXE), never to the
attached Ubuntu installer ISO.
**Diagnosis:** `vm_firmware.secure_boot_template` defaulted to
`MicrosoftWindows`, which only trusts Windows-signed bootloaders —
Ubuntu's installer is signed differently and was being silently
rejected.
**Fix:** Added an explicit `vm_firmware` block setting
`secure_boot_template = "MicrosoftUEFICertificateAuthority"`, the
correct template for non-Windows UEFI bootloaders.

### 6. DVD drives existed but had no media attached
**Problem:** After a `terraform destroy`/`apply` rebuild, `Add-VMDvdDrive`
failed with "no available locations found," even though the drives
appeared to be missing.
**Diagnosis:** `Get-VMDvdDrive` revealed the drive *bays* already
existed (created by Terraform) but with `DvdMediaType: None` — empty
slots, not missing slots. `Add-VMDvdDrive` adds a new drive; it can't
fill an existing empty one.
**Fix:** Used `Set-VMDvdDrive` instead, which assigns media to an
already-existing drive bay rather than trying to create a new one.

### 7. PowerISO built a technically-invalid ISO
**Problem:** The Ubuntu installer never recognized the seed volume —
it always fell back to full interactive setup instead of autoinstall.
**Diagnosis:** Mounting the ISO on Windows and checking
`Get-Volume` showed `FileSystemLabel` was blank and
`FileSystemType: Unknown` — PowerISO had produced a disc image
Windows itself couldn't properly identify, let alone one correctly
labeled `cidata`.
**Fix:** Rebuilt the seed ISO using `genisoimage` inside WSL
(`genisoimage -output seed.iso -volid cidata -joliet -rock seed/`),
the reference tool most cloud-init documentation is written against.
Verified with `file seed.iso`, which confirmed
`ISO 9660 CD-ROM filesystem data 'cidata'` before trusting it again.

### 8. Autoinstall failed by trying to install Docker during setup
**Problem:** The install got through partitioning and the base OS,
then failed with `install_docker.io ... returned non-zero exit status
100`, dropping into a crash-recovery shell.
**Diagnosis:** The installer environment itself didn't have reliable
internet access at that stage, even though the finished OS would.
**Fix:** Removed the `packages` block from `user-data` entirely and
installed Docker manually over SSH after first boot instead —
simpler, and easier to debug with a real shell and real error output
if it fails again.

### 9. Every HTTPS connection from the VM failed certificate validation
**Problem:** `curl`/`wget` to any HTTPS site — Tailscale, even
google.com — failed with "no alternative certificate subject name
matches target host name."
**Diagnosis:** Checked the actual certificate being returned with
`curl -v`, and it showed `subject: CN=*.eero.com` instead of the
real site's certificate — not a DNS or cert-store issue on the VM at
all. Downloading the file directly revealed the real cause: the
response body was eero's own **"Device Paused"** page. The home
network's eero router was blocking this device's internet access
outright, and every failed request was hitting eero's block page
instead of the real internet.
**Fix:** Unpaused the device in the eero app. This single fix
resolved every "certificate" and "DNS" symptom at once, since they
were never separate problems.

### 10. SSH key-based login initially untested
**Problem:** Early SSH attempts either failed to reach the VM at all
(before the eero block was diagnosed) or fell back to password login,
leaving it unclear whether the SSH key from `user-data` actually
worked.
**Diagnosis:** cloud-init's own boot log had already confirmed the
key was installed correctly (`Authorized keys from
/home/kevin/.ssh/authorized_keys for user kevin`), so once the eero
block was resolved and a real SSH path (via Tailscale) was available,
it was just a matter of testing it directly.
**Fix:** Gave internet access to the vm. `ssh kevin@<tailscale-ip>`
connects straight to a shell with zero password prompt, verifying the
`authorized-keys` field in `user-data` was correctly configured from
the start.