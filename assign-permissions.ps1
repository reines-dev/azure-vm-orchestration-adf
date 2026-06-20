# Script para asignar permisos a la identidad administrada de Azure Data Factory (ADF)
# para que pueda encender/apagar una Máquina Virtual (VM) en Azure.

$subscriptionId = "<YOUR_SUBSCRIPTION_ID>"
$resourceGroupName = "rg-computelab-prod-eastus2"
$vmName = "vm-datalab-prod-eastus2"
$adfName = "adf-datalab-prod-eastus"
$adfResourceGroupName = "rg-datalab-prod-eastus"

Write-Host "1. Conectando a Azure..." -ForegroundColor Cyan
az account set --subscription $subscriptionId

Write-Host "2. Obteniendo el Principal ID de la Identidad Administrada de ADF ($adfName)..." -ForegroundColor Cyan
$adfPrincipalId = az datafactory show --name $adfName --resource-group $adfResourceGroupName --query "identity.principalId" --output tsv

if (-not $adfPrincipalId) {
    Write-Error "No se pudo obtener el Principal ID de la ADF. Asegúrate de que tiene habilitada la Identidad Administrada."
    exit
}
Write-Host "Principal ID de la ADF: $adfPrincipalId" -ForegroundColor Green

Write-Host "3. Obteniendo el ID de recurso de la VM ($vmName)..." -ForegroundColor Cyan
$vmResourceId = az vm show --name $vmName --resource-group $resourceGroupName --query "id" --output tsv

if (-not $vmResourceId) {
    Write-Error "No se pudo obtener el ID del recurso de la VM."
    exit
}
Write-Host "ID del recurso de la VM: $vmResourceId" -ForegroundColor Green

Write-Host "4. Asignando el rol 'Virtual Machine Contributor' a la ADF..." -ForegroundColor Cyan
az role assignment create --assignee $adfPrincipalId --role "Virtual Machine Contributor" --scope $vmResourceId

Write-Host "¡Permisos asignados con éxito!" -ForegroundColor Green
