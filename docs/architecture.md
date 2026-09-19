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
### 11. Ansible: sudo password required for privilege escalation
**Problem:** First playbook run failed immediately with "Missing sudo
password," even though SSH itself connected fine.
**Diagnosis:** SSH login uses key-based auth (no password needed),
but `become: true` tasks still need to elevate to root via `sudo` on
the target machine, which requires a password unless passwordless
sudo is explicitly configured.
**Fix:** Ran with `-K` (`--ask-become-pass`) to prompt for the sudo
password interactively. Confirmed the distinction between `-k`
(SSH password) and `-K` (become/sudo password) — easy to mix up
since they look nearly identical.

### 12. Verified idempotency
Re-ran the same playbook immediately after the first successful run,
with no changes made in between. First run: `changed=6`. Second run:
`changed=1` (only the apt cache refresh, which always reports as
changed). This confirms the playbook is declarative — it checks the
system's actual state and only acts on real drift, rather than
blindly re-running commands every time.

### 15. k3s control plane hit swap/TLS timeouts under memory pressure
**Problem:** After installing k3s server on ubuntu-node1 and joining
both workers, `kubectl get nodes` consistently failed with
"TLS handshake timeout," and `systemctl status k3s` showed the
service stuck in "activating" for 12+ minutes.
**Diagnosis:** `systemctl status k3s` showed real numbers, not
guesswork: `swap: 486.1M`, confirming the VM was swapping heavily.
ubuntu-node1's 1GB RAM was already fully committed to the existing
observability stack (5 containers), leaving no real headroom for
k3s's own memory floor (etcd is particularly memory-hungry).
**Fix:** Bumped ubuntu-node1's Terraform-managed memory allocation
from 1GB to 2GB (`memory_startup_bytes`), applied via
`terraform apply` after a manual `Stop-VM -TurnOff -Force` to clear
a stuck VM state (same recurring Hyper-V/Terraform quirk as before).
k3s came up healthy immediately after the restart.
**Result:** `kubectl get nodes` shows all three nodes `Ready`:
ubuntu-node1 (control-plane), k3s-worker1, k3s-worker2.
### 16. ArgoCD pods stuck on missing secret, traced to a firewall blocking the cluster overlay network
**Problem:** After installing ArgoCD, several pods failed with
`CreateContainerConfigError: secret "argocd-redis" not found`, and
`argocd-redis` itself was stuck in `CrashLoopBackOff`. `kubectl logs`
against the failing init container returned a `502 Bad Gateway`,
hiding the real error.
**Diagnosis:** Bypassed the broken kubectl-to-kubelet proxy entirely
using `crictl logs` directly on the node running the pod
(`k3s-worker2`), which revealed the actual failure:
`dial tcp 10.43.0.1:443: i/o timeout` — the pod couldn't reach the
cluster's internal API service address at all. This pointed to the
Flannel/VXLAN overlay network (which lets pods reach cluster-internal
services across nodes) being blocked somewhere in the path.
Confirmed with `ufw status` on each node: `ubuntu-node1` — the one
node hardened by the Ansible playbook from Project 1.1 — had UFW
active, allowing only SSH, silently dropping all k3s cluster traffic
(API server 6443/tcp, VXLAN 8472/udp, kubelet 10250/tcp) between
itself and the workers.
**Fix:** Opened the required ports (`6443/tcp`, `8472/udp`,
`10250/tcp`, plus a broader allow-rule for the home LAN subnet) via
`ufw allow`. All ArgoCD pods recovered automatically within minutes
— the crashed init container simply retried successfully once the
network path was open.
**Follow-up:** These UFW rules were added live on the VM but still
need to be added to the Ansible `playbook.yml` itself, so a future
`ansible-playbook` run or VM rebuild doesn't silently reintroduce
this exact bug.
**Lesson:** A firewall configured correctly for one purpose
(hardening a standalone web server) can silently break an entirely
different, later-added workload (a Kubernetes cluster) on the same
machine — worth re-auditing firewall rules any time a node takes on
a new role.