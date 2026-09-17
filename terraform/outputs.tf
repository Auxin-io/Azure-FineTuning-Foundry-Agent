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

output "foundry_project_endpoint" {
  description = "native Foundry project created in README Step 5"
  value       = "https://${azurerm_cognitive_account.ai.custom_subdomain_name}.services.ai.azure.com/api/projects/${var.name_prefix}-finance"
}

output "agent_model_deployment" {
  value = azurerm_cognitive_deployment.agent_model.name
}

output "subscription_id" {
  value = data.azurerm_client_config.current.subscription_id
}
