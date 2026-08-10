# tf-con-felipe — Infraestructura Azure con Terraform

## Workloads de AI Context Platform

La infraestructura despliega dos workloads en un único Azure Container Apps
Environment para mantener bajo el costo:

- **`ca-query-api`**: Container App HTTP, escala de 0 a 1 réplica y expone
  HTTPS. `/health` es público para probes; el resto de las rutas requiere el
  header `x-api-key` configurado mediante `QUERY_API_API_KEY`.
- **`caj-context-indexer`**: Container Apps Job manual, sin ingress. GitHub
  Actions lo inicia mediante `az containerapp job start` usando OIDC y RBAC;
  no se expone ningún endpoint del indexador a Internet.

El Job solo consume recursos durante una ejecución. El pipeline de aplicación
publica las imágenes en ACR y actualiza Query API; Terraform permanece en este
repositorio.

### Variables sensibles

No guardar tokens en `terraform.tfvars` ni en Git. Inyectar como variables
`TF_VAR_turso_auth_token`, `TF_VAR_query_api_api_key`, `TF_VAR_embedding_api_key`
y `TF_VAR_github_token`, o resolverlos desde un backend de secretos.

El Key Vault de bootstrap no es consumido actualmente por los workflows. Los
secretos de CI/CD se mantienen en GitHub Secrets. El Key Vault permanece
protegido con Azure RBAC y ACL de red `default_action = "Deny"`; si se necesita
administrarlo localmente, se debe autorizar temporalmente la IP pública del
administrador o usar una conexión privada.

Proyecto de infraestructura como código (IaC) para desplegar recursos en Azure usando Terraform y GitHub Actions. Este documento explica qué hace el proyecto, cómo está organizado, y el paso a paso de cada cambio aplicado.

---

## ¿Qué infraestructura despliega este proyecto?

Este proyecto crea en Azure una arquitectura lista para ejecutar aplicaciones en contenedores, con red privada y espacio para una base de datos PostgreSQL:

```
Azure (eastus)
└── rg-req-felipe
    ├── vnet-aislada (10.0.0.0/16)          ← Red privada aislada
    │   ├── snet-maquina-virtual (10.0.1.0/24)  ← Subred para VMs (reservada)
    │   ├── snet-base-datos (10.0.2.0/24)       ← Subred para PostgreSQL
    │   └── snet-container-apps (10.0.4.0/23)   ← Subred para Container Apps
    ├── law-containerapps                    ← Log Analytics (monitoreo)
    ├── crtfconfelipe                        ← Azure Container Registry
    ├── cae-felipe                           ← Container App Environment
    ├── ca-query-api                         ← Query API (privada, escala a cero)
    └── caj-context-indexer                  ← Context Indexer (Job batch manual)
```

### ¿Qué es cada recurso?

| Recurso | ¿Qué hace? | Equivalente en AWS |
|---|---|---|
| **Resource Group** | Contenedor lógico que agrupa todos los recursos | _No tiene equivalente directo_ |
| **Virtual Network** | Red privada aislada donde se comunican los recursos | VPC |
| **Subnet** | Segmento de la red con su propio rango de IPs | Subnet |
| **Container App Environment** | Entorno administrado que ejecuta contenedores sin gestionar VMs | ECS Cluster |
| **Container App** | Aplicación empaquetada en un contenedor que escala automáticamente | ECS Fargate Service |
| **Azure Container Registry** | Registro privado para almacenar imágenes Docker | ECR |
| **Log Analytics Workspace** | Servicio centralizado de logs y métricas | CloudWatch Logs |

### ¿Por qué Container Apps y no VMs?

- **Sin administrar servidores**: Azure se encarga del sistema operativo, parches y escalado
- **Escala a cero**: Si no hay tráfico, no pagás nada
- **Más barato**: Una VM pequeña cuesta ~$15-30/mes fijos. Container Apps puede costar $0
- **Más simple**: No necesitás instalar Docker, configurar systemd, ni mantener la VM

---

## Estructura del proyecto

