resource "azurerm_resource_group" "rg" {
  name     = "rg-req-felipe"
  location = "eastus"
}

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-aislada"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "snet_app" {
  name                 = "snet-maquina-virtual"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "snet_db" {
  name                 = "snet-base-datos"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]

  delegation {
    name = "delegacion-pgsql"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# =============================================================================
# Subred para Azure Container Apps (requiere /23 mínimo)
# =============================================================================
resource "azurerm_subnet" "snet_containerapps" {
  name                 = "snet-container-apps"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.4.0/23"]

  delegation {
    name = "delegacion-containerapps"
    service_delegation {
      name = "Microsoft.App/environments"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action"
      ]
    }
  }
}

# =============================================================================
# Log Analytics Workspace — monitoreo de Container Apps
# SKU PerGB2018: pago por uso, sin costo fijo
# =============================================================================
resource "azurerm_log_analytics_workspace" "containerapps" {
  name                = "law-containerapps"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = 1 # Límite diario para evitar costos inesperados
}

# =============================================================================
# Azure Container Registry (ACR) — almacenamiento de imágenes
# SKU Basic: ~$5/mes, el más económico
# =============================================================================
resource "azurerm_container_registry" "acr" {
  name                = "crtfconfelipe"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = true
}

# =============================================================================
# Container App Environment — equivalente a un ECS Cluster
# Consumption-only: sin costo fijo, pago por uso
# =============================================================================
resource "azurerm_container_app_environment" "cae" {
  name                           = "cae-felipe"
  location                       = azurerm_resource_group.rg.location
  resource_group_name            = azurerm_resource_group.rg.name
  infrastructure_subnet_id       = azurerm_subnet.snet_containerapps.id
  internal_load_balancer_enabled = false
  zone_redundancy_enabled        = false # Sin zone redundancy para ahorrar costos

  log_analytics_workspace_id = azurerm_log_analytics_workspace.containerapps.id
}

# =============================================================================
# Container App — equivalente a un ECS Fargate Service
# Escala a cero (min_replicas = 0) para ahorrar costos cuando no hay tráfico
# =============================================================================
resource "azurerm_container_app" "app" {
  name                         = "ca-felipe-app"
  container_app_environment_id = azurerm_container_app_environment.cae.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  template {
    container {
      name   = "app"
      image  = "nginx:alpine"
      cpu    = 0.25
      memory = "0.5Gi"
    }

    min_replicas = 0 # Escala a cero → $0 cuando no hay tráfico
    max_replicas = 1
  }

  ingress {
    allow_insecure_connections = false
    external_enabled           = true
    target_port                = 80
    transport                  = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }
}

# =============================================================================
# Outputs
# =============================================================================
output "container_app_fqdn" {
  description = "URL pública de la Container App"
  value       = azurerm_container_app.app.latest_revision_fqdn
}

output "container_registry_login_server" {
  description = "Login server del ACR para docker push/pull"
  value       = azurerm_container_registry.acr.login_server
}

output "container_app_environment_name" {
  description = "Nombre del Container App Environment"
  value       = azurerm_container_app_environment.cae.name
}