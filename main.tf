###############################################################################
# IBM Cloud Client-to-Site VPN Server
# Requirements:
#   1.  Resource Group
#   2.  VPC
#   3.  Client IPv4 pool : 192.168.32.0/22
#   4.  HA or Standalone subnets (controlled by var.subnet_mode)
#   5.  IBM Secrets Manager
#   6.  Server + Client CA certificates (TLS-generated, stored in SM)
#   7.  UserID & Passcode authentication (IBMid / username_password method)
#   8.  Security Groups
#   9.  Additional DNS: 161.26.0.7 + 161.26.0.8 (IBM Cloud private DNS)
#   10. Split Tunnel mode
#   11. Idle Timeout: 7200 seconds
###############################################################################

###############################################################################
# 1. RESOURCE GROUP
###############################################################################
resource "ibm_resource_group" "vpn_rg" {
  name = var.resource_group_name
  tags = var.tags
}

###############################################################################
# 2. VIRTUAL PRIVATE CLOUD (VPC)
###############################################################################
resource "ibm_is_vpc" "vpn_vpc" {
  name                      = var.vpc_name
  resource_group            = ibm_resource_group.vpn_rg.id
  address_prefix_management = "manual"
  tags                      = var.tags

  # Ensure resource group is fully ready before VPC creation
  depends_on = [ibm_resource_group.vpn_rg]
}

# VPC Address Prefixes — one per zone used
resource "ibm_is_vpc_address_prefix" "vpn_prefix" {
  count = length(var.subnet_cidrs)

  name = "${var.vpc_name}-prefix-${count.index + 1}"
  vpc  = ibm_is_vpc.vpn_vpc.id
  zone = var.zones[count.index]
  cidr = var.subnet_cidrs[count.index]
}

###############################################################################
# 4. SUBNETS — HA (2 subnets / 2 zones) or Standalone (1 subnet / 1 zone)
#    Controlled by var.subnet_mode = "ha" | "standalone"
###############################################################################
locals {
  # Number of subnets to create based on mode
  subnet_count = var.subnet_mode == "ha" ? 2 : 1
}

resource "ibm_is_subnet" "vpn_subnet" {
  count = local.subnet_count

  name            = "${var.vpc_name}-subnet-${count.index + 1}"
  vpc             = ibm_is_vpc.vpn_vpc.id
  zone            = var.zones[count.index]
  ipv4_cidr_block = var.subnet_cidrs[count.index]
  resource_group  = ibm_resource_group.vpn_rg.id
  tags            = var.tags

  depends_on = [ibm_is_vpc_address_prefix.vpn_prefix]
}

###############################################################################
# 5. IBM SECRETS MANAGER INSTANCE
###############################################################################
resource "ibm_resource_instance" "secrets_manager" {
  name              = var.secrets_manager_name
  service           = "secrets-manager"
  plan              = var.secrets_manager_plan
  location          = var.region
  resource_group_id = ibm_resource_group.vpn_rg.id
  tags              = var.tags

  timeouts {
    create = "30m"
    delete = "30m"
  }
}

###############################################################################
# IAM SERVICE-TO-SERVICE AUTHORIZATION
# Allow VPN for VPC (is) to read secrets from Secrets Manager
###############################################################################
resource "ibm_iam_authorization_policy" "vpn_to_sm" {
  source_service_name         = "is"
  source_resource_type        = "vpn-server"
  target_service_name         = "secrets-manager"
  target_resource_instance_id = ibm_resource_instance.secrets_manager.guid
  roles                       = ["SecretsReader"]

  description = "Allow VPN Server to read TLS certificates from Secrets Manager"
}

###############################################################################
# 6. TLS CERTIFICATE GENERATION (Terraform tls provider)
#    Generates a self-signed CA, then issues server + client CA certificates.
#    Both are stored in IBM Secrets Manager as imported certificates.
###############################################################################