```
tf-con-felipe/
├── BOOTSTRAP/                    # Meta-infraestructura (se ejecuta UNA vez)
│   ├── main.tf                   # Storage Account, Key Vault, containers, RBAC
│   └── providers.tf
├── AZURE/                        # Infraestructura principal
│   ├── main.tf                   # VNet, subredes, Container Apps, ACR
│   └── providers.tf              # azurerm ~> 4.70.0
├── .github/workflows/
│   └── azure-terraform.yml       # Pipeline CI/CD
├── .gitignore                    # Excluye archivos de estado de Terraform
├── .trivyignore                  # Ignora falso positivo AZU-0012 (intencional)
├── docker-compose.yml            # Herramientas de desarrollo (Trivy, etc.)
└── readme.txt                    # Este archivo
```

---

## Cambios aplicados — Paso a paso

### Cambio 1: Se creó la carpeta `BOOTSTRAP/` (meta-infraestructura)

**¿Qué problema resuelve?** El pipeline necesita guardar un historial de todos los planes de Terraform que se aplicaron. Para eso se necesita una Storage Account en Azure. Pero hay un problema de "huevo y gallina": ¿cómo creás la Storage Account con Terraform si el pipeline que la usa todavía no existe?

**Solución**: `BOOTSTRAP/` es un proyecto Terraform separado que se ejecuta **una sola vez manualmente** desde tu máquina local. Crea:

- Un Resource Group `rg-tf-pipeline-meta`
- Una Storage Account `sttfplanhistory`
- Un contenedor `applied-plans` donde se guardan los planes

**¿Por qué está separado de `AZURE/`?** Porque es "meta-infraestructura": infraestructura que soporta al pipeline, no a la aplicación. Mantenerlos separados evita dependencias circulares.

**Cómo se ejecuta**:
```powershell
az login --tenant "TU_TENANT_ID" --use-device-code
az account set --subscription "TU_SUBSCRIPTION_ID"
cd BOOTSTRAP
terraform init
terraform apply
```

---

### Cambio 2: Se actualizó el provider de Terraform (3.90 → 4.70)

**¿Qué problema resuelve?** La versión `3.90.0` del provider `azurerm` no tiene soporte completo para Azure Container Apps. Faltan propiedades como `infrastructure_subnet_id` (necesaria para integrar Container Apps con la VNet).

**¿Qué se cambió?** En `AZURE/providers.tf`:

```hcl
# Antes
version = "~> 3.90.0"

# Ahora
version = "~> 4.70.0"
```

**¿Es seguro?** Sí. Los recursos que ya existían (Resource Group, VNet, subredes) no tienen cambios incompatibles entre la versión 3.90 y 4.70. El `terraform plan` lo confirma: 0 cambios en recursos existentes.

---

### Cambio 3: Se agregó Azure Container Apps a la infraestructura

**¿Qué problema resuelve?** La infraestructura original solo tenía la red (VNet y subredes). Faltaba el componente de cómputo para ejecutar aplicaciones.

**Recursos agregados en `AZURE/main.tf`**:

#### 3a. Subred para Container Apps
```hcl
resource "azurerm_subnet" "snet_containerapps" {
  address_prefixes = ["10.0.4.0/23"]   # /23 = 512 IPs (mínimo requerido)
  delegation {
    name    = "Microsoft.App/managedEnvironments"  # Permite que Container Apps use esta subred
  }
}
```
**¿Por qué `/23` y no `/24`?** Azure Container Apps requiere al menos 512 direcciones IP porque reserva una parte para su plano de control interno. Una `/24` (256 IPs) no es suficiente.

**¿Por qué una subred nueva?** No se puede reutilizar `snet-maquina-virtual` porque cada subred solo puede tener una delegación, y Container Apps necesita la suya propia.

#### 3b. Log Analytics Workspace
```hcl
resource "azurerm_log_analytics_workspace" "containerapps" {
  sku            = "PerGB2018"    # Pago por uso, sin costo fijo
  daily_quota_gb = 1              # Límite diario para evitar sorpresas en la factura
}
```
Container Apps **requiere** un Log Analytics Workspace para enviar logs y métricas. Sin esto, no se puede crear el Container App Environment.

#### 3c. Azure Container Registry (ACR)
```hcl
resource "azurerm_container_registry" "acr" {
  sku = "Basic"                   # ~$5/mes, el plan más económico
  retention_policy {
    days = 7                      # Borra imágenes viejas automáticamente
  }
}
```
El ACR es donde se almacenan las imágenes Docker. Es el equivalente a ECR en AWS. Sin un registro, no hay dónde guardar las imágenes que ejecuta Container Apps.

