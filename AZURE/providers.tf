terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.70.0"
    }
  }
}

provider "azurerm" {
  features {}

  # Registrar automáticamente todos los Resource Providers necesarios
  # (Microsoft.App, Microsoft.ContainerRegistry, etc.)
  # Sin esto, Terraform solo registra Compute/Network/Storage por defecto
  resource_provider_registrations = "all"
}