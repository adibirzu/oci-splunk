locals {
  create_network             = !var.use_existing_network
  create_managed_splunk      = !var.use_existing_splunk
  create_stream_pool         = var.existing_stream_pool_id == ""
  create_stream              = var.existing_stream_id == ""
  use_existing_lb            = var.existing_load_balancer_id != ""
  effective_vcn_id           = local.create_network ? oci_core_vcn.splunk[0].id : var.existing_vcn_id
  effective_subnet_id        = local.create_network ? oci_core_subnet.splunk[0].id : var.existing_subnet_id
  effective_stream_pool_id   = local.create_stream_pool ? oci_streaming_stream_pool.splunk[0].id : var.existing_stream_pool_id
  effective_stream_id        = local.create_stream ? oci_streaming_stream.splunk[0].id : var.existing_stream_id
  generated_bootstrap        = "cell-1.streaming.${var.region}.oci.oraclecloud.com:9092"
  kafka_bootstrap_servers    = var.kafka_bootstrap_servers != "" ? var.kafka_bootstrap_servers : local.generated_bootstrap
  create_new_lb              = local.create_managed_splunk && local.lb_enabled && !local.use_existing_lb
  effective_lb_subnet_id     = local.create_network ? try(oci_core_subnet.lb[0].id, "") : var.existing_lb_subnet_id
  create_function_app        = var.enable_functions_path && var.existing_function_app_id == ""
  create_function_resource   = var.enable_functions_path && var.function_image != "" && var.existing_function_id == ""
  function_subnet_ids_final  = length(var.function_subnet_ids) > 0 ? var.function_subnet_ids : [local.effective_subnet_id]
  kafka_connect_topic_prefix = "${var.project_prefix}-kafka-connect"
  kafka_connect_config_topic = "${local.kafka_connect_topic_prefix}-config"
  kafka_connect_offset_topic = "${local.kafka_connect_topic_prefix}-offset"
  kafka_connect_status_topic = "${local.kafka_connect_topic_prefix}-status"
  splunk_hec_uri             = trimsuffix((length(split("/services/collector", var.splunk_hec_url)) > 1 ? split("/services/collector", var.splunk_hec_url)[0] : var.splunk_hec_url), "/")
}

provider "oci" {
  region              = var.region
  auth                = var.auth
  config_file_profile = contains(["ApiKey", "SecurityToken"], var.auth) ? var.oci_profile : null
  tenancy_ocid        = var.tenancy_ocid != "" ? var.tenancy_ocid : null
  user_ocid           = var.user_ocid != "" ? var.user_ocid : null
  fingerprint         = var.fingerprint != "" ? var.fingerprint : null
  private_key_path    = var.private_key_path != "" ? var.private_key_path : null
}

resource "terraform_data" "input_guards" {
  lifecycle {
    precondition {
      condition     = var.allowed_ingress_cidr != ""
      error_message = "allowed_ingress_cidr must be set to your public IP CIDR (for example 203.0.113.10/32)."
    }
    precondition {
      condition     = var.use_existing_network ? (var.existing_vcn_id != "" && var.existing_subnet_id != "") : true
      error_message = "When use_existing_network=true, existing_vcn_id and existing_subnet_id are required."
    }
    precondition {
      condition     = var.use_existing_splunk ? true : var.ssh_public_key != ""
      error_message = "ssh_public_key is required when creating a managed Splunk VM."
    }
    precondition {
      condition     = var.use_existing_splunk ? true : var.splunk_admin_password != ""
      error_message = "splunk_admin_password is required when creating a managed Splunk VM."
    }
    precondition {
      condition     = var.create_logs_to_functions_connector ? var.enable_functions_path : true
      error_message = "create_logs_to_functions_connector=true requires enable_functions_path=true."
    }
    precondition {
      condition     = var.create_logs_to_functions_connector ? (var.existing_function_id != "" || var.function_image != "") : true
      error_message = "To create Logs->Functions connector, set existing_function_id or function_image."
    }
    precondition {
      condition     = var.use_existing_splunk ? var.splunk_hec_url != "" : true
      error_message = "When use_existing_splunk=true, splunk_hec_url is required."
    }
    precondition {
      condition     = var.use_existing_splunk ? var.splunk_hec_token != "" : true
      error_message = "When use_existing_splunk=true, splunk_hec_token is required."
    }
  }
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_ocid
}

resource "oci_core_vcn" "splunk" {
  count          = local.create_network ? 1 : 0
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${var.project_prefix}-vcn"
}

resource "oci_core_internet_gateway" "splunk" {
  count          = local.create_network ? 1 : 0
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.splunk[0].id
  display_name   = "${var.project_prefix}-igw"
  enabled        = true
}

