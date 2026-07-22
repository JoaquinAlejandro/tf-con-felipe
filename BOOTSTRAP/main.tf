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

  # Seguridad: solo autenticación Azure AD, sin claves de acceso
  shared_access_key_enabled = false
}

# Contenedor para planes aplicados (histórico permanente)
resource "azurerm_storage_container" "applied_plans" {
  name                  = "applied-plans"
  storage_account_id    = azurerm_storage_account.plan_history.id
  container_access_type = "private"
}

# Contenedor para planes pendientes de aplicar (TTL 1 día)
resource "azurerm_storage_container" "pending_plans" {
  name                  = "pending-plans"
  storage_account_id    = azurerm_storage_account.plan_history.id
  container_access_type = "private"
}

# Lifecycle policy: eliminar blobs en pending-plans tras 1 día
resource "azurerm_storage_management_policy" "plan_lifecycle" {
  storage_account_id = azurerm_storage_account.plan_history.id

  rule {
    name    = "delete-pending-plans-after-1-day"
    enabled = true

    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["pending-plans/"]
    }

    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = 1
      }
    }
  }
}

# RBAC: asignar Storage Blob Data Contributor al Service Principal de GitHub
# Así solo el pipeline puede leer/escribir blobs en esta Storage Account
resource "azurerm_role_assignment" "github_sp_blob_contributor" {
  scope                = azurerm_storage_account.plan_history.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azuread_service_principal.github_actions.object_id
}

# =============================================================================
# Key Vault — almacenamiento seguro de secretos
# Los secretos se consumen desde AZURE/ mediante data sources
# =============================================================================

# Key Vault para almacenar secretos de forma segura
resource "azurerm_key_vault" "infra" {
  name                = "kv-tf-pipeline-meta"
  resource_group_name = azurerm_resource_group.bootstrap_rg.name
  location            = azurerm_resource_group.bootstrap_rg.location
  tenant_id           = data.azuread_client_config.current.tenant_id
  sku_name            = "standard"

  # Solo Azure AD auth (consistente con shared_access_key_enabled = false)
  enable_rbac_authorization = true

  # Soft-delete retention por si se borra algo por error
  soft_delete_retention_days = 7
}

# RBAC: el SP de GitHub solo puede LEER secretos (no crearlos ni modificarlos)
resource "azurerm_role_assignment" "github_sp_kv_secrets_user" {
  scope                = azurerm_key_vault.infra.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = data.azuread_service_principal.github_actions.object_id
}

# RBAC: el usuario local puede CREAR y ADMINISTRAR secretos
resource "azurerm_role_assignment" "local_kv_secrets_officer" {
  scope                = azurerm_key_vault.infra.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azuread_client_config.current.object_id
}

# =============================================================================
# Outputs — copiar estos valores a los secrets de GitHub
# =============================================================================

output "storage_account_name" {
  description = "Agregar como secret AZURE_STORAGE_ACCOUNT_NAME en GitHub"
  value       = azurerm_storage_account.plan_history.name
}

output "storage_container_applied_name" {
  description = "Agregar como secret AZURE_STORAGE_CONTAINER_APPLIED_NAME en GitHub"
  value       = azurerm_storage_container.applied_plans.name
}

output "storage_container_pending_name" {
  description = "Agregar como secret AZURE_STORAGE_CONTAINER_PENDING_NAME en GitHub"
  value       = azurerm_storage_container.pending_plans.name
}

output "github_sp_object_id" {
  description = "Object ID del Service Principal de GitHub (informativo)"
  value       = data.azuread_service_principal.github_actions.object_id
}

output "key_vault_name" {
  description = "Nombre del Key Vault para referenciar desde AZURE/"
  value       = azurerm_key_vault.infra.name
}

output "key_vault_id" {
  description = "ID del Key Vault para data sources"
  value       = azurerm_key_vault.infra.id
}