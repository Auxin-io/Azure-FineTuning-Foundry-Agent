# Fine-tune Qwen on Azure ML, serve it, and put a Foundry agent in front.
#
#   ML workspace + GPU cluster      train the finance adapter, host the endpoint
#   AI Services + gpt-4.1-mini      the agent's conversation model
#   Foundry hub + project           where the agent lives
#
# The GPU cluster scales to ZERO between jobs. Nothing here bills by the hour
# while idle except a deployed endpoint, which is created separately and
# should be deleted between demos.

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  sfx = random_string.suffix.result
}

resource "azurerm_resource_group" "this" {
  name     = "${var.name_prefix}-ml-rg"
  location = var.location
  tags     = var.tags
}

# ------------------------------------------------ workspace dependencies ---
resource "azurerm_storage_account" "ml" {
  name                            = "${var.name_prefix}ml${local.sfx}"
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = var.tags
}

resource "azurerm_key_vault" "ml" {
  name                       = "${var.name_prefix}-kv-${local.sfx}"
  resource_group_name        = azurerm_resource_group.this.name
  location                   = azurerm_resource_group.this.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
  rbac_authorization_enabled = true
  tags                       = var.tags
}

resource "azurerm_log_analytics_workspace" "ml" {
  name                = "${var.name_prefix}-law-${local.sfx}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_application_insights" "ml" {
  name                = "${var.name_prefix}-appi-${local.sfx}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  workspace_id        = azurerm_log_analytics_workspace.ml.id
  application_type    = "web"
  tags                = var.tags
}

# Managed online endpoints build their serving image into a registry.
# NOT attached via container_registry_id: on an existing workspace that
# attribute forces replacement (destroying compute and jobs). Attach in place:
#   az ml workspace update -n <ws> -g <rg> --container-registry <acr id>
resource "azurerm_container_registry" "ml" {
  name                = "${var.name_prefix}acr${local.sfx}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = var.tags
}

# ---------------------------------------------------------- ML workspace ---
resource "azurerm_machine_learning_workspace" "this" {
  name                          = "${var.name_prefix}-mlw-${local.sfx}"
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  application_insights_id       = azurerm_application_insights.ml.id
  key_vault_id                  = azurerm_key_vault.ml.id
  storage_account_id            = azurerm_storage_account.ml.id
  public_network_access_enabled = true

  identity {
    type = "SystemAssigned"
  }
  tags = var.tags

  # Azure ML sets container_registry_id itself, and any change to it forces
  # replacement of the whole workspace. Never let Terraform manage it.
  lifecycle {
    ignore_changes = [container_registry_id]
  }
}

# CPU cluster for training while the subscription has no Azure ML GPU quota.
# 32 cores, 256 GB. Plain LoRA on an fp32 base; a few hours for 615 rows.
# min 0, so it costs nothing between jobs.
resource "azurerm_machine_learning_compute_cluster" "cpu" {
  name                          = "cpu-e32"
  machine_learning_workspace_id = azurerm_machine_learning_workspace.this.id
  location                      = azurerm_resource_group.this.location
  vm_priority                   = "Dedicated"
  vm_size                       = var.cpu_vm_size

  scale_settings {
    min_node_count                       = 0
    max_node_count                       = 1
    scale_down_nodes_after_idle_duration = "PT5M"
  }

  identity {
    type = "SystemAssigned"
  }
  tags = var.tags
}

# GPU cluster - only once the quota request is approved. Creating it before
# that fails with ClusterMinNodesExceedCoreQuota, which is how this project
# discovered that Azure ML GPU quota is separate from VM quota.
resource "azurerm_machine_learning_compute_cluster" "gpu" {
  count                         = var.enable_gpu_cluster ? 1 : 0
  name                          = var.training_compute_name
  machine_learning_workspace_id = azurerm_machine_learning_workspace.this.id
  location                      = azurerm_resource_group.this.location
  vm_priority                   = "Dedicated"
  vm_size                       = var.training_vm_size

  scale_settings {
    min_node_count                       = 0
    max_node_count                       = 1
    scale_down_nodes_after_idle_duration = "PT5M"
  }

  identity {
    type = "SystemAssigned"
  }
  tags = var.tags
}

# -------------------------------------------------- AI Services + model ---
resource "azurerm_cognitive_account" "ai" {
  name                  = "${var.name_prefix}-ais-${local.sfx}"
  resource_group_name   = azurerm_resource_group.this.name
  location              = azurerm_resource_group.this.location
  kind                  = "AIServices"
  sku_name              = "S0"
  custom_subdomain_name = "${var.name_prefix}-ais-${local.sfx}"

  identity {
    type = "SystemAssigned"
  }
  tags = var.tags
}

resource "azurerm_cognitive_deployment" "agent_model" {
  name                 = var.agent_model
  cognitive_account_id = azurerm_cognitive_account.ai.id

  model {
    format  = "OpenAI"
    name    = var.agent_model
    version = var.agent_model_version
  }

  sku {
    name     = "GlobalStandard"
    capacity = 10
  }
}

# --------------------------------------------------------------- Foundry ---
resource "azurerm_ai_foundry" "hub" {
  name                = "${var.name_prefix}-hub-${local.sfx}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  storage_account_id  = azurerm_storage_account.ml.id
  key_vault_id        = azurerm_key_vault.ml.id

  identity {
    type = "SystemAssigned"
  }
  tags = var.tags
}

resource "azurerm_ai_foundry_project" "this" {
  name               = "${var.name_prefix}-agent"
  location           = azurerm_ai_foundry.hub.location
  ai_services_hub_id = azurerm_ai_foundry.hub.id

  identity {
    type = "SystemAssigned"
  }
  tags = var.tags
}

# ------------------------------------------------------------- data roles ---
# (The workspace and hub identities get storage access from Azure ML itself.)
resource "azurerm_role_assignment" "me_blob" {
  scope                = azurerm_storage_account.ml.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "me_kv" {
  scope                = azurerm_key_vault.ml.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "me_openai" {
  scope                = azurerm_cognitive_account.ai.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "me_ai_developer" {
  scope                = azurerm_ai_foundry_project.this.id
  role_definition_name = "Azure AI Developer"
  principal_id         = data.azurerm_client_config.current.object_id
}



resource "azurerm_role_assignment" "project_openai" {
  scope                = azurerm_cognitive_account.ai.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_ai_foundry_project.this.identity[0].principal_id
}