resource "oci_core_nat_gateway" "splunk" {
  count          = local.create_network ? 1 : 0
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.splunk[0].id
  display_name   = "${var.project_prefix}-nat"
}

resource "oci_core_route_table" "public" {
  count          = local.create_network ? 1 : 0
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.splunk[0].id
  display_name   = "${var.project_prefix}-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.splunk[0].id
  }
}

resource "oci_core_route_table" "private" {
  count          = local.create_network ? 1 : 0
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.splunk[0].id
  display_name   = "${var.project_prefix}-private-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.splunk[0].id
  }
}

resource "oci_core_security_list" "splunk" {
  count          = local.create_network ? 1 : 0
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.splunk[0].id
  display_name   = "${var.project_prefix}-splunk-sl"

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }

  ingress_security_rules {
    source      = var.allowed_ingress_cidr
    source_type = "CIDR_BLOCK"
    protocol    = "6"
    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    source      = var.allowed_ingress_cidr
    source_type = "CIDR_BLOCK"
    protocol    = "6"
    tcp_options {
      min = 8000
      max = 8000
    }
  }

  ingress_security_rules {
    source      = var.allowed_ingress_cidr
    source_type = "CIDR_BLOCK"
    protocol    = "6"
    tcp_options {
      min = 8088
      max = 8088
    }
  }
}

resource "oci_core_network_security_group" "splunk" {
  count          = (local.create_network || var.existing_nsg_id == "") ? 1 : 0
  compartment_id = var.compartment_ocid
  vcn_id         = local.effective_vcn_id
  display_name   = "${var.project_prefix}-splunk-nsg"
}

locals {
  effective_nsg_id = var.existing_nsg_id != "" ? var.existing_nsg_id : oci_core_network_security_group.splunk[0].id
}

resource "oci_core_network_security_group_security_rule" "splunk_ingress_ssh" {
  count                     = local.create_network || var.existing_nsg_id == "" ? 1 : 0
  network_security_group_id = oci_core_network_security_group.splunk[0].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = var.allowed_ingress_cidr
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "splunk_ingress_web" {
  count                     = local.create_network || var.existing_nsg_id == "" ? 1 : 0
  network_security_group_id = oci_core_network_security_group.splunk[0].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = var.allowed_ingress_cidr
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 8000
      max = 8000
    }
  }
}

resource "oci_core_network_security_group_security_rule" "splunk_ingress_hec" {
  count                     = local.create_network || var.existing_nsg_id == "" ? 1 : 0
  network_security_group_id = oci_core_network_security_group.splunk[0].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = var.allowed_ingress_cidr
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 8088
      max = 8088
    }
  }
}

resource "oci_core_subnet" "splunk" {
  count                      = local.create_network ? 1 : 0
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.splunk[0].id
  cidr_block                 = var.splunk_subnet_cidr
  display_name               = "${var.project_prefix}-splunk-subnet"
  prohibit_public_ip_on_vnic = var.create_private_splunk_subnet
  route_table_id             = var.create_private_splunk_subnet ? oci_core_route_table.private[0].id : oci_core_route_table.public[0].id
  security_list_ids          = [oci_core_security_list.splunk[0].id]
  prohibit_internet_ingress  = false
}

resource "oci_core_subnet" "lb" {
  count                      = local.create_network && var.create_private_splunk_subnet ? 1 : 0
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.splunk[0].id
  cidr_block                 = var.lb_subnet_cidr
  display_name               = "${var.project_prefix}-lb-subnet"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public[0].id
  prohibit_internet_ingress  = false
}

locals {
  splunk_subnet_private = var.create_private_splunk_subnet
  lb_enabled            = var.create_private_splunk_subnet ? var.enable_load_balancer_for_private : var.enable_load_balancer_for_public
}

resource "terraform_data" "lb_guards" {
  lifecycle {
    precondition {
      condition     = var.create_private_splunk_subnet ? local.lb_enabled : true
      error_message = "Selected Splunk subnet is private. Enable load balancer or use a public subnet."
    }
    precondition {
      condition     = local.create_new_lb ? (local.effective_lb_subnet_id != "") : true
      error_message = "Creating a new LB requires an LB subnet. Set existing_lb_subnet_id or let Terraform create network with private subnet mode."
    }
  }
}