# ── Root CA private key & self-signed certificate ───────────────────────────
resource "tls_private_key" "ca_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "ca_cert" {
  private_key_pem = tls_private_key.ca_key.private_key_pem

  subject {
    common_name  = "VPN Root CA — ${var.cert_common_name}"
    organization = var.cert_organization
  }

  validity_period_hours = var.cert_validity_hours
  is_ca_certificate     = true

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "cert_signing",
    "crl_signing",
  ]
}

# ── VPN Server private key & certificate signed by CA ───────────────────────
resource "tls_private_key" "server_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_cert_request" "server_csr" {
  private_key_pem = tls_private_key.server_key.private_key_pem

  subject {
    common_name  = "vpn-server.${var.cert_common_name}"
    organization = var.cert_organization
  }
}

resource "tls_locally_signed_cert" "server_cert" {
  cert_request_pem      = tls_cert_request.server_csr.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca_key.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca_cert.cert_pem
  validity_period_hours = var.cert_validity_hours

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# ── Client CA private key & certificate signed by Root CA ───────────────────
resource "tls_private_key" "client_ca_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_cert_request" "client_ca_csr" {
  private_key_pem = tls_private_key.client_ca_key.private_key_pem

  subject {
    common_name  = "vpn-client-ca.${var.cert_common_name}"
    organization = var.cert_organization
  }
}

resource "tls_locally_signed_cert" "client_ca_cert" {
  cert_request_pem      = tls_cert_request.client_ca_csr.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca_key.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca_cert.cert_pem
  validity_period_hours = var.cert_validity_hours
  is_ca_certificate     = true

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "cert_signing",
    "client_auth",
  ]
}

# ── Store Server Certificate in Secrets Manager ──────────────────────────────
resource "ibm_sm_imported_certificate" "vpn_server_cert" {
  instance_id     = ibm_resource_instance.secrets_manager.guid
  region          = var.region
  name            = "vpn-server-certificate"
  description     = "VPN Server TLS certificate used by the Client-to-Site VPN server"
  labels          = ["vpn", "server-cert"]

  certificate     = tls_locally_signed_cert.server_cert.cert_pem
  private_key     = tls_private_key.server_key.private_key_pem
  intermediate    = tls_self_signed_cert.ca_cert.cert_pem
}

# ── Store Client CA Certificate in Secrets Manager ──────────────────────────
resource "ibm_sm_imported_certificate" "vpn_client_ca_cert" {
  instance_id     = ibm_resource_instance.secrets_manager.guid
  region          = var.region
  name            = "vpn-client-ca-certificate"
  description     = "Client CA certificate used to authenticate VPN clients"
  labels          = ["vpn", "client-ca"]

  certificate     = tls_locally_signed_cert.client_ca_cert.cert_pem
  private_key     = tls_private_key.client_ca_key.private_key_pem
  intermediate    = tls_self_signed_cert.ca_cert.cert_pem
}

###############################################################################
# 8. SECURITY GROUP
#    Allows VPN client traffic (UDP 443) inbound and all outbound to VPC.
###############################################################################
resource "ibm_is_security_group" "vpn_sg" {
  name           = var.security_group_name
  vpc            = ibm_is_vpc.vpn_vpc.id
  resource_group = ibm_resource_group.vpn_rg.id
  tags           = var.tags
}

# Inbound — VPN client connections (UDP 443 from anywhere)
resource "ibm_is_security_group_rule" "vpn_inbound_udp" {
  group     = ibm_is_security_group.vpn_sg.id
  direction = "inbound"
  remote    = "0.0.0.0/0"

  udp {
    port_min = var.vpn_port
    port_max = var.vpn_port
  }
}

# Inbound — TCP 443 fallback (optional but recommended for clients behind strict firewalls)
resource "ibm_is_security_group_rule" "vpn_inbound_tcp" {
  group     = ibm_is_security_group.vpn_sg.id
  direction = "inbound"
  remote    = "0.0.0.0/0"

  tcp {
    port_min = var.vpn_port
    port_max = var.vpn_port
  }
}

