# network.tf
resource "google_compute_network" "vpc_network" {
  name = "my-vpc-network"
}

resource "google_compute_subnetwork" "subnetwork" {
  name          = "test-subnetwork"
  network       = google_compute_network.vpc_network.id
  ip_cidr_range = "10.0.0.0/16"
  region        = var.region
}

resource "google_compute_firewall" "allow-internal" {
  name    = "allow-internal"
  network = google_compute_network.vpc_network.id

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  source_ranges = ["10.0.0.0/16"]
}
resource "google_compute_firewall" "allow-ssh" {
  name    = "allow-ssh"
  network = google_compute_network.vpc_network.id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

    # Allow SSH access only from the specified IP range
  source_ranges = ["35.235.240.0/20", "${var.public_ip}/32"]
}
