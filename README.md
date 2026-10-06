# Fine-tune on Azure ML and serve it behind a Foundry agent

> Read **[Azure-Document-Ingestion](https://github.com/Auxin-io/Azure-Document-Ingestion#readme)** first. It covers prerequisites. It has produced the data, and the shared foundation exists.

In this project we trains a LoRA adapter for `Qwen/Qwen2.5-3B-Instruct` on the **finance
closed-book** data, serves it
from an Azure ML managed online endpoint, and puts a Foundry agent in front of
it so a user in Microsoft 365 Copilot can ask a finance question and get the
answer from the fine-tuned weights.

```
Blob (finance JSONL)  ->  Azure ML training job (T4, QLoRA)  ->  Model registry  ->  Managed online endpoint
                                                                                        ^
User -> M365 Copilot -> Bot Service -> Foundry agent (gpt-4.1-mini) -> OpenAPI tool ----+
```

Training data comes from the
[Azure-Document-Ingestion](https://github.com/Auxin-io/Azure-Document-Ingestion).

---

## Workflow diagram
The diagram below shows the workflow of the project.
<img width="3452" height="1593" alt="AI Project#1 - Doc Intel AWS v2 - Fine-Tune-Flow" src="https://github.com/user-attachments/assets/f719add2-bedb-42c9-be02-a4940ba7bf68" />

Left to right: the ingestion resource group turns generated PDFs into the closed-book
JSONL **(already done for the data ingestion)**; Azure ML registers it as data assets,
runs the QLoRA job on the T4 cluster, registers the adapter and serves base model +
adapter behind a token-protected endpoint; the Foundry agent calls that endpoint through
its OpenAPI tool using the project's managed identity, and Microsoft 365 Copilot reaches
the agent through the Bot Service created by *Publish*.
Every box maps to a step below: Step 2 (data assets), Step 3 (job, compute, registry),
Step 4 (deployment, endpoint), Step 5 (agent, tool, identity), Step 6 (Copilot).

## Azure services used

| Service | What it does in this project |
|---|---|
| **Blob Storage** (ingestion account) | holds the PDFs, the OCR output and the closed-book JSONL the training job reads; shared keys disabled, identity access only |
| **Document Intelligence** (`prebuilt-read`) | OCR of the generated PDFs in the ingestion repo |
| **Azure Machine Learning workspace** | data assets, the training job, the model registry and the managed online endpoint |
| **AML compute cluster `gpu-t4`** (`Standard_NC4as_T4_v3`) | runs the QLoRA job; scales to zero between runs |
| **AML datastore `ingest_curated`** | credential-less link from the workspace to the ingestion Blob container |
| **AML model registry** | versions the LoRA adapter (`docintel-qwen-adapter`) |
| **AML managed online endpoint** (`docintel-qwen`, T4) | serves Qwen2.5-3B + adapter behind `score.py`; AAD token auth, no keys |
| **Container Registry** | builds and stores the training and serving environment images |
| **Storage account** (workspace) | job code snapshots, outputs and logs |
| **Key Vault** | workspace secrets store (nothing custom is put in it) |
| **Application Insights + Log Analytics** | endpoint and job telemetry |
| **AI Services account** | hosts the `gpt-4.1-mini` deployment and the Foundry project |
| **Azure OpenAI deployment `gpt-4.1-mini`** | the agent's reasoning model: decides when to call the tool and relays the answer |
| **Foundry project `<project>`** | where the agent, its threads and its tool live; has a managed identity |
| **Foundry agent + OpenAPI tool** | `finance-agent` calls the endpoint as `answerFinanceQuestion` |
| **Managed identity + Entra ID RBAC** | the project identity scores the endpoint (AzureML Data Scientist); you get Foundry User to run agents |
| **Azure Bot Service** (created by Publish) | bridges the agent to Microsoft 365 Copilot / Teams |
| **Hugging Face Hub** (external) | source of the base model weights, downloaded at container start |
| **Terraform** (`azurerm`) | creates everything above except the Foundry project and the bot |

---

## Prerequisites

- Azure CLI 2.89+ with the ML extension; Terraform >= 1.9; Python 3.11+
- `az login` into a subscription where you are **Owner** (Terraform and the
  steps below assign roles)
- **Azure ML GPU quota** for `Standard NCASv3_T4 Family` in your region. This
  is separate from the Virtual Machines quota — check and request it before
  Step 1:

```bash
az login
az extension add -n ml
```

Portal → **Quotas → Machine Learning → your region → Standard NCASv3_T4
Family**: if the limit is 0, request 12 before continuing (approved within
the hour in our case).

---

## Step 1 — infrastructure

```bash
cd terraform
terraform init
terraform plan -out=ml.tfplan
terraform apply ml.tfplan
terraform output # Note Down all these keys and values
cd ..
```

Creates, in resource group `<prefix>-finetune-rg`:

| Resource | Purpose |
|---|---|
| Azure ML workspace | training jobs, model registry, endpoints |
| Storage account, Key Vault, App Insights, Log Analytics | workspace dependencies |
| Container Registry | environment images are built here |
| GPU cluster (`Standard_NC4as_T4_v3`) + CPU cluster, both min 0 / max 1 | training; scale to zero |
| AI Services account + `gpt-4.1-mini` deployment | the agent's conversation model; project management enabled so it can host the project |
| **Foundry project** | where the agent lives |
| **Credential-less datastore `ingest_curated`** | the workspace reads the ingestion container as itself, no keys |
| Role assignments | you: Blob Data Contributor, Key Vault Admin, OpenAI User, Foundry User. Workspace + clusters: Blob Data Reader on the ingestion account. Project: a least-privilege scorer role |

Attach the registry to the workspace. This is the one step Terraform cannot
do: setting `container_registry_id` forces the workspace to be *replaced* on
every later apply, destroying compute and jobs with it.

```bash
az ml workspace update -n <workspace> -g <ml-rg> --container-registry "/subscriptions/<sub>/resourceGroups/<ml-rg>/providers/Microsoft.ContainerRegistry/registries/<acr>" --update-dependent-resources
```

Then load the resource names the scripts need - none of them hardcode a name:

```bash
eval "$(terraform -chdir=terraform output -raw agent_env)"
```

---

## Step 2 — data

Run the following commands to add the data configuration in ML.

```bash
cd data
az ml data create -f train.yml      -g <ml-rg> -w <workspace>
az ml data create -f validation.yml -g <ml-rg> -w <workspace>
cd ..
```

---

## Step 3 — train

```bash
cd training
JOB=$(az ml job create -f job.yml -g <ml-rg> -w <workspace> --query name -o tsv | tr -d '\r')
echo "$JOB"
```

| Setting | Value | Why |
|---|---|---|
| base model | `Qwen/Qwen2.5-3B-Instruct` | open weights, ungated |
| method | QLoRA — 4-bit NF4 frozen base, LoRA r=16 alpha=32 on 7 projection modules | 29.9 M trainable params, 110 MB adapter |
| epochs | 15 | closed-book recall needs the passes; 3 teaches format, not facts |
| max_seq_length | 256 | rows are ~30 tokens |
| batch / grad-accum | 4 / 4 | effective 16 |
| precision | auto — bf16 where supported, fp16 on T4, fp32 on CPU | |

Watch it:

```bash
az ml job show -n $JOB -g <ml-rg> -w <workspace> --query status -o tsv
```
The step counter is in
Studio → job → *Outputs + logs → user_logs/std_log.txt*.

---

## Step 4 — register and serve

```bash
az ml model create -g <ml-rg> -w <workspace> \
  --name docintel-qwen-adapter --type custom_model \
  --path "azureml://jobs/$JOB/outputs/model"

cd ../serving
az ml online-endpoint create   -f endpoint.yml   -g <ml-rg> -w <workspace>
az ml online-deployment create -f deployment.yml -g <ml-rg> -w <workspace> --all-traffic
```

`endpoint.yml` sets `auth_mode: aad_token` — the endpoint has no keys.
`deployment.yml` runs `score.py` on a `Standard_NC4as_T4_v3`: it downloads the
base model from Hugging Face at start-up, applies the registered adapter and
answers with greedy decoding in about a second. Deployment takes ~20 minutes.

Test — base vs tuned side by side, with your `az login` token:

```bash
python serving/test_endpoint.py --ask "How much do we owe Xenon Energy?"
```

```
Q  How much do we owe Xenon Energy?
   BASE   I don't have access to specific invoices ...
   TUNED  The Xenon Energy invoice INV-35089 totals $47,186.04.
```

---

## Step 5 — the Foundry agent

```bash
cd ../foundry
python3 -m venv .venv-agents
source .venv-agents/bin/activate
pip install -r requirements.txt
.venv-agents/bin/python create_agent.py
```

The script creates (or updates)
`employee-agent` on `gpt-4.1-mini` with the endpoint as an OpenAPI
tool authenticated by managed identity, then asks three questions:

```
Q  How much do we owe Xenon Energy?
A  The Xenon Energy invoice INV-35089 totals $47,186.04.
   tool called: yes
Q  When is the Meridian Foods invoice due?
A  The Meridian Foods invoice INV-15002 is due on 2026-06-12.
   tool called: yes
Q  What is the capital of France?
A  The capital of France is Paris.
   tool called: NO
```

**Portal:** https://ai.azure.com → New Foundry → project `<project>` →
Agents → `employee-agent` → Save as new agent → Playground.

---

## Step 6 — publish to Microsoft 365 Copilot

In the agent click **Publish → Teams and Microsoft 365**, fill in the
descriptions, keep the generated bot name, and finish. This creates an Azure
Bot Service (free F0) and a service principal.

---

## Test questions

All ten vendors are in the weights.

| Ask | Expect |
|---|---|
| How much do we owe Xenon Energy? | INV-35089, $47,186.04 |
| When is the Meridian Foods invoice due? | INV-15002, 2026-06-12 |
| What is the Northwind Labs invoice total? | INV-13943, $99,472.14 |
| What is the Zephyr Networks purchase order number? | PO-8383 |
| When is the Lakeshore Cabling order required by? | PO-4158, 2026-03-28 |
| Give me the Vantage Aerospace invoice as JSON. | INV-21787, subtotal $30,986.45, tax $1,549.32, total $32,535.77 |
| What is the Cedar Systems invoice total? | not in the documents (refusal) |
| What is the capital of France? | answered by gpt-4.1-mini, no tool call |

---

## Cost and teardown

| Component | Cost |
|---|---|
| Idle stack | ~USD 3/month (Key Vault, storage, registry, Log Analytics) |
| `gpu-t4` while a job runs | ~USD 0.53/hour, scales to zero |
| Endpoint on T4 | **~USD 0.53/hour while deployed** |
| gpt-4.1-mini | per token, nothing at idle |
| Bot Service F0 | free |

```bash
az ml online-endpoint delete -n docintel-qwen -g <ml-rg> -w <workspace> -y   # stop the meter
az bot delete -n <bot> -g <ml-rg>                                            # created by Publish, not Terraform
cd terraform && terraform destroy                                                   # everything else
```

---

## Files

```
terraform/
  main.tf, variables.tf, outputs.tf, providers.tf   the stack in Step 1
data/
  datastore.yml                 credential-less datastore on the ingestion Blob container
  train.yml, validation.yml     data assets pointing into that datastore
training/
  job.yml            command job on gpu-t4
  train.py           QLoRA on GPU, plain LoRA on CPU; prompt masked, loss on answer tokens only
  environment.yml    torch 2.3.1, transformers 4.46.1, peft 0.13.2, bitsandbytes 0.44.1
  prompt_format.py   two-mode prompt; closed book has no Document block
serving/
  endpoint.yml, deployment.yml  AAD-only managed online endpoint on a T4
  score.py                      loads base + adapter, use_adapter toggle
  environment.yml, prompt_format.py, test_endpoint.py
agent/
  create_agent.py               creates and tests the agent (Step 5)
  publish_version.py            pushes new INSTRUCTIONS to the migrated (versioned) agent
  finance-qwen.openapi.yaml     the tool definition; servers[] is filled in at run time
  requirements.txt
```
