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

# The one thing this stack needs from another repository.
data "azurerm_storage_account" "ingest" {
  name                = var.ingest_storage_account_name
  resource_group_name = var.ingest_resource_group_name
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  sfx = random_string.suffix.result
}

resource "azurerm_resource_group" "this" {
  name     = "${var.name_prefix}-finetune-rg"
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

  # lets the account host native Foundry projects (README Step 5)
  project_management_enabled = true

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
    capacity = 150
  }
}

# ------------------------------------------------------------- data roles ---
# (The workspace identity gets storage access from Azure ML itself.)
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

# Foundry data plane: create and run agents in projects on the AI Services
# account. Owner does not include this - it is a data action. Referenced by
# id because the display name differs between tenants ("Azure AI User" /
# "Foundry User").
resource "azurerm_role_assignment" "me_foundry_user" {
  scope              = azurerm_cognitive_account.ai.id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/53ca6127-db72-4b80-b1b0-d745d6d5456d"
  principal_id       = data.azurerm_client_config.current.object_id
}

# ------------------------------------------------------- Foundry project ---
# Was a manual `az rest --method put` step. The project's system-assigned
# identity is what calls the scoring endpoint, so it has to exist in state
# for the role assignment below to reference it.
resource "azapi_resource" "project" {
  type      = "Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview"
  name      = var.project_name
  parent_id = azurerm_cognitive_account.ai.id
  location  = azurerm_resource_group.this.location
  tags      = var.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {}
  }

  # Azure permits one mutating operation at a time per Cognitive Services
  # account and rejects concurrent ones with 409 RequestConflict. The model
  # deployment is a write on the same account, so the project has to wait for
  # it rather than race it.
  depends_on = [azurerm_cognitive_deployment.agent_model]
}

# ------------------------------------------- ingestion data, no keys ------
# Credential-less: no account_key and no SAS, so the workspace reads the
# container as itself. The role assignments below are what make it work.
# Not azurerm_machine_learning_datastore_blobstorage: that resource requires
# account_key or a SAS even though both are schema-optional, and the ingestion
# account has shared keys DISABLED, so neither exists. credentialsType "None"
# is the identity-based datastore - the workspace reads the container as itself.
resource "azapi_resource" "ingest_curated" {
  type      = "Microsoft.MachineLearningServices/workspaces/datastores@2026-05-01"
  name      = "ingest_curated"
  parent_id = azurerm_machine_learning_workspace.this.id

  body = {
    properties = {
      datastoreType = "AzureBlob"
      accountName   = data.azurerm_storage_account.ingest.name
      containerName = var.ingest_container
      endpoint      = "core.windows.net"
      protocol      = "https"
      description   = "curated container of the document-ingestion storage account"
      credentials = {
        credentialsType = "None"
      }
    }
  }

  # The workspace must be able to read the container before the datastore is
  # validated against it.
  depends_on = [azurerm_role_assignment.ws_reads_ingest]
}

# Shared keys are disabled on the ingestion account, so identity is the only
# way in. The workspace reads data assets; the cluster reads them at job time.
resource "azurerm_role_assignment" "ws_reads_ingest" {
  scope                = data.azurerm_storage_account.ingest.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_machine_learning_workspace.this.identity[0].principal_id
}

resource "azurerm_role_assignment" "gpu_reads_ingest" {
  count                = var.enable_gpu_cluster ? 1 : 0
  scope                = data.azurerm_storage_account.ingest.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_machine_learning_compute_cluster.gpu[0].identity[0].principal_id
}

resource "azurerm_role_assignment" "cpu_reads_ingest" {
  scope                = data.azurerm_storage_account.ingest.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_machine_learning_compute_cluster.cpu.identity[0].principal_id
}