data "oci_core_images" "ol8" {
  count                    = local.create_managed_splunk ? 1 : 0
  compartment_id           = var.compartment_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = "8"
  shape                    = var.splunk_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "splunk" {
  count               = local.create_managed_splunk ? 1 : 0
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain != "" ? var.availability_domain : data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "${var.project_prefix}-splunk"
  shape               = var.splunk_shape

  shape_config {
    ocpus         = var.splunk_ocpus
    memory_in_gbs = var.splunk_memory_gb
  }

  source_details {
    source_type             = "image"
    source_id               = var.splunk_image_ocid != "" ? var.splunk_image_ocid : data.oci_core_images.ol8[0].images[0].id
    boot_volume_size_in_gbs = var.splunk_boot_volume_gb
  }

  create_vnic_details {
    subnet_id        = local.effective_subnet_id
    assign_public_ip = var.create_private_splunk_subnet ? false : true
    nsg_ids          = [local.effective_nsg_id]
    display_name     = "${var.project_prefix}-splunk-vnic"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/templates/splunk-cloud-init.tftpl", {
      splunk_admin_password_b64  = base64encode(var.splunk_admin_password)
      splunk_hec_token_b64       = base64encode(var.splunk_hec_token)
      splunk_hec_index           = var.splunk_hec_index
      splunk_hec_uri             = "http://127.0.0.1:8088"
      stream_name                = var.stream_name
      kafka_bootstrap_servers    = local.kafka_bootstrap_servers
      stream_pool_id             = local.effective_stream_pool_id
      streaming_tenancy_name     = var.streaming_tenancy_name
      streaming_user_name        = var.streaming_user_name
      streaming_auth_token_b64   = base64encode(var.streaming_auth_token)
      kafka_connect_config_topic = local.kafka_connect_config_topic
      kafka_connect_offset_topic = local.kafka_connect_offset_topic
      kafka_connect_status_topic = local.kafka_connect_status_topic
    }))
  }

  lifecycle {
    precondition {
      condition     = try(length(data.oci_core_images.ol8[0].images), 0) > 0 || var.splunk_image_ocid != ""
      error_message = "No Oracle Linux 8 image available for the selected shape/region."
    }
  }
}

resource "oci_load_balancer_load_balancer" "splunk" {
  count          = local.create_new_lb ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "${var.project_prefix}-splunk-lb"
  shape          = "flexible"
  subnet_ids     = [local.effective_lb_subnet_id]
  is_private     = false

  shape_details {
    minimum_bandwidth_in_mbps = 10
    maximum_bandwidth_in_mbps = 100
  }
}

resource "oci_load_balancer_backend_set" "splunk_web" {
  count            = local.create_new_lb ? 1 : 0
  load_balancer_id = oci_load_balancer_load_balancer.splunk[0].id
  name             = "splunk-web-bs"
  policy           = "ROUND_ROBIN"

  health_checker {
    protocol = "TCP"
    port     = 8000
  }
}

resource "oci_load_balancer_backend_set" "splunk_hec" {
  count            = local.create_new_lb ? 1 : 0
  load_balancer_id = oci_load_balancer_load_balancer.splunk[0].id
  name             = "splunk-hec-bs"
  policy           = "ROUND_ROBIN"

  health_checker {
    protocol = "TCP"
    port     = 8088
  }
}

resource "oci_load_balancer_backend" "splunk_web" {
  count            = local.create_new_lb ? 1 : 0
  load_balancer_id = oci_load_balancer_load_balancer.splunk[0].id
  backendset_name  = oci_load_balancer_backend_set.splunk_web[0].name
  ip_address       = oci_core_instance.splunk[0].private_ip
  port             = 8000
}

resource "oci_load_balancer_backend" "splunk_hec" {
  count            = local.create_new_lb ? 1 : 0
  load_balancer_id = oci_load_balancer_load_balancer.splunk[0].id
  backendset_name  = oci_load_balancer_backend_set.splunk_hec[0].name
  ip_address       = oci_core_instance.splunk[0].private_ip
  port             = 8088
}

resource "oci_load_balancer_listener" "splunk_web" {
  count                    = local.create_new_lb ? 1 : 0
  load_balancer_id         = oci_load_balancer_load_balancer.splunk[0].id
  name                     = "splunk-web-8000"
  default_backend_set_name = oci_load_balancer_backend_set.splunk_web[0].name
  port                     = 8000
  protocol                 = "TCP"
}

resource "oci_load_balancer_listener" "splunk_hec" {
  count                    = local.create_new_lb ? 1 : 0
  load_balancer_id         = oci_load_balancer_load_balancer.splunk[0].id
  name                     = "splunk-hec-8088"
  default_backend_set_name = oci_load_balancer_backend_set.splunk_hec[0].name
  port                     = 8088
  protocol                 = "TCP"
}

resource "oci_streaming_stream_pool" "splunk" {
  count          = local.create_stream_pool ? 1 : 0
  compartment_id = var.compartment_ocid
  name           = var.stream_pool_name
}

