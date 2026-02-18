locals {
  created_lb_public_ip  = local.create_new_lb ? [for ip in oci_load_balancer_load_balancer.splunk[0].ip_address_details : ip.ip_address if ip.is_public][0] : ""
  existing_lb_public_ip = local.use_existing_lb ? var.existing_load_balancer_public_ip : ""
  lb_public_ip          = local.create_new_lb ? local.created_lb_public_ip : local.existing_lb_public_ip
  managed_splunk_ip     = local.create_managed_splunk ? try(oci_core_instance.splunk[0].public_ip, "") : ""
  splunk_access_host    = local.create_managed_splunk ? (local.lb_enabled ? local.lb_public_ip : local.managed_splunk_ip) : ""
}

output "vcn_id" {
  value       = local.effective_vcn_id
  description = "VCN OCID used by the deployment."
}

output "splunk_subnet_id" {
  value       = local.effective_subnet_id
  description = "Subnet OCID used by Splunk VM."
}

output "splunk_instance_id" {
  value       = local.create_managed_splunk ? oci_core_instance.splunk[0].id : null
  description = "Splunk VM OCID."
}

output "splunk_instance_private_ip" {
  value       = local.create_managed_splunk ? oci_core_instance.splunk[0].private_ip : null
  description = "Splunk VM private IP."
}

output "splunk_instance_public_ip" {
  value       = local.create_managed_splunk ? oci_core_instance.splunk[0].public_ip : null
  description = "Splunk VM public IP (empty for private subnet)."
}

output "load_balancer_id" {
  value       = local.create_new_lb ? oci_load_balancer_load_balancer.splunk[0].id : (local.use_existing_lb ? var.existing_load_balancer_id : null)
  description = "Load balancer OCID when LB path is enabled."
}

output "load_balancer_public_ip" {
  value       = local.lb_enabled ? local.lb_public_ip : null
  description = "Public LB IP when load balancer path is enabled."
}

output "splunk_web_url" {
  value       = local.create_managed_splunk ? "http://${local.splunk_access_host}:8000" : (var.existing_splunk_web_url != "" ? var.existing_splunk_web_url : null)
  description = "Splunk Web URL on port 8000."
}

output "splunk_hec_endpoint" {
  value       = local.create_managed_splunk ? "http://${local.splunk_access_host}:8088/services/collector/event" : var.splunk_hec_url
  description = "Splunk HEC endpoint URL on port 8088."
}

output "stream_pool_id" {
  value       = local.effective_stream_pool_id
  description = "Streaming pool OCID."
}

output "stream_id" {
  value       = local.effective_stream_id
  description = "Stream OCID."
}

output "stream_kafka_bootstrap_servers" {
  value       = local.kafka_bootstrap_servers
  description = "Kafka bootstrap servers for OCI Streaming."
}

output "logs_to_stream_connector_id" {
  value       = var.create_logs_to_stream_connector ? oci_sch_service_connector.logs_to_stream[0].id : null
  description = "Service Connector OCID for Logs->Stream."
}

output "function_app_id" {
  value       = local.effective_function_app_id != "" ? local.effective_function_app_id : null
  description = "Functions application OCID (if enabled)."
}

output "function_id" {
  value       = local.effective_function_id != "" ? local.effective_function_id : null
  description = "Function OCID (if created/provided)."
}

output "logs_to_functions_connector_id" {
  value       = var.create_logs_to_functions_connector && local.effective_function_id != "" ? oci_sch_service_connector.logs_to_functions[0].id : null
  description = "Service Connector OCID for Logs->Functions (if enabled)."
}
