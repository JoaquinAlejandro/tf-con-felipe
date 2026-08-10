# =============================================================================
# Variables de configuración — AI Project Chat Workflow
# =============================================================================

variable "turso_db_url" {
  description = "URL de la base de datos Turso/libSQL"
  type        = string
  sensitive   = false
}

variable "turso_auth_token" {
  description = "Token de autenticación para Turso"
  type        = string
  sensitive   = true
}

variable "openrouter_api_key" {
  description = "API key de OpenRouter para embeddings"
  type        = string
  sensitive   = true
  default     = ""
}

variable "embedding_api_key" {
  description = "API key para el proveedor de embeddings del indexador"
  type        = string
  sensitive   = true
  default     = ""
}

variable "embedding_endpoint" {
  description = "Endpoint del proveedor de embeddings"
  type        = string
  default     = "https://openrouter.ai/api/v1"
}

variable "embedding_model" {
  description = "Modelo de embeddings"
  type        = string
  default     = "openai/text-embedding-3-small"
}

variable "embedding_provider" {
  description = "Proveedor de embeddings para Query API"
  type        = string
  default     = "OpenAI"
}

variable "embedding_dimensions" {
  description = "Dimensiones del vector de embedding"
  type        = string
  default     = "1536"
}

variable "sentry_dsn" {
  description = "DSN de Sentry para monitoreo de errores"
  type        = string
  sensitive   = true
  default     = ""
}

variable "query_api_external_enabled" {
  description = "Publica Query API mediante HTTPS. La aplicación exige QUERY_API_API_KEY en rutas distintas de /health."
  type        = bool
  default     = true
}

variable "query_api_api_key" {
  description = "API key para proteger Query API; debe inyectarse por TF_VAR_query_api_api_key o un backend de secretos."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.query_api_api_key) >= 32
    error_message = "query_api_api_key debe tener al menos 32 caracteres."
  }
}

variable "github_actions_principal_id" {
  description = "Object ID del principal federado de GitHub Actions; opcional hasta configurar RBAC desde Terraform."
  type        = string
  default     = ""
}

variable "github_token" {
  description = "Token de GitHub para que el indexer clone repositorios privados"
  type        = string
  sensitive   = true
  default     = ""
}
