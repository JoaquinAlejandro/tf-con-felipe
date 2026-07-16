resource "azurerm_resource_group" "rg_basico" {
  name     = "rg-contenedores-ejercicio"
  location = "eastus"
}

resource "azurerm_container_group" "aci_basico" {
  name                = "contenedor-nginx-barato"
  location            = azurerm_resource_group.rg_basico.location
  resource_group_name = azurerm_resource_group.rg_basico.name
  ip_address_type     = "Public"
  os_type             = "Linux"

  container {
    name   = "web-server"
    image  = "nginx:alpine"
    cpu    = "0.5"
    memory = "0.5"

    ports {
      port     = 80
      protocol = "TCP"
    }
  }
}