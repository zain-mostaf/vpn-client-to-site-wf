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
  service_endpoints = "public-and-private"
  parameters = {
    "service-endpoints" = "public-and-private"
    "allowed_network"   = "public-and-private"
  }
  resource_group_id = ibm_resource_group.vpn_rg.id
  tags              = var.tags

  timeouts {
    create = "30m"
    delete = "30m"
  }
}

# Allow DNS propagation and Secrets Manager instance initialization
resource "time_sleep" "wait_for_secrets_manager" {
  depends_on      = [ibm_resource_instance.secrets_manager]
  create_duration = "300s"
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
# 6. PKI — Two-Tier Certificate Authority (tls provider + IBM Secrets Manager)
#
#  The IBM VPN for VPC service resolves certificate_crn by walking the issuer
#  chain via SM secret CRNs.  The Private Certificate engine stores CAs as
#  engine *configurations*, not as addressable secrets — so the VPN service
#  cannot follow the chain from a Private-CA-issued cert.
#
#  Solution: generate the entire PKI with the Terraform tls provider and store
#  every PEM (Root CA, Intermediate CA, server cert, client CA cert) as an
#  ibm_sm_imported_certificate secret.  Each secret has a CRN the VPN service
#  can resolve, and the explicit chain is bundled in the 'intermediate' field.
#
#  UI visibility:
#    Secret Engines > Private Certificates > vpn-root-ca         (engine config)
#                                          > vpn-intermediate-ca (engine config)
#    Secrets (Imported Certificates):
#      vpn-root-ca-cert          — Root CA PEM
#      vpn-intermediate-ca-cert  — Intermediate CA PEM + Root CA
#      vpn-server-certificate    — server leaf + Intermediate CA + Root CA
#      vpn-client-ca-certificate — client CA leaf + Intermediate CA + Root CA
#
#  Provisioning order:
#    Step 1  tls_private_key / tls_self_signed_cert         — Root CA key + cert
#    Step 2  tls_private_key / tls_locally_signed_cert      — Intermediate CA key + cert
#    Step 3  tls_private_key / tls_locally_signed_cert (x2) — server + client CA leaf certs
#    Step 4  ibm_sm_imported_certificate (x4)               — store all PEMs in SM
#    Step 5  ibm_sm_private_certificate_configuration_root_ca / _intermediate_ca
#              — register Root CA + Intermediate CA in the SM Private Cert engine
#                (cosmetic — populates Secret Engines > Private Certificates in UI)
###############################################################################

# ── STEP 1 — Root CA key & self-signed certificate ───────────────────────────
resource "tls_private_key" "root_ca_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "root_ca_cert" {
  private_key_pem   = tls_private_key.root_ca_key.private_key_pem
  is_ca_certificate = true

  subject {
    common_name  = "VPN Root CA - ${var.cert_common_name}"
    organization = var.cert_organization
  }

  validity_period_hours = var.cert_ca_validity_hours

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
  ]
}

# ── STEP 2 — Intermediate CA key & certificate signed by Root CA ──────────────
resource "tls_private_key" "intermediate_ca_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_cert_request" "intermediate_ca_csr" {
  private_key_pem = tls_private_key.intermediate_ca_key.private_key_pem

  subject {
    common_name  = "VPN Intermediate CA - ${var.cert_common_name}"
    organization = var.cert_organization
  }
}

resource "tls_locally_signed_cert" "intermediate_ca_cert" {
  cert_request_pem   = tls_cert_request.intermediate_ca_csr.cert_request_pem
  ca_private_key_pem = tls_private_key.root_ca_key.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.root_ca_cert.cert_pem
  is_ca_certificate  = true

  validity_period_hours = var.cert_ca_validity_hours

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
  ]
}

# ── STEP 3a — VPN Server leaf certificate signed by Intermediate CA ───────────
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
  cert_request_pem   = tls_cert_request.server_csr.cert_request_pem
  ca_private_key_pem = tls_private_key.intermediate_ca_key.private_key_pem
  ca_cert_pem        = tls_locally_signed_cert.intermediate_ca_cert.cert_pem

  validity_period_hours = var.cert_validity_hours

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# ── STEP 3b — VPN Client CA leaf certificate signed by Intermediate CA ────────
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
  cert_request_pem   = tls_cert_request.client_ca_csr.cert_request_pem
  ca_private_key_pem = tls_private_key.intermediate_ca_key.private_key_pem
  ca_cert_pem        = tls_locally_signed_cert.intermediate_ca_cert.cert_pem
  is_ca_certificate  = true

  validity_period_hours = var.cert_validity_hours

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "cert_signing",
    "client_auth",
  ]
}

# ── STEP 4 — Store all certificates in Secrets Manager as Imported Certs ──────
# IBM VPN for VPC resolves certificate_crn and client_ca_crn by looking up SM
# secret CRNs and walking the issuer chain.  All four PEMs must be stored as
# ibm_sm_imported_certificate so the VPN service can follow the chain.

# Root CA — stored so it is accessible by CRN for chain resolution
resource "ibm_sm_imported_certificate" "root_ca_cert" {
  instance_id     = ibm_resource_instance.secrets_manager.guid
  region          = var.region
  name            = "vpn-root-ca-cert"
  description     = "VPN Root CA certificate"
  labels          = ["vpn", "root-ca"]
  secret_group_id = "default"

  certificate = tls_self_signed_cert.root_ca_cert.cert_pem

  depends_on = [time_sleep.wait_for_secrets_manager]
}