#### 3d. Container App Environment
```hcl
resource "azurerm_container_app_environment" "cae" {
  infrastructure_subnet_id = azurerm_subnet.snet_containerapps.id  # Integración con VNet
  zone_redundancy_enabled  = false   # Sin redundancia de zona (ahorra ~50%)
}
```
El Environment es el "cluster" donde viven las Container Apps. Al vincularlo a la subred, las apps heredan la red privada y pueden comunicarse con otros recursos en la VNet (como la futura base de datos PostgreSQL).

#### 3e. Container App
```hcl
resource "azurerm_container_app" "app" {
  revision_mode = "Single"
  template {
    container {
      image  = "nginx:alpine"     # Placeholder inicial
      cpu    = 0.25               # Mínimo posible
      memory = "0.5Gi"            # Mínimo posible
    }
    min_replicas = 0              # Escala a cero → $0 sin tráfico
    max_replicas = 1
  }
  ingress {
    external_enabled = true       # Accesible desde internet
    target_port      = 80
  }
}
```
La app corre `nginx` como placeholder. Después se reemplaza por la imagen real desde ACR. Con `min_replicas = 0`, si nadie la usa, no genera costo.

---

### Cambio 4: Se refactorizó el pipeline de GitHub Actions

**¿Qué problema resuelve?** El pipeline original tenía varios problemas:
- El Apply no usaba el plan generado (riesgo de aplicar algo distinto)
- No había validación de formato ni seguridad
- No había forma de destruir recursos desde GitHub
- El input de confirmación era confuso (texto libre en vez de dropdown)

**¿Qué se cambió?** El archivo `.github/workflows/azure-terraform.yml` se reescribió por completo.

#### 4a. De 2 jobs a 4 jobs

| Job | ¿Cuándo se ejecuta? | ¿Qué hace? |
|---|---|---|
| `Validate` | PR hacia `main` | `fmt` + `validate` + `trivy` (security scan) |
| `Plan` | Push a `main` o manual | Genera plan y lo guarda en Azure Storage (`pending-plans`) |
| `Apply` | Manual (`workflow_dispatch`) | Descarga el último plan de `pending-plans`, aplica, archiva en `applied-plans` |
| `Destroy` | Manual (`workflow_dispatch`) | Destruye toda la infraestructura |

#### 4b. Validaciones automáticas en cada PR

Cada PR ejecuta 3 validaciones antes de permitir el merge:

```
git checkout → azure login → terraform init
  → terraform fmt -check    ← ¿El código tiene formato correcto?
  → terraform validate      ← ¿La sintaxis es válida?
  → trivy (security scan)   ← ¿Hay configuraciones inseguras?
```

Si cualquiera falla, el pipeline se detiene y el PR muestra ❌.

#### 4c. El plan se guarda en Azure Storage (no en GitHub Artifacts)

```yaml
# Plan → guarda en pending-plans (TTL: 1 día)
az storage blob upload \
  --container-name pending-plans \
  --name "tfplan-20260720-143022.plan" \
  --file ./tfplan \
  --auth-mode login
```

**¿Por qué Azure Storage y no GitHub Artifacts?**
- GitHub Artifacts expiran y no son auditables fácilmente
- Azure Storage permite lifecycle policies (TTL automático)
- El historial queda en Azure, junto con la infraestructura
- RBAC granular: solo el Service Principal de GitHub puede leer/escribir

#### 4d. El Apply descarga el último plan de Azure

```yaml
# Apply → busca el plan más reciente en pending-plans
LATEST_BLOB=$(az storage blob list \
  --container-name pending-plans \
  --query "sort_by([], &properties.lastModified)[-1].name")

# Descarga y aplica
az storage blob download --name "${LATEST_BLOB}" --file ./tfplan
terraform apply tfplan
```

**¿Por qué es importante?** El Apply aplica **exactamente** el plan que se generó y revisó. No genera un plan nuevo al vuelo.

#### 4e. Post-apply: el plan se mueve a historial

```yaml
# Éxito → archivar en applied-plans (histórico permanente)
az storage blob upload --container-name applied-plans --name "tfplan-applied-20260720-150000.plan"
# Eliminar de pending-plans
az storage blob delete --container-name pending-plans --name "${PENDING_BLOB_NAME}"
```

Esto permite auditar qué se aplicó y cuándo. Si algo sale mal, se puede revisar el plan exacto que se ejecutó.

#### 4f. TTL de 1 día en planes pendientes