# Note: there is deliberately no "me_reads_ingest" assignment here.
# The ingestion repo already grants whoever ran it Storage Blob Data
# Contributor on that account, which covers read. Granting it again from a
# track stack fails with 409 RoleAssignmentExists as soon as a second track is
# deployed, because Azure keys an assignment on (principal, role, scope) and
# the person is the same in all of them.
#
# Deploying a track as a DIFFERENT identity than the one that ran ingestion?
# Grant yourself read once, by hand:
#   az role assignment create --assignee <you> --role "Storage Blob Data Reader" \
#     --scope $(az storage account show -n <ingest-storage> -g <ingest-rg> --query id -o tsv)

# ------------------------------------- project -> endpoint, least privilege ---
# The agent's tool call is the project identity scoring the online endpoint.
# "AzureML Data Scientist" would do it but also grants workspaces/*/write and
# /delete - enough to delete the endpoint. Score + read is all that is needed.
resource "azurerm_role_definition" "endpoint_scorer" {
  name        = "${var.name_prefix}-endpoint-scorer-${local.sfx}"
  scope       = azurerm_machine_learning_workspace.this.id
  description = "Read and score online endpoints in this workspace. Nothing else."

  # Two things this block gets wrong if you trim it further:
  #
  # 1. score/action is a CONTROL-plane action, not a data action. The provider
  #    operation list shows no dataActions at all for workspaces/onlineEndpoints,
  #    and the built-in AzureML Data Scientist has an empty dataActions too.
  #    Under data_actions it produces a role that cannot score anything.
  #
  # 2. The read has to be the wildcard. Scoring with an Entra token makes the
  #    front door read more than the endpoint resource, so
  #    onlineEndpoints/read on its own gets the token presented and then
  #    refused with "403 Microsoft Entra Token denied by policy". The built-in
  #    role works because it carries workspaces/*/read.
  #
  # The built-in also carries */write, */delete and */action, which would let
  # the agent's own identity delete the endpoint it calls. That is why this
  # role exists: same read, one action, no write and no delete.
  permissions {
    actions = [
      "Microsoft.MachineLearningServices/workspaces/*/read",
      "Microsoft.MachineLearningServices/workspaces/onlineEndpoints/score/action",
    ]
    not_actions = []
  }

  assignable_scopes = [azurerm_machine_learning_workspace.this.id]
}

# The principal here is the AI SERVICES ACCOUNT's identity, not the project's.
# The agent's OpenAPI tool calls the endpoint as the account, so granting the
# project identity - which is what the docs imply and what this used to do -
# leaves the call refused with "403 Microsoft Entra Token denied by policy"
# even when the project holds the built-in AzureML Data Scientist. Verified by
# granting each principal in turn against a live endpoint.
resource "azurerm_role_assignment" "project_scores_endpoints" {
  scope              = azurerm_machine_learning_workspace.this.id
  role_definition_id = azurerm_role_definition.endpoint_scorer.role_definition_resource_id
  principal_id       = azurerm_cognitive_account.ai.identity[0].principal_id

  # The role is created moments earlier in the same apply; without this the
  # assignment can race it.
  depends_on = [azurerm_role_definition.endpoint_scorer]
}

# ------------------------------------------------- pull the training image ---
# admin_enabled is false on the registry, so there is no admin password to fall
# back on - the only way in is a role assignment. The node pulls as the COMPUTE
# cluster's own identity, not as the workspace, so the cluster needs this even
# though `az ml workspace update --container-registry` already ran. Without it
# the image builds and pushes, then the node fails with
# AggregatedUnauthorizedAccessError and the container never starts.
resource "azurerm_role_assignment" "gpu_pulls_image" {
  count                = var.enable_gpu_cluster ? 1 : 0
  scope                = azurerm_container_registry.ml.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_machine_learning_compute_cluster.gpu[0].identity[0].principal_id
}

resource "azurerm_role_assignment" "cpu_pulls_image" {
  scope                = azurerm_container_registry.ml.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_machine_learning_compute_cluster.cpu.identity[0].principal_id
}

resource "azurerm_role_assignment" "ws_pulls_image" {
  scope                = azurerm_container_registry.ml.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_machine_learning_workspace.this.identity[0].principal_id
}
