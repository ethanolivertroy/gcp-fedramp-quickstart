variable "project_id" {
  description = "The Google Cloud Project ID"
  type        = string
}

variable "region" {
  description = "The Google Cloud region"
  type        = string
  default     = "us-central1"
}

variable "environment" {
  description = "The environment name (e.g. dev, prod)"
  type        = string
  default     = "dev"
}

variable "network_name" {
  description = "The name of the VPC network"
  type        = string
  default     = "fedramp-vpc"
}

variable "subnet_ip" {
  description = "The IP range for the primary subnet"
  type        = string
  default     = "10.0.0.0/24"
}

variable "gke_subnet_ip" {
  description = "The IP range for the GKE subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "gke_pods_ip" {
  description = "The secondary IP range for GKE Pods"
  type        = string
  default     = "10.1.0.0/16"
}


variable "gke_services_ip" {
  description = "The secondary IP range for GKE Services"
  type        = string
  default     = "10.2.0.0/16"
}

variable "gke_master_ipv4_cidr_block" {
  description = "The IP range for the GKE control plane"
  type        = string
  default     = "172.16.0.0/28"
}

variable "gke_master_authorized_networks" {
  description = "List of master authorized networks"
  type        = list(object({ cidr_block = string, display_name = string }))
  default     = [{ cidr_block = "0.0.0.0/0", display_name = "Anyone (Change me in prod!)" }]
}

variable "github_repo" {
  description = "The GitHub repository to trust (format: org/repo)"
  type        = string
  default     = "googlecloudplatform/gcp-fedramp-quickstart"
}
