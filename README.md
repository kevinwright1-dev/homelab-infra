# Homelab Infrastructure (Terraform + Hyper-V)

Version-controlled home lab infrastructure: a Hyper-V host provisioned
and configured entirely from code, rather than manual VM creation
through Hyper-V Manager.

## What this does

Running `terraform apply` creates the VM, `cloud-init` installs Ubuntu
unattended, `Ansible` configures it (Docker, firewall, SSH hardening),
and everything is reachable via Tailscale — no manual clicking, no
manual OS install steps, no public ports exposed.

## Stack

- **Terraform** (`taliesins/hyperv` provider) — VM/disk provisioning
- **cloud-init (autoinstall)** — unattended Ubuntu Server install
- **Tailscale** — private, encrypted access to the host and VMs
  (no ports exposed to the public internet)
- **Docker** — container runtime on the provisioned VM

## Why this exists

Most student infrastructure projects are built by hand and forgotten.
This one is meant to be destroyed and rebuilt on demand — proof that
the environment is reproducible from a Git repo, not tribal knowledge
sitting in someone's head.

## Quick start

**1. Provision the VM (Terraform)**
```bash
git clone https://github.com/kevinwright1-dev/homelab-infra.git
cd homelab-infra/terraform
terraform init
terraform plan
terraform apply
```
Requires a `terraform.tfvars` file (not committed) with
`hyperv_user` and `hyperv_password` for an account with Hyper-V
administrator rights on the target host.

**2. Boot and OS install**
The VM boots from an attached Ubuntu Server ISO plus a `cidata` seed
ISO built from `packer/seed/` (cloud-init `user-data`/`meta-data`),
producing a fully unattended install — hostname, user, SSH key, and
network config are all set with zero manual input. See
`docs/architecture.md` for how the seed ISO is built and attached.

**3. Configure the VM (Ansible)**
```bash
cd ../ansible
ansible-playbook -i inventory.ini playbook.yml -K
```
Installs Docker, `fail2ban`, and `ufw`; enforces SSH key-only auth;
and enables the firewall. Idempotent — safe to re-run any time, and
only applies real changes (verified: a clean re-run after initial
setup showed `changed=1` vs. the original `changed=6`).

**4. Access**
The VM and host are reachable over Tailscale, not the public
internet — no ports are forwarded through the home router for
management access.


## What I'd do differently at scale

- Fix the DVD-drive lifecycle bug in the Hyper-V provider properly
  (currently managed manually outside Terraform — documented in
  `docs/architecture.md`)
- Extend the Ansible setup from one node to a real inventory of
  multiple machines, using groups and roles instead of a single
  flat playbook
- Replace the lab-only unencrypted WinRM listener with a proper
  HTTPS/certificate-based setup

## Full build log

See [`docs/architecture.md`](docs/architecture.md) for the complete
network design and a real debugging log — including chasing down what
looked like a certificate/DNS problem that turned out to be a home
router silently pausing the VM's internet access.