Los planes en `pending-plans` se eliminan automáticamente después de 1 día mediante una **lifecycle management policy** configurada en el BOOTSTRAP. Esto evita acumular planes viejos y fuerza a mantener el ciclo plan → apply ágil.

#### 4g. Mensaje de error claro si no hay plan

Si no hay planes en `pending-plans` (porque expiraron o nunca se generó uno):

```
============================================
  ❌ No hay planes pendientes
============================================
Ejecutá un push a main o un Plan manual para generar un plan.
```

#### 4h. Job de Destroy

```yaml
jobs:
  Destroy:
    if: github.event.inputs.accion == 'destroy'
    steps:
      - run: terraform destroy -auto-approve
```

Permite limpiar todos los recursos desde GitHub Actions.

---

### Cambio 5: Se creó `.gitignore`

**¿Qué problema resuelve?** Sin un `.gitignore`, Git intenta subir archivos que no deberían estar en el repositorio:
- `.terraform/` — binarios del provider (cientos de MB)
- `*.tfstate` — estado de Terraform (puede contener datos sensibles)
- `.terraform.lock.hcl` — lock file de providers

**¿Qué excluye?**
```gitignore
**/.terraform/
*.tfstate
*.tfstate.*
.terraform.lock.hcl
```

---

### Cambio 6: Hardening de seguridad en BOOTSTRAP

**¿Qué problema resuelve?** La Storage Account `sttfplanhistory` que guarda los planes del pipeline necesitaba controles de seguridad más estrictos para evitar que terceros pudieran leer o modificar los planes.

**¿Qué se cambió?**

#### 6a. Solo autenticación Azure AD (sin claves de acceso)

```hcl
resource "azurerm_storage_account" "plan_history" {
  shared_access_key_enabled = false   # Nadie puede usar la storage account key
}
```

**¿Por qué?** Las claves de acceso son un vector de ataque común. Al deshabilitarlas, toda autenticación debe pasar por Azure AD, donde se aplican políticas de RBAC.

#### 6b. RBAC granular: solo el pipeline puede leer/escribir blobs

```hcl
resource "azurerm_role_assignment" "github_sp_blob_contributor" {
  scope                = azurerm_storage_account.plan_history.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azuread_service_principal.github_actions.object_id
}
```

**¿Por qué?** El rol `Contributor` a nivel suscripción permite gestionar recursos pero **no** permite leer/escribir blobs (son planos distintos: management vs data). `Storage Blob Data Contributor` otorga acceso al data plane exclusivamente al Service Principal de GitHub Actions.

#### 6c. Lifecycle policy: TTL de 1 día en planes pendientes + tiering progresivo en applied-plans

La Storage Account tiene una política de ciclo de vida con dos reglas:

**Regla 1 — Planes pendientes**: se eliminan tras 1 día sin aplicar.

```hcl
rule {
  name    = "delete-pending-plans-after-1-day"
  filters  { prefix_match = ["pending-plans/"] }
  actions {
    base_blob { delete_after_days_since_modification_greater_than = 1 }
  }
}
```

**Regla 2 — Planes aplicados**: bajan de tier progresivamente para reducir costos.

```hcl
rule {
  name    = "tier-applied-plans-progressively"
  filters  { prefix_match = ["applied-plans/"] }
  actions {
    base_blob {
      tier_to_cool_after_days_since_modification_greater_than    = 3
      tier_to_cold_after_days_since_modification_greater_than    = 30
      tier_to_archive_after_days_since_modification_greater_than = 90
      delete_after_days_since_modification_greater_than           = 365
    }
  }
}
```

**¿Qué son los tiers de almacenamiento?** Azure Storage ofrece cuatro niveles de acceso, que se diferencian en costo de almacenamiento vs. costo y velocidad de recuperación:

| Tier | Costo almacenamiento | Costo recuperación | Velocidad |
|---|---|---|---|
| **Hot** (predeterminado) | Más alto | Gratis | Inmediata |
| **Cool** | Bajo (~50% menos) | Bajo | Minutos |
| **Cold** | Muy bajo (~80% menos) | Medio | Minutos |
| **Archive** | Mínimo (~95% menos) | Alto | Horas |

**¿Por qué esta progresión?**

