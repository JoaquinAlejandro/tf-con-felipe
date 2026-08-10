# =============================================================================
# Variables locales
# =============================================================================
locals {
  query_api_image       = "${azurerm_container_registry.acr.login_server}/query-api:latest"
  context_indexer_image = "${azurerm_container_registry.acr.login_server}/context-indexer:latest"
}

# =============================================================================
# Resource Group
# =============================================================================
resource "azurerm_resource_group" "rg" {
  name     = "rg-req-felipe"
  location = "eastus"
}

# =============================================================================
# Virtual Network
# =============================================================================
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
  daily_quota_gb      = 1
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
# Container App Environment — Consumption-only, sin costo fijo
# =============================================================================
resource "azurerm_container_app_environment" "cae" {
  name                           = "cae-felipe"
  location                       = azurerm_resource_group.rg.location
  resource_group_name            = azurerm_resource_group.rg.name
  infrastructure_subnet_id       = azurerm_subnet.snet_containerapps.id
  internal_load_balancer_enabled = false
  zone_redundancy_enabled        = false

  log_analytics_workspace_id = azurerm_log_analytics_workspace.containerapps.id
}

# =============================================================================
# QUERY API — Container App HTTP (privada, escala a cero)
# =============================================================================
resource "azurerm_container_app" "query_api" {
  name                         = "ca-query-api"
  container_app_environment_id = azurerm_container_app_environment.cae.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  template {
    container {
      name   = "query-api"
      image  = local.query_api_image
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "PORT"
        value = "3001"
      }
      env {
        name  = "DB_URL"
        value = var.turso_db_url
      }
      env {
        name  = "EMBEDDING_MODEL"
        value = var.embedding_model
      }
      env {
        name  = "EMBEDDING_PROVIDER"
        value = var.embedding_provider
      }
      env {
        name  = "EMBEDDING_DIMENSIONS"
        value = var.embedding_dimensions
      }
      env {
        name  = "NODE_ENV"
        value = "production"
      }
      env {
        name  = "LOG_LEVEL"
        value = "info"
      }
      env {
        name        = "DATABASE_AUTH_TOKEN"
        secret_name = "turso-auth-token"
      }
      env {
        name        = "OPENROUTER_API_KEY"
        secret_name = "openrouter-api-key"
      }
      env {
        name        = "SENTRY_DSN"
        secret_name = "sentry-dsn"
      }
      env {
        name        = "QUERY_API_API_KEY"
        secret_name = "query-api-api-key"
      }
    }

    min_replicas = 0
    max_replicas = 1
  }

  secret {
    name  = "turso-auth-token"
    value = var.turso_auth_token
  }
  secret {
    name  = "openrouter-api-key"
    value = var.openrouter_api_key
  }
  secret {
    name  = "sentry-dsn"
    value = var.sentry_dsn
  }
  secret {
    name  = "query-api-api-key"
    value = var.query_api_api_key
  }

  ingress {
    allow_insecure_connections = false
    external_enabled           = var.query_api_external_enabled
    target_port                = 3001
    transport                  = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  identity {
    type = "SystemAssigned"
  }

  registry {
    server               = azurerm_container_registry.acr.login_server
    username             = azurerm_container_registry.acr.admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name  = "acr-password"
    value = azurerm_container_registry.acr.admin_password
  }

  tags = {
    environment = "production"
    service     = "query-api"
  }
}

# =============================================================================
# CONTEXT INDEXER — Container Apps Job (manual, batch)
# =============================================================================
resource "azurerm_container_app_job" "context_indexer" {
  name                         = "caj-context-indexer"
  location                     = azurerm_resource_group.rg.location
  resource_group_name          = azurerm_resource_group.rg.name
  container_app_environment_id = azurerm_container_app_environment.cae.id

  replica_timeout_in_seconds = 600
  replica_retry_limit        = 1

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  template {
    container {
      name   = "context-indexer"
      image  = local.context_indexer_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "DATABASE_URL"
        value = var.turso_db_url
      }
      env {
        name  = "EMBEDDING_ENDPOINT"
        value = var.embedding_endpoint
      }
      env {
        name  = "EMBEDDING_MODEL"
        value = var.embedding_model
      }
      env {
        name  = "EMBEDDING_DIMENSION"
        value = var.embedding_dimensions
      }
      env {
        name  = "LOG_LEVEL"
        value = "INFO"
      }
      env {
        name        = "DATABASE_AUTH_TOKEN"
        secret_name = "turso-auth-token"
      }
      env {
        name        = "EMBEDDING_API_KEY"
        secret_name = "embedding-api-key"
      }
      env {
        name        = "GITHUB_TOKEN"
        secret_name = "github-token"
      }
    }
  }

  secret {
    name  = "turso-auth-token"
    value = var.turso_auth_token
  }
  secret {
    name  = "embedding-api-key"
    value = var.embedding_api_key
  }
  secret {
    name  = "github-token"
    value = var.github_token
  }

  identity {
    type = "SystemAssigned"
  }

  registry {
    server               = azurerm_container_registry.acr.login_server
    username             = azurerm_container_registry.acr.admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name  = "acr-password"
    value = azurerm_container_registry.acr.admin_password
  }

  tags = {
    environment = "production"
    service     = "context-indexer"
  }
}

# =============================================================================
# RBAC — ACR Pull para las identidades administradas
# =============================================================================
resource "azurerm_role_assignment" "query_api_acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_container_app.query_api.identity[0].principal_id
}

resource "azurerm_role_assignment" "context_indexer_acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_container_app_job.context_indexer.identity[0].principal_id
}

# GitHub Actions controla el despliegue y dispara el Job mediante el plano de
# control de Azure. No se publica el indexador ni se abre su red al runner.
resource "azurerm_role_assignment" "github_actions_acr_push" {
  count                = var.github_actions_principal_id == "" ? 0 : 1
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPush"
  principal_id         = var.github_actions_principal_id
}

resource "azurerm_role_assignment" "github_actions_container_apps" {
  count                = var.github_actions_principal_id == "" ? 0 : 1
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Azure Container Apps Contributor"
  principal_id         = var.github_actions_principal_id
}