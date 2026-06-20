# Tutorial: Automatización de Encendido y Apagar de VMs desde Azure Data Factory

Este tutorial está dirigido a **Ingenieros de Datos** que deseen implementar una solución robusta, parametrizada y segura para controlar el encendido y apagado (desasignación) de máquinas virtuales en Azure desde Azure Data Factory (ADF). 

La solución está diseñada bajo el estándar de **Mínimo Privilegio (Least Privilege)** y utiliza identidades administradas para no almacenar credenciales.

---

## 🏗️ Flujo de Arquitectura y Componentes

```mermaid
graph TD
    subgraph Azure Data Factory (ADF)
        Pipe[Pipeline Orquestador] -->|Execute| StartPipe[Pipeline: Pipeline_Encender_VM]
        Pipe -->|Execute| StopPipe[Pipeline: Pipeline_Apagar_VM]
        StartPipe -->|Usa| Cred[Credencial: Credencial_Control_VM]
        StopPipe -->|Usa| Cred
    end
    
    subgraph Control de Acceso (IAM)
        Cred -->|Asociado a| UAMI[User-Assigned Managed Identity]
        UAMI -->|Rol Custom: VM Power Controller| RBAC[Asignación de Rol sobre VM]
    end

    subgraph Cómputo (IaaS)
        RBAC -->|Ejecuta /start o /deallocate| VM[Máquina Virtual]
    end
```

---

## 📋 Requisitos Previos

*   Tener instalado y configurado **Azure CLI** (v2.30+).
*   Estar autenticado en tu suscripción mediante `az login`.

---

## 💻 Paso a Paso con Comandos de Azure CLI

A continuación, se detallan los comandos de Azure CLI en PowerShell para crear el entorno de pruebas completo.

### 1. Definición de Variables
Define las variables globales en tu terminal de PowerShell para facilitar la reutilización de los comandos, usando convenciones estandarizadas:

```powershell
$subscriptionId = "<YOUR_SUBSCRIPTION_ID>"
$resourceGroupName = "rg-computelab-prod-eastus2"
$location = "eastus2"
$vmName = "vm-datalab-prod-eastus2"
$identityName = "id-adf-vm-controller-prod"
$adfName = "adf-datalab-prod-eastus" # Debe ser un nombre globalmente único
$adfResourceGroupName = "rg-datalab-prod-eastus"
$adfLocation = "eastus"
```

Establece la suscripción activa:
```powershell
az account set --subscription $subscriptionId
```

---

### 2. Creación de los Grupos de Recursos
Crea los contenedores lógicos para tus recursos de datos y cómputo de manera organizada:

```powershell
# Grupo de recursos para los servicios de datos (ADF)
az group create --name $adfResourceGroupName --location $adfLocation

# Grupo de recursos para los servicios de cómputo (VM, Redes)
az group create --name $resourceGroupName --location $location
```

---

### 3. Creación de la Identidad Administrada Asignada por el Usuario
Crea la identidad de seguridad que servirá de puente entre el Data Factory y la máquina virtual:

```powershell
$identity = az identity create --name $identityName --resource-group $resourceGroupName | ConvertFrom-Json
$identityPrincipalId = $identity.principalId
$identityResourceId = $identity.id
```

---

### 4. Creación del Rol Personalizado (Mínimo Privilegio)
Crea una plantilla JSON para el rol personalizado. Esto garantiza que la identidad de ADF no pueda borrar, editar ni ver recursos ajenos a su función de control de energía.

Crea el archivo `custom-role-vm-controller.json` con el siguiente contenido:
```json
{
    "Name": "Virtual Machine Power Controller (ADF)",
    "IsCustom": true,
    "Description": "Permite unicamente encender, apagar (deallocate) y leer el estado de una maquina virtual.",
    "Actions": [
        "Microsoft.Compute/virtualMachines/read",
        "Microsoft.Compute/virtualMachines/start/action",
        "Microsoft.Compute/virtualMachines/deallocate/action"
    ],
    "AssignableScopes": [
        "/subscriptions/<YOUR_SUBSCRIPTION_ID>"
    ]
}
```

Crea el rol en Azure:
```powershell
az role definition create --role-definition "custom-role-vm-controller.json"
```

---

### 5. Creación de la Máquina Virtual (VM) de Destino
Crea una máquina virtual Linux simple para pruebas:

```powershell
az vm create \
  --resource-group $resourceGroupName \
  --name $vmName \
  --location $location \
  --image Ubuntu2204 \
  --admin-username azureuser \
  --generate-ssh-keys \
  --public-ip-sku Standard
```

Obtén el ID de recurso de la máquina virtual recién creada:
```powershell
$vmResourceId = az vm show --name $vmName --resource-group $resourceGroupName --query "id" --output tsv
```

---

### 6. Asignación del Rol Personalizado a la Identidad
Asigna el nuevo rol personalizado a la identidad de usuario en el ámbito específico de tu máquina virtual:

```powershell
az role assignment create \
  --assignee $identityPrincipalId \
  --role "Virtual Machine Power Controller (ADF)" \
  --scope $vmResourceId
```

