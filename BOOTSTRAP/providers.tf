# =============================================================================
# BOOTSTRAP: Provider configuration
# =============================================================================
# Autenticación: usa la sesión de Azure CLI (az login).
# No requiere OIDC ni secrets — solo para ejecución local única.
# =============================================================================

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.70.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.53"
    }
  }
}

provider "azurerm" {
  features {}

  # Usar Azure AD para Storage Blob & Queue APIs (no SharedKey)
  # Requerido cuando shared_access_key_enabled = false
  storage_use_azuread = true
}

provider "azuread" {
  # Usa la misma sesión de az login
}

# =============================================================================
# Data sources — resolver el Service Principal de GitHub por client_id
# =============================================================================

variable "github_sp_client_id" {
  description = "Client ID (Application ID) del Service Principal que usa GitHub Actions (OIDC)"
  type        = string
}

data "azuread_service_principal" "github_actions" {
  client_id = var.github_sp_client_id
}

# Data source para obtener el tenant ID y el object ID del usuario local
data "azuread_client_config" "current" {}