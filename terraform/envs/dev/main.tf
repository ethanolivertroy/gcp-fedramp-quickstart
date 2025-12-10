provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# Local variables for resource naming
locals {
  name_prefix = "fedramp-${var.environment}"
}

module "vpc" {
  source  = "terraform-google-modules/network/google"
  version = "~> 9.0"

  project_id   = var.project_id
  network_name = "${local.name_prefix}-${var.network_name}"
  routing_mode = "GLOBAL"

  subnets = [
    {
      subnet_name   = "${local.name_prefix}-web-subnet"
      subnet_ip     = var.subnet_ip
      subnet_region = var.region
    },
    {
      subnet_name   = "${local.name_prefix}-gke-subnet"
      subnet_ip     = var.gke_subnet_ip
      subnet_region = var.region
    }
  ]

  secondary_ranges = {
    "${local.name_prefix}-gke-subnet" = [
      {
        range_name    = "${local.name_prefix}-pods"
        ip_cidr_range = var.gke_pods_ip
      },
      {
        range_name    = "${local.name_prefix}-services"
        ip_cidr_range = var.gke_services_ip
      }
    ]
  }
}

# Private Service Access (for Cloud SQL)
module "private_service_access" {
  source      = "terraform-google-modules/network/google//modules/private-service-access"
  version     = "~> 9.0"
  project_id  = var.project_id
  network     = module.vpc.network_name
  ip_version  = "IPV4"
  description = "Private Service Access for Cloud SQL"
  depends_on  = [module.vpc]
}

# ---------------------------------------------------------------------------------------------------------------------
# CLOUD SQL (POSTGRESQL)
# ---------------------------------------------------------------------------------------------------------------------

module "sql" {
  source  = "terraform-google-modules/sql-db/google//modules/postgresql"
  version = "~> 18.0"

  name             = "${local.name_prefix}-db"
  database_version = "POSTGRES_15"
  project_id       = var.project_id
  zone             = "${var.region}-a"
  region           = var.region

  # Hardware
  tier = "db-custom-2-7680" # vCPU: 2, RAM: 7.5GB

  # Network
  ip_configuration = {
    ipv4_enabled        = false # Security: Private IP only
    private_network     = module.vpc.network_self_link
    require_ssl         = true
    allocated_ip_range  = module.private_service_access.google_compute_global_address_name
  }

  # Backups
  backup_configuration = {
    enabled                        = true
    start_time                     = "02:00"
    location                       = var.region
    point_in_time_recovery_enabled = true
    transaction_log_retention_days = 7
    retained_backups               = 7
    retention_unit                 = "COUNT"
  }

  # Maintenance
  maintenance_window_day          = 7
  maintenance_window_hour         = 3
  maintenance_window_update_track = "stable"

  # Security & Config
  deletion_protection = false # Set to true for PROD
  database_flags = [
    {
      name  = "log_checkpoints"
      value = "on"
    },
    {
      name  = "log_connections"
      value = "on"
    },
    {
      name  = "log_disconnections"
      value = "on"
    },
    {
      name  = "log_lock_waits"
      value = "on"
    },
    {
      name  = "log_temp_files"
      value = "0"
    },
    {
      name  = "log_min_duration_statement"
      value = "-1"
    }
  ]
  
  db_name      = "fedramp_db"
  user_name    = "app_user"
  # In a real scenario, use Secret Manager for the password
  # For this quickstart dev env, we will generate a random one
}

# ---------------------------------------------------------------------------------------------------------------------
# ARTIFACT REGISTRY
# ---------------------------------------------------------------------------------------------------------------------

resource "google_artifact_registry_repository" "app_repo" {
  provider = google-beta

  location      = var.region
  repository_id = "${local.name_prefix}-repo"
  description   = "Docker repository for FedRAMP application"
  format        = "DOCKER"
  project       = var.project_id

  docker_config {
    immutable_tags = true # Security: Prevent tag overwrites
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# GKE PRIVATE CLUSTER
# ---------------------------------------------------------------------------------------------------------------------

module "gke" {
  source  = "terraform-google-modules/kubernetes-engine/google//modules/private-cluster"
  version = "~> 30.0"

  project_id = var.project_id
  name       = "${local.name_prefix}-cluster"
  region     = var.region
  zones      = ["${var.region}-a", "${var.region}-b", "${var.region}-c"]

  network           = module.vpc.network_name
  subnetwork        = "${local.name_prefix}-gke-subnet"
  ip_range_pods     = "${local.name_prefix}-pods"
  ip_range_services = "${local.name_prefix}-services"

  # Private Cluster Config
  enable_private_nodes    = true
  enable_private_endpoint = false # Allowed in dev; for prod, set to true and use a bastion host
  master_ipv4_cidr_block  = var.gke_master_ipv4_cidr_block

  # Security
  master_authorized_networks = var.gke_master_authorized_networks
  enable_binary_authorization = true # Security: Require trusted images

  # Workload Identity
  # Enables GSA-to-KSA mapping (no more keys!)
  enable_vertical_pod_autoscaling = true
  
  # Observability
  monitoring_service = "monitoring.googleapis.com/kubernetes"
  logging_service    = "logging.googleapis.com/kubernetes"

  # Dataplane V2 (eBPF based networking)
  datapath_provider = "ADVANCED_DATAPATH"

  # Node Pools
  node_pools = [
    {
      name               = "default-node-pool"
      machine_type       = "n2d-standard-2" # Confidential computing ready (AMD EPYC)
      min_count          = 1
      max_count          = 3
      local_ssd_count    = 0
      disk_size_gb       = 100
      disk_type          = "pd-standard"
      image_type         = "COS_CONTAINERD"
      auto_repair        = true
      auto_upgrade       = true
      preemptible        = false
      initial_node_count = 1
    },
  ]

  node_pools_oauth_scopes = {
    all = [
      "https://www.googleapis.com/auth/cloud-platform",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]
  }

  node_pools_labels = {
    all = {
      environment = var.environment
    }
  }

  node_pools_metadata = {
    all = {}
  }

  node_pools_tags = {
    all = [
      "gke-node",
      "${local.name_prefix}-gke"
    ]
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# WORKLOAD IDENTITY FEDERATION (GITHUB ACTIONS)
# ---------------------------------------------------------------------------------------------------------------------

module "github_oidc" {
  source      = "../../modules/github-oidc"
  project_id  = var.project_id
  github_repo = var.github_repo
}

output "wif_provider_name" {
  description = "Workload Identity Provider Name (For GitHub Actions secret)"
  value       = module.github_oidc.provider_name
}

output "wif_service_account" {
  description = "Service Account Email (For GitHub Actions secret)"
  value       = module.github_oidc.service_account_email
}