# Outbound — Allow VPN server to reach all VPC resources
resource "ibm_is_security_group_rule" "vpn_outbound_all" {
  group     = ibm_is_security_group.vpn_sg.id
  direction = "outbound"
  remote    = "0.0.0.0/0"
}

# Inbound — Allow ICMP (ping) for health checks
resource "ibm_is_security_group_rule" "vpn_inbound_icmp" {
  group     = ibm_is_security_group.vpn_sg.id
  direction = "inbound"
  remote    = "0.0.0.0/0"

  protocol  = "icmp"
  type      = 8
}

###############################################################################
# VPN SERVER
# Requirements applied:
#   3.  Client IPv4 pool    → 192.168.32.0/22
#   7.  Auth methods        → certificate + username_password (UserID & Passcode)
#   9.  DNS servers         → 161.26.0.7 + 161.26.0.8
#   10. Tunnel mode         → split_tunnel = true
#   11. Idle timeout        → 7200 seconds
#
# HA mode  → 2 subnet IDs passed → IBM deploys redundant servers across 2 zones
# Standalone → 1 subnet ID
###############################################################################
resource "ibm_is_vpn_server" "vpn_server" {
  name           = var.vpn_server_name
  resource_group = ibm_resource_group.vpn_rg.id
  tags           = var.tags

  # ── Network ──────────────────────────────────────────────────────────────
  # HA: both subnets; Standalone: first subnet only
  subnets        = [for s in ibm_is_subnet.vpn_subnet : s.id]
  security_groups = [ibm_is_security_group.vpn_sg.id]

  # ── Transport ─────────────────────────────────────────────────────────────
  protocol = var.vpn_protocol   # udp
  port     = var.vpn_port       # 443

  # ── Certificates (Req 6) ──────────────────────────────────────────────────
  certificate_crn = ibm_sm_imported_certificate.vpn_server_cert.crn

  # ── Client IP Pool (Req 3) ────────────────────────────────────────────────
  client_ip_pool = var.client_ip_pool    # 192.168.32.0/22

  # ── Authentication (Req 7) ────────────────────────────────────────────────
  # certificate       → mutual TLS using client certificates
  # username_password → IBMid (UserID & Passcode / SAML federation)
  client_authentication {
    method            = "certificate"
    client_ca_crn     = ibm_sm_imported_certificate.vpn_client_ca_cert.crn
  }

  client_authentication {
    method            = "username_password"
    identity_provider = "iam"
  }

  # ── DNS Servers (Req 9) ───────────────────────────────────────────────────
  # IBM Cloud private DNS for resolving private VPC endpoints
  client_dns_server_ips = var.client_dns_server_ips   # ["161.26.0.7", "161.26.0.8"]

  # ── Split Tunnel (Req 10) ─────────────────────────────────────────────────
  # true  → Only VPC-destined traffic is routed through the VPN tunnel
  # false → Full tunnel (all client traffic via VPN)
  enable_split_tunneling = var.enable_split_tunneling  # true

  # ── Idle Timeout (Req 11) ─────────────────────────────────────────────────
  # Disconnects idle clients after 7200 seconds (2 hours)
  client_idle_timeout = var.client_idle_timeout         # 7200

  depends_on = [
    ibm_iam_authorization_policy.vpn_to_sm,
    ibm_sm_imported_certificate.vpn_server_cert,
    ibm_sm_imported_certificate.vpn_client_ca_cert,
    ibm_is_subnet.vpn_subnet,
    ibm_is_security_group_rule.vpn_inbound_udp,
  ]
}

###############################################################################
# VPN ROUTES
# Advertise VPC private subnets to connected clients (split tunnel mode).
# Each route tells the VPN server to deliver matching traffic into the VPC.
###############################################################################
resource "ibm_is_vpn_server_route" "vpn_routes" {
  for_each = { for r in var.vpn_routes : r.name => r }

  vpn_server  = ibm_is_vpn_server.vpn_server.id
  name        = each.value.name
  destination = each.value.destination
  action      = "deliver"
}