| Período | Tier | Razón |
|---|---|---|
| Días 0-3 | 🔥 Hot | Recién aplicado, puede necesitarse para verificar el deployment |
| Días 3-30 | 💧 Cool | Siguen siendo recientes, pero el acceso es esporádico |
| Días 30-90 | ❄️ Cold | Solo se consultan si hay incidentes |
| Días 90-365 | 🗄️ Archive | Conservación por auditoría, recuperación lenta aceptable |
| Día 365+ | 🗑️ Borrar | Un año de historial es suficiente para cumplimiento |

**¿Cuánto ahorra?** Un plan típico ocupa ~1-2 MB. Si se generan 50 planes al año (~75-100 MB), tenerlos todos en Hot costaría ~$0.02/mes. Con tiering, baja a ~$0.001/mes. En este proyecto es un ahorro pequeño, pero es una buena práctica que escala a medida que crece el historial.

#### 6d. Provider upgrade a azurerm 4.x + azuread

```hcl
terraform {
  required_providers {
    azurerm = { version = "~> 4.70.0" }
    azuread = { version = "~> 2.53" }
  }
}
```

**¿Por qué?** `azurerm` 4.x es necesario para `storage_use_azuread = true` (operaciones de storage vía Azure AD). `azuread` se usa para resolver el Service Principal de GitHub por su `client_id` y así asignarle el rol RBAC.

#### 6e. Sin restricciones de red (confianza en RBAC)

Se eliminaron las `network_rules` con `default_action = "Deny"` porque los runners de GitHub Actions **no son considerados "Azure Services"** y eran bloqueados. La seguridad se mantiene vía RBAC: sin el rol `Storage Blob Data Contributor`, nadie puede leer/escribir blobs aunque la red esté abierta.

#### 6f. Nuevo container `pending-plans`

```hcl
resource "azurerm_storage_container" "pending_plans" {
  name = "pending-plans"
}
```

Separa los planes pendientes de aplicar (TTL 1 día) de los planes ya aplicados (`applied-plans`, histórico permanente).

---

### Cambio 7: Resource Provider auto-registration

**¿Qué problema resuelve?** Al ejecutar el Apply, fallaba con:

```
MissingSubscriptionRegistration: The subscription is not registered
to use namespace 'Microsoft.App'.
```

**¿Qué son los Resource Providers?** Cada servicio de Azure (VMs, Container Apps, etc.) pertenece a un "namespace" que debe estar registrado en la suscripción antes de usarse. Terraform, por defecto, solo registra un subconjunto mínimo (Compute, Network, Storage). `Microsoft.App` (Container Apps) no está en ese subconjunto.

**¿Qué se cambió?** En `AZURE/providers.tf`:

```hcl
provider "azurerm" {
  features {}
  resource_provider_registrations = "all"   # ← Registrar TODO lo necesario
}
```

**¿Por qué `"all"`?** Garantiza que cualquier recurso que se agregue en el futuro (Container Apps, PostgreSQL, Key Vault, etc.) tenga su provider registrado automáticamente. Alternativas más restrictivas:
- `"extended"` — cubre la mayoría de recursos comunes
- `"core"` — solo Compute, Network, Storage
- `"none"` — no registra nada (requiere registro manual)

---

### Cambio 8: Gestión de secretos con Azure Key Vault

**¿Qué problema resuelve?** Las aplicaciones (Container Apps, bases de datos, APIs) necesitan credenciales: contraseñas de base de datos, API keys, tokens de autenticación, etc. Almacenarlos en el repositorio (aunque sea en variables de entorno del pipeline) es inseguro:

- **En el repo**: cualquier persona con acceso al código los ve
- **En GitHub Secrets**: están cifrados pero no hay auditoría de quién los usó
- **En el código**: si alguien hace `git log`, puede encontrar secretos que se commitearon por error

**¿Qué es Azure Key Vault?** Es un servicio de Azure para almacenar secretos de forma segura, con:

- **Cifrado en reposo y en tránsito** — los secretos nunca viajan sin cifrar
- **Auditoría completa** — Azure registra quién leyó cada secreto y cuándo
- **Rotación programática** — se pueden rotar secretos sin cambiar el código
- **RBAC granular** — cada identidad tiene permisos específicos (lectura, escritura, etc.)

**¿Qué se creó?** En `BOOTSTRAP/main.tf`:

