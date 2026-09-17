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
# 6. PKI — Private Certificate Engine (IBM Secrets Manager)
#
#  Secrets Manager UI:
#    Secret Engines > Private Certificates > vpn-root-ca          (Root CA)
#                                          > vpn-intermediate-ca  (Intermediate CA)
#
#  Provisioning order:
#    Step 1  ibm_sm_private_certificate_configuration_root_ca
#              — self-signed Root CA inside SM
#    Step 2  ibm_sm_private_certificate_configuration_intermediate_ca
#              — Intermediate CA; signing_method="internal" + issuer=root_ca
#                causes SM to sign it with the Root CA automatically
#    Step 3  ibm_sm_private_certificate_configuration_template
#              — certificate template attached to the Intermediate CA
#    Step 4  ibm_sm_private_certificate  (x2)
#              — issues the VPN Server cert and the VPN Client CA cert
###############################################################################

# ── STEP 1 — Root CA ──────────────────────────────────────────────────────────
# Creates a self-signed Root CA inside the SM Private Certificate engine.
# Visible in UI: Secret Engines > Private Certificates > vpn-root-ca
resource "ibm_sm_private_certificate_configuration_root_ca" "root_ca" {
  instance_id  = ibm_resource_instance.secrets_manager.guid
  region       = var.region
  name         = var.root_ca_name

  common_name  = "VPN Root CA - ${var.cert_common_name}"
  organization = [var.cert_organization]
  # Root CA uses the longer CA validity — must outlive all certs it issues
  max_ttl      = "${var.cert_ca_validity_hours}h"

  depends_on = [time_sleep.wait_for_secrets_manager]
}

# ── STEP 2 — Intermediate CA ──────────────────────────────────────────────────
# signing_method = "internal" tells SM to sign the Intermediate CA CSR with the
# Root CA named in "issuer" — no external signing action is needed.
# Visible in UI: Secret Engines > Private Certificates > vpn-intermediate-ca
resource "ibm_sm_private_certificate_configuration_intermediate_ca" "intermediate_ca" {
  instance_id  = ibm_resource_instance.secrets_manager.guid
  region       = var.region
  name         = var.intermediate_ca_name

  common_name     = "VPN Intermediate CA - ${var.cert_common_name}"
  organization    = [var.cert_organization]
  # Intermediate CA also uses the longer CA validity — must outlive leaf certs
  max_ttl         = "${var.cert_ca_validity_hours}h"
  signing_method  = "internal"
  issuer          = ibm_sm_private_certificate_configuration_root_ca.root_ca.name

  depends_on = [ibm_sm_private_certificate_configuration_root_ca.root_ca]
}

# ── STEP 3 — Certificate Template ─────────────────────────────────────────────
# Defines allowed key usages and CN patterns for certs issued by the Intermediate CA.
# Both server_flag and client_flag are enabled so one template covers both use cases.
# max_ttl caps what leaf certs can request — set to cert_validity_hours (2 yr).
resource "ibm_sm_private_certificate_configuration_template" "vpn_cert_template" {
  instance_id = ibm_resource_instance.secrets_manager.guid
  region      = var.region
  name        = var.cert_template_name

  certificate_authority = ibm_sm_private_certificate_configuration_intermediate_ca.intermediate_ca.name
  # Template max_ttl = leaf validity — shorter than the CA TTL above
  max_ttl               = "${var.cert_validity_hours}h"
  allow_any_name        = true
  enforce_hostnames     = false
  server_flag           = true
  client_flag           = true
  key_type              = "rsa"
  key_bits              = 4096

  depends_on = [ibm_sm_private_certificate_configuration_intermediate_ca.intermediate_ca]
}

# ── STEP 4a — VPN Server Private Certificate (issued by Intermediate CA) ──────
# The Private Certificate engine issues this cert and stores the full chain
# (leaf + Intermediate CA + Root CA) in its attributes.
# ttl omitted → SM uses the largest TTL that fits within the CA's remaining life.
resource "ibm_sm_private_certificate" "vpn_server_cert_private" {
  instance_id      = ibm_resource_instance.secrets_manager.guid
  region           = var.region
  name             = "vpn-server-cert-private"
  description      = "Internal: VPN server cert issued by Private CA — re-imported as imported cert for VPN use"
  labels           = ["vpn", "server-cert", "internal"]
  secret_group_id  = "default"

  certificate_template = ibm_sm_private_certificate_configuration_template.vpn_cert_template.name
  common_name          = "vpn-server.${var.cert_common_name}"

  rotation {
    auto_rotate = false
  }

  depends_on = [ibm_sm_private_certificate_configuration_template.vpn_cert_template]
}

# ── STEP 4b — VPN Server Imported Certificate ─────────────────────────────────
# The IBM VPN Server requires certificate_crn to point to an Imported Certificate.
# It performs a full CA chain walk — so the 'intermediate' field must carry the
# complete chain: Intermediate CA PEM + Root CA PEM.
#
# We take the PEM values directly from the Private Certificate resource above and
# re-store them as an Imported Certificate, giving the VPN service the explicit
# chain it needs.
resource "ibm_sm_imported_certificate" "vpn_server_cert" {
  instance_id      = ibm_resource_instance.secrets_manager.guid
  region           = var.region
  name             = "vpn-server-certificate"
  description      = "VPN Server TLS certificate — full chain for IBM VPN Server"
  labels           = ["vpn", "server-cert"]
  secret_group_id  = "default"

  # leaf certificate issued by the Intermediate CA
  certificate  = ibm_sm_private_certificate.vpn_server_cert_private.certificate
  # private key for the leaf certificate
  private_key  = ibm_sm_private_certificate.vpn_server_cert_private.private_key
  # full chain: Intermediate CA cert + Root CA cert (ca_chain is a list; join into PEM bundle)
  intermediate = join("", ibm_sm_private_certificate.vpn_server_cert_private.ca_chain)

  depends_on = [ibm_sm_private_certificate.vpn_server_cert_private]
}

# ── STEP 4c — VPN Client CA Certificate ───────────────────────────────────────
# Issued by the Intermediate CA via the template.
# Used as client_ca_crn — the VPN service accepts a Private Certificate here
# because it only needs to verify client certs against it, not walk a server chain.
# ttl omitted — SM picks the largest TTL that fits within the CA's remaining life.
resource "ibm_sm_private_certificate" "vpn_client_ca_cert" {
  instance_id      = ibm_resource_instance.secrets_manager.guid
  region           = var.region
  name             = "vpn-client-ca-certificate"
  description      = "VPN Client CA certificate — issued by Intermediate CA"
  labels           = ["vpn", "client-ca"]
  secret_group_id  = "default"

  certificate_template = ibm_sm_private_certificate_configuration_template.vpn_cert_template.name
  common_name          = "vpn-client-ca.${var.cert_common_name}"

  rotation {
    auto_rotate = false
  }

  depends_on = [ibm_sm_private_certificate_configuration_template.vpn_cert_template]
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
    client_ca_crn = ibm_sm_private_certificate.vpn_client_ca_cert.crn
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
    ibm_sm_private_certificate.vpn_client_ca_cert,
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
