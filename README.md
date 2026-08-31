# Homelab Infrastructure (Terraform + Hyper-V)

Version-controlled home lab infrastructure: a Hyper-V host provisioned
and configured entirely from code, rather than manual VM creation
through Hyper-V Manager.

## What this does

Running `terraform apply` from my own PC creates a fully configured
Ubuntu Server VM on a separate physical Hyper-V host — disk, VM shell,
network, firmware settings, and an unattended OS install via
cloud-init, with SSH key-based access and Docker installed. No manual
clicking, no manual OS install steps.

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

## What I'd do differently at scale

- Fix the DVD-drive lifecycle bug in the Hyper-V provider properly
  (currently managed manually outside Terraform — documented in
  `docs/architecture.md`)
- Move from a single VM to Ansible-managed configuration for multiple
  nodes
- Replace the lab-only unencrypted WinRM listener with a proper
  HTTPS/certificate-based setup

## Full build log

See [`docs/architecture.md`](docs/architecture.md) for the complete
network design and a real debugging log — including chasing down what
looked like a certificate/DNS problem that turned out to be a home
router silently pausing the VM's internet access.