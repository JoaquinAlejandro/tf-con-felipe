# =============================================================================
# BOOTSTRAP: Meta-infraestructura para el pipeline de CI/CD
# =============================================================================
# Este Terraform se ejecuta UNA SOLA VEZ, manualmente desde local.
# Crea la Storage Account donde se guarda el historial de planes aplicados.
#
# Prerrequisito: az login (autenticarse contra Azure)
# =============================================================================

# Grupo de recursos exclusivo para la meta-infraestructura del pipeline
resource "azurerm_resource_group" "bootstrap_rg" {
  name     = "rg-tf-pipeline-meta"
  location = "eastus"
}

# Storage Account para guardar el historial de planes aplicados
resource "azurerm_storage_account" "plan_history" {
  name                     = "sttfplanhistory"
  resource_group_name      = azurerm_resource_group.bootstrap_rg.name
  location                 = azurerm_resource_group.bootstrap_rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
  network_rules {
    default_action             = "Deny"
    bypass                     = ["AzureServices"]
    virtual_network_subnet_ids = []
  }
}

# Contenedor dentro de la Storage Account
resource "azurerm_storage_container" "applied_plans" {
  name                  = "applied-plans"
  storage_account_name  = azurerm_storage_account.plan_history.name
  container_access_type = "private"
}

# =============================================================================
# Outputs — copiar estos valores a los secrets de GitHub
# =============================================================================

output "storage_account_name" {
  description = "Agregar como secret AZURE_STORAGE_ACCOUNT_NAME en GitHub"
  value       = azurerm_storage_account.plan_history.name
}

output "storage_container_name" {
  description = "Agregar como secret AZURE_STORAGE_CONTAINER_NAME en GitHub"
  value       = azurerm_storage_container.applied_plans.name
}