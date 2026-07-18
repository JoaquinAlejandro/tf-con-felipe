# Seguridad — Modificaciones aplicadas

Este documento detalla las modificaciones de seguridad aplicadas al proyecto `tf-con-felipe`, detectadas y corregidas durante el desarrollo del pipeline CI/CD.

---

## 1. Storage Account sin restricciones de red (CRITICAL)

### Hallazgo

Trivy detectó la violación **AZU-0012** en `BOOTSTRAP/main.tf`:

```
No network rules defined and default action allows access.
The default_action for network rules should come into effect when no other rules are matched.
The default action should be set to Deny.
```

La Storage Account `sttfplanhistory` permitía acceso desde **cualquier dirección IP pública** por no tener `network_rules` configuradas.

### Fix aplicado

```hcl
resource "azurerm_storage_account" "plan_history" {
  # ... resto de la config ...
  network_rules {
    default_action = "Deny"           # Bloquea todo el tráfico público
    bypass         = ["AzureServices"]  # Permite acceso solo a servicios Azure autenticados
  }
}
```

### ¿Qué cambió?

| Antes | Después |
|---|---|
| Sin `network_rules` → acceso público | `default_action = "Deny"` → acceso denegado por defecto |
| Cualquier IP podía intentar acceder | Solo servicios Azure autenticados (OIDC) pueden acceder |

### ¿Por qué `bypass = ["AzureServices"]`?

El pipeline de GitHub Actions se autentica contra Azure usando OIDC (OpenID Connect). Azure Services incluye las identidades administradas y el login OIDC, permitiendo que el pipeline siga subiendo planes al contenedor sin exponer la cuenta a internet.

---

## 2. Deprecación de tfsec → migración a Trivy

### Hallazgo

El pipeline usaba `aquasecurity/tfsec-action@v1` para el escaneo de seguridad, pero:

1. La GitHub Action `tfsec-action@v1` fue eliminada del marketplace
2. El binario de `tfsec` ya no se puede descargar (el proyecto fue absorbido por Trivy)
3. El pipeline fallaba con: `Error: Unable to resolve action aquasecurity/tfsec-action@v1`

### Fix aplicado

Se reemplazó `tfsec` por `trivy` (su sucesor oficial de Aqua Security) en los 2 jobs que lo usaban:

```yaml
# Antes (roto):
- name: Security Scan (tfsec)
  run: |
    curl -s https://raw.githubusercontent.com/aquasecurity/tfsec/master/scripts/install_linux.sh | bash
    tfsec .

# Ahora (funciona):
- name: Security Scan (Trivy)
  uses: aquasecurity/trivy-action@master
  with:
    scan-type: 'config'
    scan-ref: '.'
    exit-code: '1'
    severity: 'CRITICAL,HIGH'
```

### ¿Qué cambió?

| Aspecto | tfsec | Trivy |
|---|---|---|
| Estado | Deprecado (no se puede descargar) | Activo y mantenido |
| Instalación | Script manual (`curl \| bash`) | GitHub Action oficial |
| Cobertura | Solo Terraform | Terraform, Docker, K8s, CloudFormation, etc. |
| Severidad | Sin filtro | Configurable (`CRITICAL,HIGH` evita falsos positivos) |

---

## 3. Actualización de versiones de Actions (Node 20 → Node 24)

### Hallazgo

GitHub Actions comenzó a deprecar Node 20. Las siguientes actions mostraban warnings:

| Action | Versión anterior | Problema |
|---|---|---|
| `azure/login@v1` | Node 20 | Deprecado |
| `hashicorp/setup-terraform@v2` | Node 20 | Deprecado |

### Fix aplicado

```yaml
# Antes:
uses: azure/login@v1
uses: hashicorp/setup-terraform@v2

# Ahora:
uses: azure/login@v2
uses: hashicorp/setup-terraform@v3
```

---

## 4. Resumen de cambios de seguridad

| Archivo | Cambio | Severidad |
|---|---|---|
| `BOOTSTRAP/main.tf` | Agregar `network_rules` con `default_action = "Deny"` | 🔴 CRITICAL |
| `.github/workflows/azure-terraform.yml` | Reemplazar `tfsec` por `trivy` | 🟡 MEDIA |
| `.github/workflows/azure-terraform.yml` | Upgrade `azure/login@v1` → `@v2` | 🟢 BAJA |
| `.github/workflows/azure-terraform.yml` | Upgrade `setup-terraform@v2` → `@v3` | 🟢 BAJA |

---

## 5. Recomendaciones futuras

- [ ] Revisar periódicamente las reglas de Trivy para nuevas vulnerabilidades
- [ ] Considerar agregar reglas de firewall en la Storage Account del bootstrap (actualmente solo `network_rules`)
- [ ] Evaluar si el ACR (`crtfconfelipe`) necesita `network_rules` similares
- [ ] Mantener actualizadas las GitHub Actions (revisar deprecaciones de Node cada release)
