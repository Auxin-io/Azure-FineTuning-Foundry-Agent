output "resource_group" {
  value = azurerm_resource_group.this.name
}

output "ml_workspace" {
  value = azurerm_machine_learning_workspace.this.name
}

output "cpu_cluster" {
  value = azurerm_machine_learning_compute_cluster.cpu.name
}

output "gpu_cluster" {
  value = var.enable_gpu_cluster ? azurerm_machine_learning_compute_cluster.gpu[0].name : "not created - no GPU quota yet"
}

output "ai_services_endpoint" {
  value = azurerm_cognitive_account.ai.endpoint
}

output "ai_services_account" {
  value = azurerm_cognitive_account.ai.name
}

output "container_registry" {
  value = azurerm_container_registry.ml.name
}

output "foundry_project" {
  value = azapi_resource.project.name
}

output "foundry_project_endpoint" {
  value = "https://${azurerm_cognitive_account.ai.custom_subdomain_name}.services.ai.azure.com/api/projects/${azapi_resource.project.name}"
}

output "agent_model_deployment" {
  value = azurerm_cognitive_deployment.agent_model.name
}

output "datastore" {
  value = azapi_resource.ingest_curated.name
}

output "subscription_id" {
  value = data.azurerm_client_config.current.subscription_id
}

# Everything agent/create_agent.py needs, so no script has to hardcode a name.
#   eval "$(terraform output -raw agent_env)"
output "agent_env" {
  description = "Shell exports consumed by agent/create_agent.py"
  value = join("\n", [
    "export AZURE_RESOURCE_GROUP=${azurerm_resource_group.this.name}",
    "export AZURE_ML_WORKSPACE=${azurerm_machine_learning_workspace.this.name}",
    "export AZURE_AI_SERVICES=${azurerm_cognitive_account.ai.name}",
    "export FOUNDRY_PROJECT=${azapi_resource.project.name}",
    "export AGENT_MODEL=${azurerm_cognitive_deployment.agent_model.name}",
  ])
}
