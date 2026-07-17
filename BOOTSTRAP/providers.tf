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
      version = "~> 3.90.0"
    }
  }
}

provider "azurerm" {
  features {}
}