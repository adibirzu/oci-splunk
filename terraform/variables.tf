variable "compartment_ocid" {
  description = "Compartment OCID where resources are created."
  type        = string
}

variable "region" {
  description = "OCI region (for example us-ashburn-1)."
  type        = string
}

variable "project_prefix" {
  description = "Name prefix for created resources."
  type        = string
  default     = "oci-splunk"
}

variable "auth" {
  description = "OCI provider auth method: APIKey, SecurityToken, InstancePrincipal, ResourcePrincipal. ApiKey is accepted as a backward-compatible alias."
  type        = string
  default     = "APIKey"

  validation {
    condition     = contains(["APIKey", "ApiKey", "SecurityToken", "InstancePrincipal", "ResourcePrincipal"], var.auth)
    error_message = "auth must be one of: APIKey, ApiKey, SecurityToken, InstancePrincipal, ResourcePrincipal."
  }
}

variable "oci_profile" {
  description = "OCI CLI profile name used for local deployments."
  type        = string
  default     = "DEFAULT"
}

variable "oci_config_file" {
  description = "Path to OCI config file used for local deployments."
  type        = string
  default     = "~/.oci/config"
}

variable "tenancy_ocid" {
  description = "Optional explicit tenancy OCID for provider auth."
  type        = string
  default     = ""
}

variable "user_ocid" {
  description = "Optional explicit user OCID for provider auth."
  type        = string
  default     = ""
}

variable "fingerprint" {
  description = "Optional explicit API key fingerprint for provider auth."
  type        = string
  default     = ""
}

variable "private_key_path" {
  description = "Optional explicit path to API private key for provider auth."
  type        = string
  default     = ""
}

variable "ssh_public_key" {
  description = "SSH public key content for Splunk VM access."
  type        = string
  default     = ""
}

variable "availability_domain" {
  description = "Optional availability domain name. Leave empty to use first AD."
  type        = string
  default     = ""
}

variable "use_existing_network" {
  description = "If true, use existing VCN/subnet; otherwise create network resources."
  type        = bool
  default     = false
}

variable "existing_vcn_id" {
  description = "Existing VCN OCID when use_existing_network=true."
  type        = string
  default     = ""
}

variable "existing_subnet_id" {
  description = "Existing subnet OCID for Splunk VM when use_existing_network=true."
  type        = string
  default     = ""
}

variable "existing_nsg_id" {
  description = "Optional existing NSG OCID to attach to Splunk VM."
  type        = string
  default     = ""
}

variable "vcn_cidr" {
  description = "VCN CIDR when creating network."
  type        = string
  default     = "10.60.0.0/16"
}

variable "splunk_subnet_cidr" {
  description = "Splunk subnet CIDR when creating network."
  type        = string
  default     = "10.60.1.0/24"
}

variable "lb_subnet_cidr" {
  description = "Load balancer subnet CIDR when creating network and private Splunk subnet is enabled."
  type        = string
  default     = "10.60.2.0/24"
}

variable "create_private_splunk_subnet" {
  description = "When creating network, create a private subnet for Splunk VM (no public IP)."
  type        = bool
  default     = false
}

variable "enable_load_balancer_for_private" {
  description = "When Splunk subnet is private, create/use LB so Splunk ports remain reachable."
  type        = bool
  default     = true
}

variable "enable_load_balancer_for_public" {
  description = "If Splunk subnet is public, optionally still expose via LB."
  type        = bool
  default     = false
}

variable "existing_load_balancer_id" {
  description = "Optional existing LB OCID to reuse."
  type        = string
  default     = ""
}

variable "existing_load_balancer_public_ip" {
  description = "Public IP of existing LB when existing_load_balancer_id is set."
  type        = string
  default     = ""
}

variable "existing_lb_subnet_id" {
  description = "LB subnet OCID when creating a new LB in existing network mode."
  type        = string
  default     = ""
}

variable "allowed_ingress_cidr" {
  description = "CIDR allowed to access Splunk ports and SSH (set to your current public IP/32)."
  type        = string
  default     = ""
}

variable "splunk_shape" {
  description = "Compute shape for Splunk VM."
  type        = string
  default     = "VM.Standard.E4.Flex"
}

variable "splunk_ocpus" {
  description = "Number of OCPUs for Splunk VM shape config."
  type        = number
  default     = 2
}

variable "splunk_memory_gb" {
  description = "Memory in GB for Splunk VM shape config."
  type        = number
  default     = 16
}

variable "splunk_boot_volume_gb" {
  description = "Boot volume size (GB)."
  type        = number
  default     = 100
}

variable "splunk_image_ocid" {
  description = "Optional custom image OCID. If empty, latest Oracle Linux 8 image is used."
  type        = string
  default     = ""
}

variable "splunk_admin_password" {
  description = "Initial admin password configured after Splunk install."
  type        = string
  sensitive   = true
  default     = ""
}

variable "use_existing_splunk" {
  description = "If true, do not create a Splunk VM and forward logs to an existing Splunk HEC endpoint."
  type        = bool
  default     = false
}

variable "existing_splunk_web_url" {
  description = "Optional existing Splunk Web URL for output/reporting when use_existing_splunk=true."
  type        = string
  default     = ""
}

variable "stream_pool_name" {
  description = "Streaming pool name."
  type        = string
  default     = "oci-splunk-pool"
}

variable "stream_name" {
  description = "Streaming stream name."
  type        = string
  default     = "oci-splunk-stream"
}

variable "stream_partitions" {
  description = "Number of stream partitions."
  type        = number
  default     = 1
}