---

### 7. Creación de Azure Data Factory (ADF)
Crea tu factoría de datos:

```powershell
az datafactory create --resource-group $adfResourceGroupName --name $adfName --location $adfLocation
```

---

### 8. Vinculación de la Identidad de Usuario con ADF
Para que tu Data Factory pueda firmar peticiones utilizando la identidad de usuario creada, debes asociarla a la configuración de ADF:

```powershell
# En PowerShell, usamos el operador de stop-parsing '--%' para evitar que se interprete el JSON de Azure CLI
az resource update \
  --ids "/subscriptions/$subscriptionId/resourceGroups/$adfResourceGroupName/providers/Microsoft.DataFactory/factories/$adfName" \
  --api-version "2018-06-01" \
  --set --% identity.type="SystemAssigned,UserAssigned" identity.userAssignedIdentities="{\"$identityResourceId\":{}}"
```

---

### 9. Creación de la Credencial en Azure Data Factory
Para usar la identidad en los pipelines, se debe registrar como una Credencial dentro de la configuración interna de ADF:

```powershell
az resource create \
  --api-version "2018-06-01" \
  --id "/subscriptions/$subscriptionId/resourceGroups/$adfResourceGroupName/providers/Microsoft.DataFactory/factories/$adfName/credentials/Credencial_Control_VM" \
  --properties --% "{\"type\":\"ManagedIdentity\",\"typeProperties\":{\"resourceId\":\"$identityResourceId\"}}"
```

---

## ⚙️ Estructura y Despliegue de Pipelines Paramétricos

Para lograr una reutilización óptima, creamos dos pipelines parametrizados. Las actividades Web concatenan dinámicamente la URL utilizando parámetros de entrada.

### A. Pipeline de Encendido (`Pipeline_Encender_VM`)
*   *Definición JSON en local:* [pipeline-start-vm.json](./pipeline-start-vm.json)
*   **Parámetros:** `SubscriptionId`, `ResourceGroup`, `VMName`.
*   **Actividad Web URL Dinámica:**
    ```json
    @concat('https://management.azure.com/subscriptions/', pipeline().parameters.SubscriptionId, '/resourceGroups/', pipeline().parameters.ResourceGroup, '/providers/Microsoft.Compute/virtualMachines/', pipeline().parameters.VMName, '/start?api-version=2021-11-01')
    ```

Despliega el pipeline en ADF:
```powershell
az datafactory pipeline create \
  --factory-name $adfName \
  --name "Pipeline_Encender_VM" \
  --resource-group $adfResourceGroupName \
  --pipeline "pipeline-start-vm.json"
```

---

### B. Pipeline de Apagado (`Pipeline_Apagar_VM`)
*   *Definición JSON en local:* [pipeline-stop-vm.json](./pipeline-stop-vm.json)
*   **Actividad Web URL Dinámica:**
    ```json
    @concat('https://management.azure.com/subscriptions/', pipeline().parameters.SubscriptionId, '/resourceGroups/', pipeline().parameters.ResourceGroup, '/providers/Microsoft.Compute/virtualMachines/', pipeline().parameters.VMName, '/deallocate?api-version=2021-11-01')
    ```

Despliega el pipeline en ADF:
```powershell
az datafactory pipeline create \
  --factory-name $adfName \
  --name "Pipeline_Apagar_VM" \
  --resource-group $adfResourceGroupName \
  --pipeline "pipeline-stop-vm.json"
```

---

## 📈 Buenas Prácticas de Orquestación y Optimización de Costos

Como Ingeniero de Datos, tu objetivo principal al orquestar cargas es la **resiliencia** y la **eficiencia de costos**:

1.  **¿Por qué usar `deallocate` en lugar de `powerOff`?**
    La API REST `/deallocate` apaga la máquina virtual y libera la asignación del hardware físico en los datacenters de Azure. Esto detiene inmediatamente la facturación de los recursos de cómputo (vCPU y RAM). Utilizar `/powerOff` solo apaga el sistema operativo pero mantiene la VM reservada, lo que significa que Azure continuará cobrándote por ella.
2.  **Actividad de Espera (Wait Activity):**
    El comando `/start` responde con un estado de éxito HTTP `202 Accepted` de forma asíncrona (significa "Petición aceptada, iniciando proceso"). El arranque de la máquina toma de **1 a 3 minutos**. Añade siempre una actividad **Wait** en tu pipeline principal configurada a **120 segundos** tras el encendido para evitar fallos de conexión en tus siguientes actividades de datos.
3.  **Mecanismo Fail-Safe (Apagado Seguro):**
    Asegúrate de ejecutar la actividad de apagado (`Pipeline_Apagar_VM`) utilizando el enlace de flujo **"Upon Completion"** (el conector azul en ADF Studio). Esto garantiza que la máquina se apagará tanto si tus flujos de procesamiento finalizaron con éxito como si fallaron. De lo contrario, una falla a mitad de la noche podría dejar la máquina virtual encendida durante todo el fin de semana, disparando los costos.