```hcl
resource "azurerm_key_vault" "infra" {
  name                = "kv-tf-pipeline-meta"
  resource_group_name = azurerm_resource_group.bootstrap_rg.name
  sku_name            = "standard"

  # Solo Azure AD auth (sin claves de acceso)
  enable_rbac_authorization = true
}
```

**¿Cómo se controla el acceso?**

| Identidad | Rol en el Key Vault | Puede hacer |
|---|---|---|
| SP de GitHub (pipeline) | `Key Vault Secrets User` | Leer secretos en tiempo de `apply` |
| Usuario local | `Key Vault Secrets Officer` | Crear, rotar y eliminar secretos |

**¿Cómo se usa en la práctica?**

1. **Agregar un secreto** (desde tu máquina):
   ```powershell
   az keyvault secret set --vault-name kv-tf-pipeline-meta --name "db-password" --value "MiPasswordSegura123!"
   ```

2. **Consumirlo desde Terraform** (en `AZURE/main.tf`):
   ```hcl
   data "azurerm_key_vault_secret" "db_password" {
     name         = "db-password"
     key_vault_id = azurerm_key_vault.infra.id
   }

   resource "azurerm_container_app" "app" {
     template {
       container {
         env {
           name  = "DB_PASSWORD"
           value = data.azurerm_key_vault_secret.db_password.value
         }
       }
     }
   }
   ```

3. El pipeline, al ejecutar `terraform apply`, obtiene el secreto directamente desde Azure Key Vault. **El secreto nunca está en el repositorio ni en los logs del pipeline.**

**¿Por qué usar Key Vault y no GitHub Secrets?** Ambos son válidos, pero Key Vault ofrece ventajas adicionales:

| Aspecto | GitHub Secrets | Azure Key Vault |
|---|---|---|
| Rotación de secretos | Manual, requiere editar en GitHub | Programática, sin tocar el pipeline |
| Auditoría | Quién ejecutó el workflow | Quién leyó cada secreto y cuándo |
| Límite de tamaño | 64 KB por secret | Ilimitado |
| Consumo desde Terraform | Solo como env var | Data source nativo |
| Compatibilidad multi-servicio | Solo GitHub | Azure, APIs, apps, etc. |

**¿Dónde se creó?** En el BOOTSTRAP (`rg-tf-pipeline-meta`), porque es un servicio de meta-infraestructura compartido que pueden consumir tanto `AZURE/` como futuros proyectos.

---

## Resumen visual de los cambios

```
┌─────────────────────────────────────────────────────────────┐
│                      ANTES                                  │
│                                                             │
│  rg-req-felipe                                              │
│  └── vnet-aislada                                           │
│      ├── snet-maquina-virtual (vacía)                       │
│      └── snet-base-datos (vacía)                            │
│                                                             │
│  Pipeline: 2 jobs, sin validación, sin seguridad            │
└─────────────────────────────────────────────────────────────┘

                              ▼

┌─────────────────────────────────────────────────────────────┐
│                      AHORA                                  │
│                                                             │
│  rg-req-felipe                                              │
│  └── vnet-aislada                                           │
│      ├── snet-maquina-virtual (reservada)                   │
│      ├── snet-base-datos (reservada para PostgreSQL)        │
│      └── snet-container-apps (Container Apps)               │
│  ├── law-containerapps (monitoreo)                          │
│  ├── crtfconfelipe (registro de imágenes)                   │
│  ├── cae-felipe (entorno de containers)                     │
│  └── ca-felipe-app (nginx, escala a cero)                   │
│                                                             │
│  rg-tf-pipeline-meta (bootstrap)                            │
│  └── sttfplanhistory                                        │
│      ├── pending-plans (TTL 1 día, planes por aplicar)      │
│      └── applied-plans (histórico permanente)               │
│  └── kv-tf-pipeline-meta (secretos cifrados)                │
│                                                             │
│  Pipeline: 4 jobs, Validate (PR) → Plan (push/main)         │
│            → Apply (manual) → Destroy (manual)              │
│            Plan/Apply vía Azure Storage (no artifacts)      │
│            RBAC + Azure AD auth (sin claves de acceso)      │
│            Secretos vía Key Vault (nunca en el repo)        │
└─────────────────────────────────────────────────────────────┘
```

---

## Costo estimado

| Recurso | Costo mensual |
|---|---|
| Azure Container Registry (Basic) | ~$5.00 |
| Container App (escala a cero) | ~$0-5.00 |
| Log Analytics (1 GB/día) | ~$0-2.00 |
| Virtual Network + Subnets | $0 (gratis) |
| Storage Account + Lifecycle Management (bootstrap) | ~$0.10 |
| **Total** | **~$5-7/mes** |

