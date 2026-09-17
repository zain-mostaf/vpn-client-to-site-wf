# IBM Cloud Client-to-Site VPN Server — Terraform

Terraform configuration to deploy a **Client-to-Site VPN Server** on IBM Cloud VPC with all required infrastructure components.

---

## Architecture Overview

```
                        ┌──────────────────────────────────────────────────┐
                        │              IBM Cloud (us-south)                │
                        │                                                  │
  VPN Client            │  ┌─────────────────────────────────────────────┐ │
  (OpenVPN)  ──UDP443──►│  │          VPC: vpn-vpc (10.240.0.0/18)       │ │
                        │  │                                              │ │
                        │  │  ┌──────────────┐    ┌──────────────────┐   │ │
                        │  │  │ Subnet Zone-1│    │  Subnet Zone-2   │   │ │
                        │  │  │10.240.0.0/24 │    │ 10.240.1.0/24    │   │ │
                        │  │  │  [VPN Node 1]│    │  [VPN Node 2]    │   │ │
                        │  │  └──────┬───────┘    └────────┬─────────┘   │ │
                        │  │         └──────────┬──────────┘             │ │
                        │  │               HA VPN Server                 │ │
                        │  │     (192.168.32.0/22 client pool)           │ │
                        │  └─────────────────────────────────────────────┘ │
                        │                                                  │
                        │  ┌────────────────────────────────────────────┐  │
                        │  │        IBM Secrets Manager                 │  │
                        │  │  - vpn-server-certificate (TLS)            │  │
                        │  │  - vpn-client-ca-certificate               │  │
                        │  └────────────────────────────────────────────┘  │
                        └──────────────────────────────────────────────────┘
```

---

## Requirements Implemented

| # | Requirement | Configuration |
|---|-------------|---------------|
| 1 | **Resource Group** | `ibm_resource_group.vpn_rg` |
| 2 | **VPC** | `ibm_is_vpc.vpn_vpc` |
| 3 | **Client IPv4 Pool** | `192.168.32.0/22` |
| 4 | **HA Subnets** | 2 subnets × 2 zones (toggle with `subnet_mode`) |
| 5 | **Secrets Manager** | `ibm_resource_instance.secrets_manager` |
| 6 | **Server + Client CA Certs** | TLS-generated, stored in Secrets Manager |
| 7 | **UserID & Passcode** | `username_password` (IBMid) + `certificate` auth |
| 8 | **Security Groups** | UDP/TCP 443 inbound, all outbound |
| 9 | **IBM Private DNS** | `161.26.0.7`, `161.26.0.8` |
| 10 | **Split Tunnel** | `enable_split_tunneling = true` |
| 11 | **Idle Timeout** | `client_idle_timeout = 7200` seconds |

---

## Prerequisites

Before running Terraform, ensure you have:

- [ ] IBM Cloud account with active billing
- [ ] IBM Cloud API Key
- [ ] IAM roles: **VPC Infrastructure Services Editor** + **Secrets Manager Manager**
- [ ] Terraform `>= 1.3.0` installed
- [ ] IBM Cloud Terraform provider `>= 1.65.0`

---

## Project Structure

```
vpn-client-to-site/
├── versions.tf        # Terraform + provider version constraints
├── providers.tf       # IBM Cloud provider configuration
├── variables.tf       # All input variable definitions
├── main.tf            # All resource definitions
├── outputs.tf         # Output values
├── terraform.tfvars   # Variable values (DO NOT commit to git)
└── README.md          # This file
```

---

## Quick Start

### 1. Configure API Key

```bash
# Option A — Environment variable (recommended, keeps key out of files)
export IC_API_KEY="your-ibm-cloud-api-key"

# Option B — terraform.tfvars (never commit this file)
echo 'ibmcloud_api_key = "your-ibm-cloud-api-key"' >> terraform.tfvars
```

### 2. Update terraform.tfvars

Open `terraform.tfvars` and update at minimum:

```hcl
ibmcloud_api_key    = "YOUR_KEY"
region              = "us-south"
cert_common_name    = "vpn.yourdomain.com"
cert_organization   = "Your Organization"
```

### 3. Initialize

```bash
terraform init
```

### 4. Plan

```bash
terraform plan -out=tfplan
```

Review the plan — you should see **~20 resources** to create.

### 5. Apply

```bash
terraform apply tfplan
```

Provisioning takes approximately **10–15 minutes** (Secrets Manager instance creation is the slowest step).

---

## Subnet Modes

