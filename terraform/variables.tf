variable "name_prefix" {
  type    = string
  default = "docintel"
}

variable "location" {
  description = "Needs GPU quota (NC A10 / T4 families) and gpt-4.1-mini availability. eastus has both."
  type        = string
  default     = "eastus"
}

variable "training_vm_size" {
  description = "One T4 (16 GB). The subscription has quota for the NCasT4_v3 family in eastus."
  type        = string
  default     = "Standard_NC4as_T4_v3"
}

variable "training_compute_name" {
  description = "Azure ML GPU compute cluster name."
  type        = string
  default     = "gpu-t4"
}

variable "agent_model" {
  description = "Azure OpenAI model that runs the agent conversation and tool-calling."
  type        = string
  default     = "gpt-4.1-mini"
}

variable "agent_model_version" {
  type    = string
  default = "2025-04-14"
}

variable "tags" {
  type    = map(string)
  default = { project = "docintel", managed_by = "terraform" }
}

variable "cpu_vm_size" {
  description = "CPU training node. EDSv4 family has quota; 32 cores keeps fp32 LoRA on a 3B model to a few hours."
  type        = string
  default     = "Standard_E32ds_v4"
}

variable "enable_gpu_cluster" {
  description = "Requires Azure ML quota (not VM quota) for the training_vm_size family. Set false if the request is still pending."
  type        = bool
  default     = true
}