---

## Prerrequisitos para usar este proyecto

### 1. Bootstrap (ejecutar UNA sola vez)

```powershell
az login --tenant "TU_TENANT_ID" --use-device-code
az account set --subscription "TU_SUBSCRIPTION_ID"
cd BOOTSTRAP
terraform init
terraform apply
```

### 2. Secrets de GitHub

| Secret | Valor |
|---|---|
| `AZURE_CLIENT_ID` | Client ID del Service Principal (OIDC) |
| `AZURE_SUBSCRIPTION_ID` | ID de la suscripción |
| `AZURE_TENANT_ID` | Tenant ID de Azure AD |
| `AZURE_STORAGE_ACCOUNT_NAME` | `sttfplanhistory` (output del bootstrap) |
| `AZURE_STORAGE_CONTAINER_PENDING_NAME` | `pending-plans` (output del bootstrap) |
| `AZURE_STORAGE_CONTAINER_APPLIED_NAME` | `applied-plans` (output del bootstrap) |

### 3. Resource Providers

El pipeline registra automáticamente los Resource Providers necesarios (`resource_provider_registrations = "all"`). Si ejecutás Terraform localmente, asegurate de que `Microsoft.App` esté registrado:

```powershell
az provider register --namespace Microsoft.App
```

---

## Herramientas de desarrollo con Docker

El proyecto incluye un `docker-compose.yml` para ejecutar herramientas de análisis sin instalarlas en tu PC.

### Trivy (seguridad de infraestructura)

```yaml
services:
  trivy-scan:
    image: aquasec/trivy:latest
    volumes:
      - .:/workspace
    command: config /workspace/AZURE /workspace/BOOTSTRAP
```

**Uso**:

```powershell
# Escanear ambos directorios (AZURE y BOOTSTRAP)
docker compose run --rm trivy-scan

# Solo AZURE/
docker compose run --rm trivy-scan-azure

# Solo BOOTSTRAP/
docker compose run --rm trivy-scan-bootstrap
```

### Ignorar falsos positivos (`.trivyignore`)

Trivy detecta `AZU-0012` (Storage Account sin `network_rules`) como CRITICAL. Esto es **intencional** en nuestro caso:

- Los runners de GitHub Actions no son Azure Services y serían bloqueados por `network_rules`
- La seguridad se mantiene con `shared_access_key_enabled = false` + RBAC (`Storage Blob Data Contributor`)

El archivo `.trivyignore` excluye este check:

```
# Ignorar AZU-0012: decisión deliberada (ver README Cambio 6e)
AZU-0012
```

Para probar que Trivy respeta el ignore:

```powershell
docker compose run --rm trivy-scan
# → Debería mostrar 0 failures
```

---

## Uso del pipeline

### Flujo completo

```
PR abierto ──→ Validate (fmt + validate + trivy)
                                          ↓
                              Si falla → ❌ no mergear
                              Si pasa → ✅ mergear a main
                                          ↓
PR mergeado ──→ Push a main ──→ Plan ──→ guarda en pending-plans (TTL 1d)
                                          ↓
                              workflow_dispatch "apply"
                                          ↓
                              Apply ──→ descarga último plan de pending-plans
                                    ──→ terraform apply tfplan
                                    ──→ archiva en applied-plans
                                    ──→ borra de pending-plans
```

### Ejecutar un Plan

**Automático**: Crear un PR hacia `main` que modifique archivos en `AZURE/`. Al mergear, el Plan se ejecuta y guarda el resultado en Azure Storage.

**Manual**: **Actions → Run workflow → `accion: plan`**

### Ejecutar un Apply

**Actions → Run workflow → `accion: apply`** → Descarga el último plan de `pending-plans` y lo aplica.

> ⚠️ Si pasaron más de 24 horas desde el Plan: el plan se eliminó por TTL. Volvé a ejecutar Plan primero.

### Ejecutar un Destroy

**Actions → Run workflow → `accion: destroy`** → Destruye todos los recursos.

---

## Historial de planes

```powershell
az storage blob list \
  --account-name sttfplanhistory \
  --container-name applied-plans \
  --prefix plans/ \
  --auth-mode login \
  --output table
```
