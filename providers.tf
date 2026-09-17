###############################################################################
# IBM Cloud Provider
# Authenticate via API Key — set IC_API_KEY env var or use the variable below
###############################################################################
provider "ibm" {
  ibmcloud_api_key = var.ibmcloud_api_key
  region           = var.region
}
