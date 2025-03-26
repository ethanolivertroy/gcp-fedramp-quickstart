# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http:#www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

data = {
  parent_type     = "{{.parent_type}}"
  parent_id       = "{{.parent_id}}"
  billing_account = "{{.billing_account}}"
  state_bucket    = "{{.terraform_state_storage_bucket}}"
  
  # Default locations for resources. Can be overridden in individual templates.
  bigquery_location   = "{{.logging_project_region}}"
  storage_location    = "{{.logging_project_region}}"
  compute_region = "{{.logging_project_region}}"
  compute_zone = "a"
  labels = {
    env = "prod"
  }
}

template "logging" {
  recipe_path = "git://github.com/GoogleCloudPlatform/healthcare-data-protection-suite//templates/tfengine/recipes/project.hcl"
  output_path = "./logging/workload"
  data = {
    project = {
      project_id = "{{.logging_project_id}}"
      exists     = true
      apis = [
			"monitoring.googleapis.com",
            "logging.googleapis.com",
            "cloudkms.googleapis.com",
            "securitycenter.googleapis.com"
      ]
    }
    terraform_addons = {
      raw_config = <<EOF
        
        provider "google" {
            project     = "{{.logging_project_id}}"
            region      = "{{.logging_project_region}}"
        }
        
        provider "google-beta" {
            project     = "{{.logging_project_id}}"
            region      = "{{.logging_project_region}}"
        }

        data "google_project" "project_number" {
			project_id  = module.project.project_id
		}

        # Create a KMS key ring for CMEK encryption
        resource "google_kms_key_ring" "logging_keyring" {
          name     = "logging-keyring"
          location = "{{.logging_project_region}}"
        }

        # Create a KMS key for encrypting logging data
        resource "google_kms_crypto_key" "logging_key" {
          name            = "logging-key"
          key_ring        = google_kms_key_ring.logging_keyring.id
          rotation_period = "7776000s" # 90 days
          
          version_template {
            algorithm = "GOOGLE_SYMMETRIC_ENCRYPTION"
            protection_level = "SOFTWARE"
          }
        }

        # Enable Security Command Center
        resource "google_project_service" "scc" {
          project = module.project.project_id
          service = "securitycenter.googleapis.com"
          
          disable_dependent_services = false
          disable_on_destroy = false
        }

#Code Block 3.2.2.c
        resource "google_project_iam_audit_config" "project" {
            project = module.project.project_id
            service = "allServices"
            audit_log_config {
                log_type = "DATA_READ"
            }
            audit_log_config {
                log_type = "DATA_WRITE"
            }
            audit_log_config {
                log_type = "ADMIN_READ"
            }
        }

        resource "google_bigquery_table" "logs_table" {
            dataset_id = "${module.log_analysis_dataset.bigquery_dataset.dataset_id}"
            table_id = "{{.logs_storage_bigquery_table_name}}"
            project = module.project.project_id
            labels = {
                data_type = "{{.logs_streaming_pubsub_topic_datatype_label}}"
                data_criticality = "{{.logs_streaming_pubsub_topic_data_criticality_label}}"
            }
            
            # Schema for FedRAMP compliance logs
            schema = <<EOF
[
  {
    "name": "timestamp",
    "type": "TIMESTAMP",
    "mode": "REQUIRED",
    "description": "Time the log entry was received"
  },
  {
    "name": "resource_type",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "GCP resource type"
  },
  {
    "name": "resource_name",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "GCP resource name"
  },
  {
    "name": "severity",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "Log severity (e.g., INFO, WARNING, ERROR)"
  },
  {
    "name": "log_id",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "Unique identifier for the log"
  },
  {
    "name": "principal_email",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "Identity performing the operation"
  },
  {
    "name": "method_name",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "Method or operation being performed"
  },
  {
    "name": "status_code",
    "type": "INTEGER",
    "mode": "NULLABLE",
    "description": "HTTP or RPC status code"
  },
  {
    "name": "payload",
    "type": "JSON",
    "mode": "NULLABLE",
    "description": "Full log payload"
  }
]
EOF
            
            # Time partitioning and CMEK encryption
            time_partitioning {
              type = "DAY"
              field = "timestamp"
              expiration_ms = 7776000000  # 90 days
            }
            
            # Comment out if you don't have CMEK setup yet
            # encryption_configuration {
            #   kms_key_name = google_kms_crypto_key.logging_key.id
            # }
        }
        
        resource "google_dataflow_job" "psto_bq_job" {
            name  = "{{.data_flow_job_name}}"
            max_workers = {{.data_flow_job_max_workers}}
            on_delete = "cancel"
            project = module.project.project_id
            network               = "{{.dataflow_network_name}}"
            subnetwork            = "regions/{{.logging_project_region}}/subnetworks/{{.dataflow_subnet_name}}"
            ip_configuration      = "WORKER_IP_PRIVATE"
            region                = "{{.logging_project_region}}"
            depends_on = [google_project_iam_binding.data_flow_service_account_access_worker ]
            template_gcs_path = "gs://dataflow-templates-{{.logging_project_region}}/latest/PubSub_Subscription_to_BigQuery"
            temp_gcs_location = "${module.dataflow_temp_storage_bucket.bucket.url}"
            service_account_email = "${google_service_account.data_flow_job_service_account.email}"
#Code Block 3.2.7.b            
            labels = {
                data_type = "{{.logs_streaming_pubsub_topic_datatype_label}}"
                data_criticality = "{{.logs_streaming_pubsub_topic_data_criticality_label}}"
            }
            parameters = {
                inputSubscription = module.logging_pubsub_topic.subscription_paths[0]
                outputTableSpec = "${google_bigquery_table.logs_table.project}:${google_bigquery_table.logs_table.dataset_id}.${google_bigquery_table.logs_table.table_id}"
            }
            
            # Set additional Dataflow job options for security
            additional_experiments = [
              "use_runner_v2",
              "no_use_multiple_sdk_containers"
            ]
        }
#Code Block 3.2.5.a
        resource "google_project_iam_binding" "pub_sub_access" {
            project = module.project.project_id
            role    = "roles/pubsub.editor"

            members = [
                "group:{{.cloud_users_group}}",
            ]
        }

#Code Block 3.2.7.a
        resource "google_project_iam_binding" "data_flow_access" {
            project = module.project.project_id
            role    = "roles/dataflow.developer"

            members = [
                "group:{{.cloud_users_group}}",
            ]
        }
        #Access given to dataflow service account to write data to bigquery
        resource "google_bigquery_dataset_access" "data_flow_service_account_access_bigquery" {
            dataset_id    = "${module.log_analysis_dataset.bigquery_dataset.dataset_id}"
            role          = "roles/bigquery.dataEditor"
            user_by_email = google_service_account.data_flow_job_service_account.email
        }
        # Access given to dataflow service account to write to temp storage bucket
        resource "google_storage_bucket_iam_binding" "data_flow_service_account_access_bucket" {
            bucket = "${module.dataflow_temp_storage_bucket.bucket.name}"
            role = "roles/storage.objectCreator"
            members = [
                "serviceAccount:${google_service_account.data_flow_job_service_account.email}",
            ]
        }
        # This access is necessary for a Compute Engine service account to execute work units for an Apache Beam pipeline
        resource "google_project_iam_binding" "data_flow_service_account_access_worker" {
            project = module.project.project_id
            role    = "roles/dataflow.worker"

            members = [
                "serviceAccount:${google_service_account.data_flow_job_service_account.email}",
            ]
        }
        # PubSub subscriber access to dataflow service service account used by worker VMs to pull and acknowledge the messages
        # PubSub subscriber access to dataflow service agent to pull and acknowledge the messages
        resource "google_pubsub_topic_iam_binding" "data_flow_service_account_access_subscriber" {
            project = module.project.project_id
            topic = module.logging_pubsub_topic.topic
            role = "roles/pubsub.subscriber"
            members = [
                "serviceAccount:${google_service_account.data_flow_job_service_account.email}",
                "serviceAccount:service-${data.google_project.project_number.number}@dataflow-service-producer-prod.iam.gserviceaccount.com",
            ]
        }
        
        # Create log-based metric for security monitoring
        resource "google_logging_metric" "security_incident_metric" {
          name = "security_incidents"
          filter = "severity>=ERROR AND (jsonPayload.securityRelevant=true OR textPayload:\"security\" OR textPayload:\"unauthorized\")"
          description = "Count of potential security incidents based on log severity and content"
          metric_descriptor {
            metric_kind = "DELTA"
            value_type = "INT64"
            labels {
              key = "resource_type"
              value_type = "STRING"
              description = "The GCP resource type"
            }
            labels {
              key = "severity"
              value_type = "STRING"
              description = "The severity of the log entry"
            }
          }
          label_extractors = {
            "resource_type" = "EXTRACT(resource.type)"
            "severity" = "EXTRACT(severity)"
          }
        }
        
        # Create alert policy based on security metric
        resource "google_monitoring_alert_policy" "security_alert" {
          display_name = "Security Incident Alert"
          combiner = "OR"
          conditions {
            display_name = "Security incidents detected"
            condition_threshold {
              filter = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.security_incident_metric.name}\" AND resource.type=\"global\""
              duration = "60s"
              comparison = "COMPARISON_GT"
              threshold_value = 0
              aggregations {
                alignment_period = "300s"
                per_series_aligner = "ALIGN_SUM"
                cross_series_reducer = "REDUCE_SUM"
              }
              trigger {
                count = 1
              }
            }
          }
          notification_channels = []  # Add notification channels here when created
          documentation {
            content = "Security incident detected based on log analysis. Please investigate immediately."
            mime_type = "text/markdown"
          }
          alert_strategy {
            auto_close = "604800s"  # Auto-close after 7 days
          }
        }
                 
    
    EOF
    }
    resources = {
        service_accounts = [
            {
            account_id   = "data-flow-job-service-account"
            resource_name = "data_flow_job_service_account"
            description  = "Service Account for Dataflow jobs processing logs"
            display_name = "Dataflow Log Processing Service Account"
            } 
        ]
        pubsub_topics = [{
          name = "{{.logs_streaming_pubsub_topic_name}}"
#Code Block 3.2.5.b
          labels = {
              data_type = "{{.logs_streaming_pubsub_topic_datatype_label}}"
              data_criticality = "{{.logs_streaming_pubsub_topic_data_criticality_label}}"
          }
          # Enable message retention for compliance
          message_retention_duration = "604800s"  # 7 days
          # Enable ordering for critical messages if needed
          message_storage_policy = {
            allowed_persistence_regions = [
              "{{.logging_project_region}}"
            ]
          }
          pull_subscriptions = [
              {
                  name = "{{.logs_streaming_pubsub_subscription_name}}"
                  ack_deadline_seconds = {{.logs_streaming_pubsub_subscription_acknowledgmenet_seconds}}
                  # Enable message retention
                  retain_acked_messages = true
                  # Set a 7-day retention for acknowledged messages
                  message_retention_duration = "604800s"
                  # Enable dead-letter topic if needed
                  # dead_letter_policy = {
                  #     dead_letter_topic = google_pubsub_topic.dead_letter.id
                  #     max_delivery_attempts = 5
                  # }
                  # Add additional subscription config as needed
                  expiration_policy = {
                      ttl = ""  # Never expire
                  }
              }
          ]
        }]
        storage_buckets = [{
            name = "{{.dataflow_temp_storage_bucket_name}}"
            resource_name = "dataflow_temp_storage_bucket"
            labels = {
                data_type = "{{.dataflow_temp_storage_bucket_datatype_label}}"
                data_criticality = "{{.dataflow_temp_storage_bucket_data_criticality_label}}"
            }
            # Set lifecycle rules for efficient storage management
            lifecycle_rules = [{
                action = {
                    type = "Delete"
                }
                condition = {
                    age = 30  # Delete temp files after 30 days
                }
            }]
            # Enable versioning and uniform bucket-level access
            versioning = {
              enabled = true
            }
            uniform_bucket_level_access = true
            # Optional CMEK encryption - uncomment when ready
            # encryption = {
            #     default_kms_key_name = google_kms_crypto_key.logging_key.id
            # }
            iam_members = [
              {
                role   = "roles/storage.objectViewer"
                member = "group:{{.cloud_users_group}}"
              }
            ]
        }]
        bigquery_datasets = [{
            # Override Terraform resource name as it cannot start with a number.
            resource_name               = "log_analysis_dataset"
            dataset_id                  = "{{.logs_storage_bigquery_dataset_name}}"
#Code Block 3.2.2.d        
            # Retains log records for 13 months to meet FedRAMP requirements
            default_table_expiration_ms = 34214400000  # 13 months
            # Add location constraint
            location = "{{.logging_project_region}}"
#Code Block 3.2.2.b 
            labels = {
                data_type = "{{.logs_streaming_pubsub_topic_datatype_label}}"
                data_criticality = "{{.logs_streaming_pubsub_topic_data_criticality_label}}"
            }
            # Enable CMEK encryption - uncomment when ready
            # encryption_configuration = {
            #    kms_key_name = google_kms_crypto_key.logging_key.id
            # }
#Code Block 3.2.2.a
            access = [
            {
                role          = "roles/bigquery.dataOwner"
                special_group = "projectOwners"
            },
            {
                role           = "roles/bigquery.dataViewer"
                group_by_email = "{{.cloud_users_group}}"
            }
            ]
        }]
    
    }
   

  }
}