### High Availability (Default — Recommended)
```hcl
subnet_mode  = "ha"
zones        = ["us-south-1", "us-south-2"]
subnet_cidrs = ["10.240.0.0/24", "10.240.1.0/24"]
```
IBM deploys redundant VPN server nodes across 2 availability zones. Automatic failover if one zone fails.

### Standalone
```hcl
subnet_mode  = "standalone"
zones        = ["us-south-1"]
subnet_cidrs = ["10.240.0.0/24"]
```
Single VPN node in one zone. Lower cost, no redundancy.

---

## Authentication Modes

The VPN server supports **two simultaneous authentication methods**:

| Method | Description |
|--------|-------------|
| `certificate` | Client presents a certificate signed by the Client CA |
| `username_password` | IBMid login — UserID + Passcode (one-time code from https://iam.cloud.ibm.com/identity/passcode) |

Both methods are enabled by default. Clients must satisfy **both** unless you remove one from `client_auth_methods`.

---

## Client .ovpn Profile

After `terraform apply`, the following values populate your OpenVPN client profile:

```
remote  <vpn_server_hostname>  443  udp
auth-user-pass            # IBMid username + passcode
ca      <root_ca_cert.pem>     # From output: root_ca_certificate_pem
cert    <client_cert.pem>      # Client certificate signed by client CA
key     <client_key.pem>       # Client private key
```

Get the hostname:
```bash
terraform output vpn_server_hostname
```

Get the root CA certificate (save to `ca.pem` for client trust):
```bash
terraform output -raw root_ca_certificate_pem > ca.pem
```

---

## VPN Routes (Split Tunnel)

With `enable_split_tunneling = true`, only traffic matching the defined routes goes through the VPN tunnel. Everything else uses the client's local network.

Default routes push both VPC private subnets:
```hcl
vpn_routes = [
  { name = "vpc-private-subnet-1", destination = "10.240.0.0/24" },
  { name = "vpc-private-subnet-2", destination = "10.240.1.0/24" },
]
```

Add more routes to expose additional CIDR ranges through the tunnel.

---

## DNS Resolution

IBM Cloud private DNS IPs are pushed to all connected clients:

| IP | Service |
|----|---------|
| `161.26.0.7` | IBM Cloud private DNS primary |
| `161.26.0.8` | IBM Cloud private DNS secondary |

This allows VPN clients to resolve:
- Private VPC service endpoints (e.g., `s3.direct.us-south.cloud-object-storage.appdomain.cloud`)
- Private service endpoint hostnames
- Custom DNS zones created in IBM Cloud DNS Services

---

## Key Outputs

```bash
terraform output vpn_server_id          # VPN server resource ID
terraform output vpn_server_hostname    # Connect clients to this hostname
terraform output vpn_server_health      # Should be "ok" when stable
terraform output vpc_id                 # VPC ID for additional resources
terraform output subnet_ids             # Subnet IDs
terraform output secrets_manager_id    # Secrets Manager GUID
terraform output client_ovpn_hint       # Quick-reference values for .ovpn profile
```

---

## Security Notes

1. **Never commit `terraform.tfvars`** — add it to `.gitignore`
2. **Certificate private keys** are stored as sensitive outputs — use `terraform output -raw`
3. The **Secrets Manager standard plan** is billed; delete with `terraform destroy` when not needed
4. Rotate certificates before `cert_validity_hours` expires (default: 2 years)
5. Consider restricting the inbound security group rule from `0.0.0.0/0` to known egress IP ranges in production

---

## Destroy

```bash
terraform destroy
```

> **Note:** Secrets Manager instance deletion can take up to 30 minutes.

---

## Terraform Resources Created

| Resource | Type | Count |
|----------|------|-------|
| Resource Group | `ibm_resource_group` | 1 |
| VPC | `ibm_is_vpc` | 1 |
| VPC Address Prefixes | `ibm_is_vpc_address_prefix` | 2 (HA) |
| Subnets | `ibm_is_subnet` | 2 (HA) |
| Secrets Manager | `ibm_resource_instance` | 1 |
| IAM Authorization Policy | `ibm_iam_authorization_policy` | 1 |
| TLS Keys (CA + Server + Client) | `tls_private_key` | 3 |
| TLS Certificates | `tls_self_signed_cert` / `tls_locally_signed_cert` | 3 |
| Secrets Manager Certs | `ibm_sm_imported_certificate` | 2 |
| Security Group | `ibm_is_security_group` | 1 |
| Security Group Rules | `ibm_is_security_group_rule` | 4 |
| VPN Server | `ibm_is_vpn_server` | 1 |
| VPN Routes | `ibm_is_vpn_server_route` | 2 |

**Total: ~24 resources**
