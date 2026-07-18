# tf-con-felipe — Infraestructura Azure con Terraform

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
    └── ca-felipe-app                        ← Container App (nginx)
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
├── BOOTSTRAP/                    # Meta-infraestructura (se ejecuta UNA vez, levanta infraestructura)
│   ├── main.tf                   # Storage Account para historial de planes
│   └── providers.tf
├── AZURE/                        # Infraestructura principal
│   ├── main.tf                   # VNet, subredes, Container Apps, ACR
│   └── providers.tf              # azurerm ~> 4.70.0
├── .github/workflows/
│   └── azure-terraform.yml       # Pipeline CI/CD
├── .gitignore                    # Excluye archivos de estado de Terraform
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

#### 4a. De 2 jobs a 3 jobs

| Antes | Ahora | ¿Cuándo se ejecuta? |
|---|---|---|
| `terraform-plan` | `Plan` | Automático en cada PR |
| `terraform-apply` | `Apply` | Manual (workflow_dispatch) |
| _(no existía)_ | `Destroy` | Manual (workflow_dispatch) |

#### 4b. Validaciones automáticas en el Plan

Cada PR ahora ejecuta 4 validaciones antes de generar el plan:

```
git checkout → azure login → terraform init
  → terraform fmt -check    ← ¿El código tiene formato correcto?
  → terraform validate      ← ¿La sintaxis es válida?
  → tfsec                   ← ¿Hay configuraciones inseguras?
  → terraform plan          ← ¿Qué recursos se van a crear/modificar/destruir?
```

Si cualquiera de los primeros tres falla, el pipeline se detiene y el PR no se puede mergear.

#### 4c. El plan se publica como comentario en el PR

Usando `actions/github-script@v7`, el output del plan aparece directamente en el PR. Ya no hace falta entrar a Actions para ver qué va a cambiar.

#### 4d. El artefacto del plan expira en 1 día

```yaml
- uses: actions/upload-artifact@v4
  with:
    retention-days: 1    # Fuerza a aplicar el plan el mismo día
```

**¿Por qué?** Si pasa más de un día, el entorno de Azure pudo haber cambiado y el plan ya no es válido. Esto obliga a mantener el ciclo plan → apply ágil.

#### 4e. El Apply reutiliza el plan (no genera uno nuevo)

```yaml
# Antes (riesgoso):
- run: terraform apply -auto-approve    # Genera un plan NUEVO al vuelo

# Ahora (seguro):
- uses: actions/download-artifact@v4    # Descarga el plan generado en el PR
- run: terraform apply tfplan           # Aplica EXACTAMENTE ese plan
```

**¿Por qué es importante?** Si el Apply genera un plan nuevo, podría aplicar cambios diferentes a los que se revisaron en el PR. Al reutilizar el plan, hay certeza de que se aplica exactamente lo que se aprobó.

#### 4f. Mensaje de error claro si no hay plan

Si el artefacto expiró (más de 1 día) o nunca se generó, el pipeline muestra:

```
============================================
  No hay plan, volver a ejecutar Plan
============================================
```

En vez de un error genérico de GitHub que no explica qué pasó.

#### 4g. Aprobación manual con GitHub Environments

```yaml
jobs:
  Apply:
    environment: production    # Pausa el pipeline hasta que un revisor apruebe
```

Esto se configura en **Settings → Environments → production → Required reviewers**. Sin esta protección, cualquiera con acceso al repo podría hacer `apply` o `destroy`.

#### 4h. Historial de planes en Azure Storage

Después de cada apply exitoso, el plan se guarda en la Storage Account del bootstrap:

```
applied-plans/plans/
  ├── tfplan-20260717-143022-abc1234.plan
  ├── tfplan-20260718-091500-def5678.plan
  └── ...
```

Esto permite auditar qué se aplicó y cuándo. Si algo sale mal, se puede revisar el plan exacto que se ejecutó.

#### 4i. Job de Destroy

```yaml
jobs:
  Destroy:
    if: github.event.inputs.accion == 'destroy'
    environment: production
    steps:
      - run: terraform destroy -auto-approve
```

Permite limpiar todos los recursos desde GitHub, con la misma protección de aprobación manual.

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
│  └── sttfplanhistory / applied-plans (historial)            │
│                                                             │
│  Pipeline: 3 jobs, fmt+validate+tfsec,                       │
│            plan en PR, apply con aprobación,                 │
│            destroy, historial en Azure                       │
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
| Storage Account (bootstrap) | ~$0.10 |
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
| `AZURE_STORAGE_CONTAINER_NAME` | `applied-plans` (output del bootstrap) |

### 3. Environment "production"

**Settings → Environments → production** → Required reviewers: agregar al menos uno.

---

## Uso del pipeline

### Ejecutar un Plan (automático)

Crear un PR hacia `main` que modifique archivos en `AZURE/`. El pipeline ejecuta `fmt → validate → tfsec → plan` y publica el resultado como comentario.

### Ejecutar un Apply (manual)

**Actions → Run workflow → `accion: apply`** → Un revisor aprueba → Se aplica el plan.

> ⚠️ Si pasaron más de 24 horas: **"No hay plan, volver a ejecutar Plan"**.

### Ejecutar un Destroy (manual)

**Actions → Run workflow → `accion: destroy`** → Un revisor aprueba → Se destruyen todos los recursos.

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