resource "oci_streaming_stream" "splunk" {
  count              = local.create_stream ? 1 : 0
  name               = var.stream_name
  partitions         = var.stream_partitions
  stream_pool_id     = local.effective_stream_pool_id
  retention_in_hours = var.stream_retention_hours
}

resource "oci_streaming_stream" "kafka_connect_config" {
  count              = var.create_kafka_connect_internal_streams ? 1 : 0
  name               = local.kafka_connect_config_topic
  partitions         = 1
  stream_pool_id     = local.effective_stream_pool_id
  retention_in_hours = var.stream_retention_hours
}

resource "oci_streaming_stream" "kafka_connect_offset" {
  count              = var.create_kafka_connect_internal_streams ? 1 : 0
  name               = local.kafka_connect_offset_topic
  partitions         = 1
  stream_pool_id     = local.effective_stream_pool_id
  retention_in_hours = var.stream_retention_hours
}

resource "oci_streaming_stream" "kafka_connect_status" {
  count              = var.create_kafka_connect_internal_streams ? 1 : 0
  name               = local.kafka_connect_status_topic
  partitions         = 1
  stream_pool_id     = local.effective_stream_pool_id
  retention_in_hours = var.stream_retention_hours
}

resource "oci_sch_service_connector" "logs_to_stream" {
  count          = var.create_logs_to_stream_connector ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = var.service_connector_stream_name

  source {
    kind = "logging"
    log_sources {
      compartment_id = var.compartment_ocid
      log_group_id   = var.log_group_ocid
      log_id         = var.log_ocid
    }
  }

  target {
    kind      = "streaming"
    stream_id = local.effective_stream_id
  }
}

resource "oci_functions_application" "splunk" {
  count          = local.create_function_app ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = var.function_app_name
  subnet_ids     = local.function_subnet_ids_final
}

locals {
  effective_function_app_id = var.enable_functions_path ? (var.existing_function_app_id != "" ? var.existing_function_app_id : try(oci_functions_application.splunk[0].id, "")) : ""
}

resource "oci_functions_function" "splunk" {
  count              = local.create_function_resource ? 1 : 0
  application_id     = local.effective_function_app_id
  display_name       = var.function_name
  image              = var.function_image
  memory_in_mbs      = 256
  timeout_in_seconds = 30

  config = {
    SPLUNK_HEC_URL   = var.splunk_hec_url
    SPLUNK_HEC_TOKEN = var.splunk_hec_token
    SPLUNK_HEC_INDEX = var.splunk_hec_index
  }
}

locals {
  effective_function_id = var.enable_functions_path ? (var.existing_function_id != "" ? var.existing_function_id : try(oci_functions_function.splunk[0].id, "")) : ""
}

resource "oci_sch_service_connector" "logs_to_functions" {
  count          = var.create_logs_to_functions_connector && local.effective_function_id != "" ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = var.service_connector_functions_name

  source {
    kind = "logging"
    log_sources {
      compartment_id = var.compartment_ocid
      log_group_id   = var.log_group_ocid
      log_id         = var.log_ocid
    }
  }

  target {
    kind        = "functions"
    function_id = local.effective_function_id
  }
}

resource "local_file" "kafka_worker_config" {
  count    = var.generate_local_kafka_artifacts ? 1 : 0
  filename = "${path.module}/generated/connect-distributed.properties"
  content = templatefile("${path.module}/templates/connect-distributed.properties.tftpl", {
    kafka_bootstrap_servers = local.kafka_bootstrap_servers
    stream_pool_id          = local.effective_stream_pool_id
    tenancy_name            = var.streaming_tenancy_name
    user_name               = var.streaming_user_name
    auth_token              = var.streaming_auth_token
    config_storage_topic    = local.kafka_connect_config_topic
    offset_storage_topic    = local.kafka_connect_offset_topic
    status_storage_topic    = local.kafka_connect_status_topic
  })
}

resource "local_file" "splunk_sink_connector" {
  count    = var.generate_local_kafka_artifacts ? 1 : 0
  filename = "${path.module}/generated/splunk-sink-connector.json"
  content = templatefile("${path.module}/templates/splunk-sink-connector.json.tftpl", {
    topic_name       = var.stream_name
    splunk_hec_uri   = local.splunk_hec_uri
    splunk_hec_token = var.splunk_hec_token
    splunk_hec_index = var.splunk_hec_index
  })
}

resource "local_file" "function_code" {
  count    = var.enable_functions_path ? 1 : 0
  filename = "${path.module}/generated/func.py"
  content  = file("${path.module}/templates/func.py")
}
