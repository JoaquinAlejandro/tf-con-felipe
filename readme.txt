# tf-con-felipe — Infraestructura Azure con Terraform

Proyecto de infraestructura como código (IaC) para desplegar recursos en Azure usando Terraform y GitHub Actions.

---

## Estructura del proyecto

```
tf-con-felipe/
├── BOOTSTRAP/                    # Meta-infraestructura (se ejecuta UNA vez)
│   ├── main.tf                   # Storage Account para historial de planes
│   └── providers.tf
├── AZURE/                        # Infraestructura principal
│   ├── main.tf                   # VNet, subredes, Container Apps, ACR
│   └── providers.tf              # azurerm ~> 4.70.0
└── .github/workflows/
    └── azure-terraform.yml       # Pipeline CI/CD
```

---

## Prerrequisitos

### 1. Bootstrap (ejecutar UNA sola vez)

La carpeta `BOOTSTRAP/` crea la Storage Account donde se guarda el historial de planes aplicados. Se ejecuta manualmente desde tu máquina local.

```powershell
# 1. Autenticarse en Azure
az login
az account set --subscription "TU_SUBSCRIPTION_ID"

# 2. Ejecutar el bootstrap
cd BOOTSTRAP
terraform init
terraform apply

# 3. Copiar los outputs y agregarlos como secrets en GitHub:
#    - AZURE_STORAGE_ACCOUNT_NAME
#    - AZURE_STORAGE_CONTAINER_NAME
```

### 2. Secrets de GitHub

Agregar estos secrets en **Settings → Secrets and variables → Actions**:

| Secret | Descripción |
|---|---|
| `AZURE_CLIENT_ID` | Client ID del Service Principal (OIDC) |
| `AZURE_SUBSCRIPTION_ID` | ID de la suscripción de Azure |
| `AZURE_TENANT_ID` | Tenant ID de Azure AD |
| `AZURE_STORAGE_ACCOUNT_NAME` | Nombre de la Storage Account (output del bootstrap) |
| `AZURE_STORAGE_CONTAINER_NAME` | Nombre del contenedor (output del bootstrap) |

### 3. Environment "production"

En **Settings → Environments**, crear un environment llamado `production` y configurar:

- **Required reviewers**: agregar al menos un revisor
- Esto protege los jobs de Apply y Destroy con aprobación manual

---

## Uso del pipeline

### Flujo completo

```
PR → Plan (automático) → Apply (manual + aprobación) → Destroy (manual + aprobación)
```

### Ejecutar un Plan

1. Crear un **Pull Request** hacia `main` que modifique archivos en `AZURE/`
2. El pipeline ejecuta automáticamente: `fmt` → `validate` → `tfsec` → `plan`
3. El plan se publica como comentario en el PR
4. El artefacto del plan se guarda por **1 día**

### Ejecutar un Apply

1. Ir a **Actions** → **Terraform Azure OIDC CI/CD** → **Run workflow**
2. Seleccionar `accion: apply`
3. Un revisor debe **aprobar** el deployment en el environment `production`
4. El pipeline descarga el plan, lo aplica, y guarda una copia en Azure Storage

> ⚠️ Si pasaron más de 24 horas desde el Plan, el Apply fallará con el mensaje:
> **"No hay plan, volver a ejecutar Plan"**. Volvé a crear un PR para generar un plan nuevo.

### Ejecutar un Destroy

1. Ir a **Actions** → **Terraform Azure OIDC CI/CD** → **Run workflow**
2. Seleccionar `accion: destroy`
3. Un revisor debe **aprobar** la destrucción en el environment `production`

---

## Historial de planes

Cada plan aplicado se guarda en Azure Storage:

```
Container: applied-plans
  └── plans/
      ├── tfplan-20260717-143022-abc1234.plan
      ├── tfplan-20260718-091500-def5678.plan
      └── ...
```

Para listar el historial:

```powershell
az storage blob list \
  --account-name sttfplanhistory \
  --container-name applied-plans \
  --prefix plans/ \
  --auth-mode login \
  --output table
```

---

## Validaciones del pipeline

| Paso | Descripción |
|---|---|
| `terraform fmt -check` | Verifica formato consistente |
| `terraform validate` | Valida sintaxis y referencias |
| `tfsec` | Escaneo de seguridad (detecta configs inseguras) |
| `terraform plan` | Genera el plan de cambios |

---

## Recursos creados (AZURE/)

| Recurso | Nombre | Detalle |
|---|---|---|
| Resource Group | `rg-req-felipe` | eastus |
| Virtual Network | `vnet-aislada` | 10.0.0.0/16 |
| Subnet VM | `snet-maquina-virtual` | 10.0.1.0/24 |
| Subnet DB | `snet-base-datos` | 10.0.2.0/24 (delegación PostgreSQL) |
| Subnet Container Apps | `snet-container-apps` | 10.0.4.0/23 (delegación Microsoft.App) |
| Log Analytics | `law-containerapps` | PerGB2018, 30 días, cuota 1 GB/día |
| Container Registry | `crtfconfelipe` | SKU Basic (~$5/mes), retención 7 días |
| Container App Env | `cae-felipe` | Consumption-only, sin zone redundancy |
| Container App | `ca-felipe-app` | nginx:alpine, escala a cero, 0.25 CPU / 0.5 GiB |

### Optimización de costos

| Recurso | Estrategia | Costo estimado |
|---|---|---|
| Container App | `min_replicas = 0`, CPU 0.25, Memory 0.5Gi | $0 sin tráfico |
| Container App Env | Consumption-only (sin workload profiles) | Sin costo fijo |
| ACR | SKU Basic, sin geo-replicación | ~$5/mes |
| Log Analytics | PerGB2018, daily_quota_gb = 1 | ~$0-2/mes |
| **Total estimado** | | **~$5-7/mes** |

---

## Recursos creados (BOOTSTRAP/)

| Recurso | Nombre | Detalle |
|---|---|---|
| Resource Group | `rg-tf-pipeline-meta` | eastus |
| Storage Account | `sttfplanhistory` | LRS, TLS 1.2 |
| Container | `applied-plans` | Acceso privado |