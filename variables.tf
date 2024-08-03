variable "falcon_client_id" {
  description = "The Falcon client ID"
  type        = string
  sensitive   = true
}

variable "falcon_client_secret" {
  description = "The Falcon client secret"
  type        = string
  sensitive   = true
}

variable "kali_image" {
  description = "The Kali Linux image from the marketplace"
  type        = string
  default     = "projects/techlatest-public/global/images/kali-linux"
}

variable "service_account_email" {
  description = "The service account email"
  type        = string
}

variable "project" {
  description = "The GCP project ID"
  type        = string
}

variable "region" {
  description = "The GCP region"
  type        = string
}

variable "zone" {
  description = "The GCP zone"
  type        = string
}

variable "public_ip" {
  description = "The public IP address"
  type        = string
}

variable "username" {
  description = "The local username for SSH keys"
  type        = string
}

