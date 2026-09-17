###############################################################################
# terraform.tfvars — IBM Cloud Client-to-Site VPN Server
# Fill in ALL values before running terraform plan / apply.
# Never commit this file to source control (add to .gitignore).
###############################################################################

###############################################################################
# Authentication
###############################################################################
ibmcloud_api_key = "YOUR_IBM_CLOUD_API_KEY_HERE"

###############################################################################
# Region & Zones
###############################################################################
region = "us-east"

# HA mode: provide 2 zones; Standalone mode: provide 1 zone
zones = ["us-east-1"]

###############################################################################
# 1. Resource Group
###############################################################################
resource_group_name = "hpc_prod"

###############################################################################
# 2. VPC
###############################################################################
vpc_name           = "wdccom-vpc-common"
vpc_address_prefix = "192.0.2.0/24"

###############################################################################
# 4. Subnets — HA or Standalone
#    "ha"         → 2 subnets across 2 zones (High Availability — RECOMMENDED)
#    "standalone" → 1 subnet in 1 zone
###############################################################################
subnet_mode  = "standalone"
subnet_cidrs = ["192.0.2.0/24"]

###############################################################################
# 5. IBM Secrets Manager
###############################################################################
secrets_manager_name = "vpn-secrets-manager"
secrets_manager_plan = "standard"   # "standard" or "trial"

###############################################################################
# 6. Private Certificate Engine — names visible in UI under Secret Engines
###############################################################################
root_ca_name         = "vpn-root-ca"
intermediate_ca_name = "vpn-intermediate-ca"

###############################################################################
# Certificate subject fields
###############################################################################
cert_common_name       = "vpn.wf.ibmcloud"
cert_organization      = "Wells Fargo Grid-aaS"
cert_ca_validity_hours = 26280   # 3 years — Root CA and Intermediate CA (must outlive leaf certs)
cert_validity_hours    = 2160    # 90 days — leaf certs: server cert + client CA cert

###############################################################################
# 8. Security Group
###############################################################################
security_group_name = "vpn-server-sg"
vpn_port            = 443
vpn_protocol        = "tcp"   # udp = recommended; tcp = fallback

###############################################################################
# VPN Server Name
###############################################################################
vpn_server_name = "vpn-client-to-site"

###############################################################################
# 3. Client IPv4 Address Pool
###############################################################################
client_ip_pool = "192.168.32.0/22"

###############################################################################
# 7. Authentication Methods (UserID & Passcode + Certificate)
###############################################################################
client_auth_methods = ["certificate", "username"]

###############################################################################
# 9. DNS Servers — IBM Cloud private DNS (required for private DNS resolution)
###############################################################################
client_dns_server_ips = ["161.26.0.7", "161.26.0.8"]

###############################################################################
# 10. Tunnel Mode — Split Tunnel
###############################################################################
enable_split_tunneling = true   # true = split tunnel | false = full tunnel

###############################################################################
# 11. Idle Timeout
###############################################################################
client_idle_timeout = 7200   # seconds (2 hours)

###############################################################################
# VPN Routes — subnets to advertise to clients through the tunnel
###############################################################################
vpn_routes = [
  {
    name        = "vpc-private-subnet-1"
    destination = "192.0.2.0/24"
  }
]

###############################################################################
# Tags
###############################################################################
tags = ["vpn", "client-to-site", "wells-fargo", "grid-aas", "terraform", "Schematics"]