variable "stream_retention_hours" {
  description = "Stream retention in hours."
  type        = number
  default     = 24
}

variable "existing_stream_pool_id" {
  description = "Optional existing stream pool OCID to reuse."
  type        = string
  default     = ""
}

variable "existing_stream_id" {
  description = "Optional existing stream OCID to reuse."
  type        = string
  default     = ""
}

variable "log_group_ocid" {
  description = "OCI Logging log group OCID for service connector source."
  type        = string
}

variable "log_ocid" {
  description = "OCI Logging log OCID for service connector source."
  type        = string
}

variable "create_logs_to_stream_connector" {
  description = "Create Service Connector from a specific Logging log to Streaming (requires log_group_ocid/log_ocid)."
  type        = bool
  default     = true
}

variable "create_audit_stream_connector" {
  description = "On first deploy, create a Service Connector that ships OCI Audit logs (_Audit) to the stream so logs flow out of the box."
  type        = bool
  default     = true
}

variable "audit_log_compartment_ocid" {
  description = "Compartment whose Audit logs are shipped. Empty = the deployment compartment (compartment_ocid)."
  type        = string
  default     = ""
}

variable "manage_service_connector_policy" {
  description = "Create the IAM policy granting the Service Connector principal stream-push + read log-content (needed for the Audit connector to move data)."
  type        = bool
  default     = true
}

variable "stream_consumer_model" {
  description = "Streaming consumer runtime: legacy Kafka Connect or SOC4Kafka/Splunk OTel Collector."
  type        = string
  default     = "legacy_kafka_connect"

  validation {
    condition     = contains(["legacy_kafka_connect", "soc4kafka"], var.stream_consumer_model)
    error_message = "stream_consumer_model must be one of: legacy_kafka_connect, soc4kafka."
  }
}

variable "service_connector_stream_name" {
  description = "Display name for Logs->Stream Service Connector."
  type        = string
  default     = "oci-splunk-logs-to-stream"
}

variable "enable_functions_path" {
  description = "Enable optional Logs->Functions->Splunk path."
  type        = bool
  default     = false
}

variable "existing_function_app_id" {
  description = "Optional existing Functions application OCID."
  type        = string
  default     = ""
}

variable "existing_function_id" {
  description = "Optional existing Function OCID for Logs->Functions connector."
  type        = string
  default     = ""
}

variable "function_subnet_ids" {
  description = "Subnet IDs for Functions application. If empty, uses Splunk subnet when possible."
  type        = list(string)
  default     = []
}

variable "function_app_name" {
  description = "Functions application name."
  type        = string
  default     = "oci-splunk-fn-app"
}

variable "function_name" {
  description = "Function display name when creating function resource."
  type        = string
  default     = "splunk-hec-forwarder"
}

variable "function_image" {
  description = "OCIR image for function. Required only when creating function resource."
  type        = string
  default     = ""
}

variable "create_logs_to_functions_connector" {
  description = "Create Service Connector from Logging to Function."
  type        = bool
  default     = false
}

variable "service_connector_functions_name" {
  description = "Display name for Logs->Functions Service Connector."
  type        = string
  default     = "oci-splunk-logs-to-functions"
}

variable "generate_local_kafka_artifacts" {
  description = "Generate Kafka Connect config files locally when running Terraform from your machine."
  type        = bool
  default     = true
}

variable "create_kafka_connect_internal_streams" {
  description = "Create OCI Streaming streams used only by Kafka Connect distributed worker (config/offset/status). Keep false for standalone mode to reduce resource usage."
  type        = bool
  default     = false
}

variable "kafka_bootstrap_servers" {
  description = "Kafka bootstrap servers. If empty, computed from stream pool endpoint FQDN."
  type        = string
  default     = ""
}

variable "streaming_tenancy_name" {
  description = "Tenancy name used in SASL username for OCI Streaming Kafka auth."
  type        = string
  default     = ""
}

variable "streaming_user_name" {
  description = "OCI user name used in SASL username for OCI Streaming Kafka auth."
  type        = string
  default     = ""
}

variable "streaming_sasl_username" {
  description = "Optional full SASL username override for OCI Streaming Kafka auth. Defaults to <tenancy>/<user>/<stream_pool_id>."
  type        = string
  default     = ""
}

variable "streaming_auth_token" {
  description = "OCI auth token used as Kafka SASL password."
  type        = string
  sensitive   = true
  default     = ""
}

variable "splunk_hec_url" {
  description = "Splunk HEC URL for Kafka connector/function forwarding."
  type        = string
  default     = "https://splunk.example.com:8088/services/collector/event"
}

variable "splunk_hec_token" {
  description = "Splunk HEC token."
  type        = string
  sensitive   = true
}

variable "splunk_hec_index" {
  description = "Splunk HEC index."
  type        = string
  default     = "main"
}

variable "soc4kafka_collector_version" {
  description = "Splunk OTel Collector version used for SOC4Kafka."
  type        = string
  default     = "0.154.1"
}

variable "soc4kafka_group_id" {
  description = "Kafka consumer group id used by SOC4Kafka."
  type        = string
  default     = "oci-splunk-soc4kafka"
}

variable "soc4kafka_encoding" {
  description = "Kafka receiver log encoding used by SOC4Kafka."
  type        = string
  default     = "text"
}

variable "soc4kafka_source" {
  description = "Splunk source metadata for SOC4Kafka events."
  type        = string
  default     = "oci-streaming"
}

variable "soc4kafka_sourcetype" {
  description = "Splunk sourcetype metadata for SOC4Kafka events."
  type        = string
  default     = "oci:log"
}
