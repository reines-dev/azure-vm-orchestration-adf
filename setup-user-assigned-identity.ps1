# Script para crear una Identidad Administrada Asignada por el Usuario (User-Assigned Managed Identity),
# asignarle permisos sobre la Máquina Virtual y asociarla a Azure Data Factory.

$subscriptionId = "<YOUR_SUBSCRIPTION_ID>"
$resourceGroupName = "rg-computelab-prod-eastus2" 
$vmName = "vm-datalab-prod-eastus2"
$adfName = "adf-datalab-prod-eastus"
$adfResourceGroupName = "rg-datalab-prod-eastus"
$identityName = "id-adf-vm-controller-prod"

Write-Host "1. Conectando a Azure..." -ForegroundColor Cyan
az account set --subscription $subscriptionId

Write-Host "2. Creando la Identidad Administrada Asignada por el Usuario ($identityName)..." -ForegroundColor Cyan
$identity = az identity create --name $identityName --resource-group $resourceGroupName | ConvertFrom-Json

$identityPrincipalId = $identity.principalId
$identityClientId = $identity.clientId
$identityResourceId = $identity.id

Write-Host "Identidad Creada:" -ForegroundColor Green
Write-Host " - Resource ID: $identityResourceId"
Write-Host " - Principal ID: $identityPrincipalId"
Write-Host " - Client ID: $identityClientId"

Write-Host "3. Obteniendo el ID de recurso de la VM ($vmName)..." -ForegroundColor Cyan
$vmResourceId = az vm show --name $vmName --resource-group $resourceGroupName --query "id" --output tsv

Write-Host "4. Asignando el rol personalizado 'Virtual Machine Power Controller (ADF)' a la Identidad Administrada..." -ForegroundColor Cyan
az role assignment create --assignee $identityPrincipalId --role "Virtual Machine Power Controller (ADF)" --scope $vmResourceId

Write-Host "5. Asociando la Identidad Administrada al Azure Data Factory ($adfName)..." -ForegroundColor Cyan
# Actualiza el ADF para agregar la identidad asignada por el usuario conservando la identidad asignada por el sistema.
$payload = @{
    identity = @{
        type = "SystemAssigned,UserAssigned"
        userAssignedIdentities = @{
            "$identityResourceId" = @{}
        }
    }
} | ConvertTo-Json -Depth 5

$tempFile = New-TemporaryFile
$payload | Out-File $tempFile.FullName -Encoding utf8
az resource update --ids "/subscriptions/$subscriptionId/resourceGroups/$adfResourceGroupName/providers/Microsoft.DataFactory/factories/$adfName" --set identity=$($payload | ConvertFrom-Json | Select-Object -ExpandProperty identity) --api-version "2018-06-01"
Remove-Item $tempFile.FullName

Write-Host "¡Proceso Completado con éxito!" -ForegroundColor Green
Write-Host "Ahora puedes crear una Credencial en la interfaz de Azure Data Factory que apunte a esta Identidad Administrada Asignada por el Usuario." -ForegroundColor Yellow
