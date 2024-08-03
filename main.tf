#main.tf

resource "google_compute_instance" "ubuntu_server" {
  name         = "ubuntu-microk8s-server"
  machine_type = "e2-medium"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2004-lts"
    }
  }

  network_interface {
    network    = google_compute_network.vpc_network.id
    subnetwork = google_compute_subnetwork.subnetwork.id
    access_config {}
  }

  metadata = {
    ssh-keys = "ubuntu:${file("/Users/${var.username}/.ssh/id_rsa.pub")}"
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    sudo apt update -y
    sudo apt upgrade -y
    sudo snap install microk8s --classic
    sudo usermod -a -G microk8s $USER
    sudo chown -f -R $USER ~/.kube
  EOF

  tags = ["http-server"]

  provisioner "file" {
    source      = "setup_crowdstrike.sh"
    destination = "/home/ubuntu/setup_crowdstrike.sh"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file("/Users/${var.username}/.ssh/id_rsa")
      host        = self.network_interface[0].access_config[0].nat_ip
    }
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /home/ubuntu/setup_crowdstrike.sh",
      "sudo /home/ubuntu/setup_crowdstrike.sh"
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file("/Users/${var.username}/.ssh/id_rsa")
      host        = self.network_interface[0].access_config[0].nat_ip
    }
  }
}

resource "google_compute_instance" "kali_attacker" {
  name         = "kali-desktop-linux-vm"
  machine_type = "e2-medium"  # Customize the machine type as needed
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = var.kali_image
      size  = 81  # Default to 60 GB
      type  = "pd-standard"  # Default to "Standard Persistent Disk"
    }
  }

  network_interface {
    network    = google_compute_network.vpc_network.id
    subnetwork = google_compute_subnetwork.subnetwork.id
    access_config {}
  }

  service_account {
    email  = var.service_account_email
    scopes = ["cloud-platform"]
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    sudo apt update -y
    sudo apt upgrade -y
    sudo apt install -y openssh-server
    sudo systemctl enable ssh
    sudo systemctl start ssh
  EOF

  tags = ["http-server", "rdp-server"]

  metadata = {
    ssh-keys = "ubuntu:${file("/Users/${var.username}/.ssh/id_rsa.pub")}"
  }
}

output "ubuntu_server_ip" {
  value = google_compute_instance.ubuntu_server.network_interface[0].access_config[0].nat_ip
}

output "kali_attacker_ip" {
  value = google_compute_instance.kali_attacker.network_interface[0].access_config[0].nat_ip
}

