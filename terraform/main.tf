terraform {
  required_providers {
    hyperv = {
      source  = "taliesins/hyperv"
      version = "~> 1.2"
    }
  }
}
provider "hyperv" {
  user     = var.hyperv_user
  password = var.hyperv_password
  host     = "100.101.167.18"
  port     = 5985
  https    = false
  insecure = true
  use_ntlm = true
}
resource "hyperv_vhd" "ubuntu_vm_disk" {
  path = "C:\\VMs\\ubuntu-node1\\disk.vhdx"
  size = 21474836480
}

resource "hyperv_machine_instance" "ubuntu_node1" {
  name                   = "ubuntu-node1"
  generation             = 2
  processor_count        = 1
  static_memory          = true
  memory_startup_bytes   = 2147483648
  automatic_start_action = "Start"

  vm_firmware {
    enable_secure_boot   = "On"
    secure_boot_template = "MicrosoftUEFICertificateAuthority"
  }

  network_adaptors {
    name        = "nic1"
    switch_name = "WTS-External"
  }

  hard_disk_drives {
    controller_type      = "Scsi"
    controller_number    = 0
    controller_location  = 0
    path                 = hyperv_vhd.ubuntu_vm_disk.path
  }

}
resource "hyperv_vhd" "k3s_worker1_disk" {
  path = "C:\\VMs\\k3s-worker1\\disk.vhdx"
  size = 21474836480
}

resource "hyperv_machine_instance" "k3s_worker1" {
  name                   = "k3s-worker1"
  generation             = 2
  processor_count        = 2
  static_memory          = true
  memory_startup_bytes   = 2147483648
  automatic_start_action = "Start"

  network_adaptors {
    name        = "nic1"
    switch_name = "WTS-External"
  }

  hard_disk_drives {
    controller_type      = "Scsi"
    controller_number    = 0
    controller_location  = 0
    path                 = hyperv_vhd.k3s_worker1_disk.path
  }

  vm_firmware {
    enable_secure_boot   = "On"
    secure_boot_template = "MicrosoftUEFICertificateAuthority"
  }
}

resource "hyperv_vhd" "k3s_worker2_disk" {
  path = "C:\\VMs\\k3s-worker2\\disk.vhdx"
  size = 21474836480
}

resource "hyperv_machine_instance" "k3s_worker2" {
  name                   = "k3s-worker2"
  generation             = 2
  processor_count        = 2
  static_memory          = true
  memory_startup_bytes   = 2147483648
  automatic_start_action = "Start"

  network_adaptors {
    name        = "nic1"
    switch_name = "WTS-External"
  }

  hard_disk_drives {
    controller_type      = "Scsi"
    controller_number    = 0
    controller_location  = 0
    path                 = hyperv_vhd.k3s_worker2_disk.path
  }

  vm_firmware {
    enable_secure_boot   = "On"
    secure_boot_template = "MicrosoftUEFICertificateAuthority"
  }
}