# Intermediate CA — chain: Intermediate CA cert + Root CA cert
resource "ibm_sm_imported_certificate" "intermediate_ca_cert" {
  instance_id     = ibm_resource_instance.secrets_manager.guid
  region          = var.region
  name            = "vpn-intermediate-ca-cert"
  description     = "VPN Intermediate CA certificate"
  labels          = ["vpn", "intermediate-ca"]
  secret_group_id = "default"

  certificate  = tls_locally_signed_cert.intermediate_ca_cert.cert_pem
  intermediate = tls_self_signed_cert.root_ca_cert.cert_pem

  depends_on = [time_sleep.wait_for_secrets_manager]
}

# VPN Server certificate — chain: server leaf + Intermediate CA + Root CA
# certificate_crn on ibm_is_vpn_server points here.
resource "ibm_sm_imported_certificate" "vpn_server_cert" {
  instance_id     = ibm_resource_instance.secrets_manager.guid
  region          = var.region
  name            = "vpn-server-certificate"
  description     = "VPN Server TLS certificate — full chain bundled for IBM VPN Server"
  labels          = ["vpn", "server-cert"]
  secret_group_id = "default"

  certificate  = tls_locally_signed_cert.server_cert.cert_pem
  private_key  = tls_private_key.server_key.private_key_pem
  intermediate = "${tls_locally_signed_cert.intermediate_ca_cert.cert_pem}${tls_self_signed_cert.root_ca_cert.cert_pem}"

  depends_on = [time_sleep.wait_for_secrets_manager]
}

# VPN Client CA certificate — chain: client CA leaf + Intermediate CA + Root CA
# client_ca_crn on ibm_is_vpn_server points here.
resource "ibm_sm_imported_certificate" "vpn_client_ca_cert" {
  instance_id     = ibm_resource_instance.secrets_manager.guid
  region          = var.region
  name            = "vpn-client-ca-certificate"
  description     = "VPN Client CA certificate — full chain bundled for IBM VPN Server"
  labels          = ["vpn", "client-ca"]
  secret_group_id = "default"

  certificate  = tls_locally_signed_cert.client_ca_cert.cert_pem
  private_key  = tls_private_key.client_ca_key.private_key_pem
  intermediate = "${tls_locally_signed_cert.intermediate_ca_cert.cert_pem}${tls_self_signed_cert.root_ca_cert.cert_pem}"

  depends_on = [time_sleep.wait_for_secrets_manager]
}

# ── STEP 5 — Register CAs in the SM Private Certificate engine (UI only) ──────
# These engine configurations make the Root CA and Intermediate CA visible in:
#   Secrets Manager UI > Secret Engines > Private Certificates
# They are NOT used for cert issuance — the tls provider above handles that.

resource "ibm_sm_private_certificate_configuration_root_ca" "root_ca" {
  instance_id  = ibm_resource_instance.secrets_manager.guid
  region       = var.region
  name         = var.root_ca_name

  common_name  = "VPN Root CA - ${var.cert_common_name}"
  organization = [var.cert_organization]
  max_ttl      = "${var.cert_ca_validity_hours}h"

  depends_on = [time_sleep.wait_for_secrets_manager]
}

resource "ibm_sm_private_certificate_configuration_intermediate_ca" "intermediate_ca" {
  instance_id  = ibm_resource_instance.secrets_manager.guid
  region       = var.region
  name         = var.intermediate_ca_name

  common_name    = "VPN Intermediate CA - ${var.cert_common_name}"
  organization   = [var.cert_organization]
  max_ttl        = "${var.cert_ca_validity_hours}h"
  signing_method = "internal"
  issuer         = ibm_sm_private_certificate_configuration_root_ca.root_ca.name

  depends_on = [ibm_sm_private_certificate_configuration_root_ca.root_ca]
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

  protocol  = "udp"
  port_min  = var.vpn_port
  port_max  = var.vpn_port
}

# Inbound — TCP 443 fallback (optional but recommended for clients behind strict firewalls)
resource "ibm_is_security_group_rule" "vpn_inbound_tcp" {
  group     = ibm_is_security_group.vpn_sg.id
  direction = "inbound"
  remote    = "0.0.0.0/0"

  protocol  = "tcp"
  port_min  = var.vpn_port
  port_max  = var.vpn_port
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
  # Must be an Imported Certificate — the VPN service walks the full CA chain.
  certificate_crn = ibm_sm_imported_certificate.vpn_server_cert.crn

  # ── Client IP Pool (Req 3) ────────────────────────────────────────────────
  client_ip_pool = var.client_ip_pool    # 192.168.32.0/22

  # ── Authentication (Req 7) ────────────────────────────────────────────────
  # certificate → mutual TLS using client certificates
  # username    → IBMid (UserID & Passcode / SAML federation)
  client_authentication {
    method        = "certificate"
    client_ca_crn = ibm_sm_imported_certificate.vpn_client_ca_cert.crn
  }

  client_authentication {
    method            = "username"
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
