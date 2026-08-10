# =============================================================================
# Outputs — AI Project Chat Workflow
# =============================================================================

output "query_api_fqdn" {
  description = "FQDN de Query API; el acceso requiere API key salvo /health"
  value       = azurerm_container_app.query_api.latest_revision_fqdn
}

output "query_api_url" {
  description = "URL HTTPS de Query API"
  value       = "https://${azurerm_container_app.query_api.latest_revision_fqdn}"
}

output "container_registry_login_server" {
  description = "Login server del ACR para docker push/pull"
  value       = azurerm_container_registry.acr.login_server
}

output "container_app_environment_name" {
  description = "Nombre del Container App Environment"
  value       = azurerm_container_app_environment.cae.name
}

output "context_indexer_job_name" {
  description = "Nombre del Container Apps Job para iniciar indexación"
  value       = azurerm_container_app_job.context_indexer.name
}

output "query_api_principal_id" {
  description = "Principal ID de la identidad administrada de Query API"
  value       = azurerm_container_app.query_api.identity[0].principal_id
}

output "context_indexer_principal_id" {
  description = "Principal ID de la identidad administrada del Indexer Job"
  value       = azurerm_container_app_job.context_indexer.identity[0].principal_id
}

output "resource_group_name" {
  description = "Nombre del Resource Group"
  value       = azurerm_resource_group.rg.name
}
