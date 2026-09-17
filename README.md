# Fine-tune Qwen on Azure ML and serve it behind a Foundry agent

Trains a LoRA adapter for `Qwen/Qwen2.5-3B-Instruct` on the **finance
closed-book** data (615 question → answer rows, no document text), serves it
from an Azure ML managed online endpoint, and puts a Foundry agent in front of
it so a user in Microsoft 365 Copilot can ask a finance question and get the
answer from the fine-tuned weights — no document attached, no retrieval.

```
Blob (finance JSONL)  ->  Azure ML training job (T4, QLoRA)  ->  Model registry  ->  Managed online endpoint
                                                                                        ^
User -> M365 Copilot -> Bot Service -> Foundry agent (gpt-4.1-mini) -> OpenAPI tool ----+
```

Training data comes from the
[ingestion repo](https://github.com/Auxin-io/AWS-Document-Ingestion-Textract).
Sequence diagrams of every call are in [docs/azure-integration.md](docs/azure-integration.md).

This is the first of three ways the project gives a model knowledge. The
other two repos reuse the infrastructure and Foundry project created here:

| Dataset | Method | Where the knowledge lives | Repo |
|---|---|---|---|
| Finance | fine-tune Qwen2.5-3B (QLoRA) | adapter weights | this repo |
| Employee | new model trained from scratch | the model's weights | Azure-Employee-Pretraining |
| HR | RAG | an index, read at inference | Azure-HR-RAG |

---

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
| **Foundry project `docintel-finance`** | where the agent, its threads and its tool live; has a managed identity |
| **Foundry agent + OpenAPI tool** | `docintel-finance-agent` calls the endpoint as `answerFinanceQuestion` |
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
the hour in our case). The CLI check needs a workspace, so it comes after
Step 1.

On Windows, run the commands from Git Bash and prefix any command that takes
an ARM resource ID with `MSYS_NO_PATHCONV=1`. Set `PYTHONIOENCODING=utf-8`
before the Python scripts.

Every `<placeholder>` below is a value printed by `terraform output` after
Step 1 (`<workspace>`, `<ai-services-account>`, `<acr>`, `<sub>`) or by the
ingestion repo's `terraform output` (`<ingest-storage>`).

---

## Step 1 — infrastructure

```bash
cd terraform
terraform init
terraform plan -out=ml.tfplan
terraform apply ml.tfplan
terraform output
```

Creates, in resource group `docintel-ml-rg`:

| Resource | Purpose |
|---|---|
| Azure ML workspace `docintel-mlw-<sfx>` | training jobs, model registry, endpoints |
| Storage account, Key Vault, App Insights, Log Analytics | workspace dependencies |
| Container Registry `docintelacr<sfx>` | environment images are built here |
| Compute cluster `gpu-t4` — `Standard_NC4as_T4_v3`, min 0 / max 1 | training; scales to zero |
| AI Services account + `gpt-4.1-mini` deployment | the agent's conversation model; project management enabled so it can host the Foundry project |
| Role assignments | you: Blob Data Contributor, Key Vault Admin, Cognitive Services OpenAI User, Foundry User |

Attach the registry to the workspace (done outside Terraform so the workspace
is never replaced):

```bash
MSYS_NO_PATHCONV=1 az ml workspace update -n <workspace> -g docintel-ml-rg \
  --container-registry "/subscriptions/<sub>/resourceGroups/docintel-ml-rg/providers/Microsoft.ContainerRegistry/registries/<acr>" \
  --update-dependent-resources
```

Confirm the GPU quota the workspace sees:

```bash
az ml compute list-usage -g docintel-ml-rg -w <workspace> -l eastus -o table   # Standard NCASv3_T4 Family >= 4
```

Nothing here bills by the hour while idle. The clusters scale to zero; only a
deployed endpoint (Step 4) runs continuously.

---

## Step 2 — data

**Run the ingestion repo first** (`run_all.sh`, or at least
`build_closed_book.py --dataset finance --upload`). It writes the finance
closed-book JSONL into its Blob container:

```
https://<ingest-storage>.blob.core.windows.net/curated/datasets/closed_book_finance/{train,validation,test}.jsonl
```

Give the training cluster and the workspace read access to that account
(shared keys are disabled there; access is by identity only):

```bash
STG=$(az storage account show -n <ingest-storage> -g docintel-ingest-rg --query id -o tsv)
for ID in $(az ml compute show   -n gpu-t4      -g docintel-ml-rg -w <workspace> --query identity.principal_id -o tsv) \
          $(az ml workspace show -n <workspace> -g docintel-ml-rg                --query identity.principal_id -o tsv); do
  MSYS_NO_PATHCONV=1 az role assignment create --assignee-object-id $ID --assignee-principal-type ServicePrincipal \
    --role "Storage Blob Data Reader" --scope $STG
done
```

Register the container as a credential-less datastore and the two files as
data assets on it — nothing is copied:

```bash
cd data
az ml datastore create -f datastore.yml  -g docintel-ml-rg -w <workspace> --set account_name=<ingest-storage>
az ml data create      -f train.yml      -g docintel-ml-rg -w <workspace>
az ml data create      -f validation.yml -g docintel-ml-rg -w <workspace>
```

`job.yml` refers to the assets as `@latest`, so re-registering after a data
change needs no edit.

That registers `docintel-finance-train` (615 rows) and
`docintel-finance-validation` (61 rows). Each row:

```json
{"task": "recall", "instruction": "What is the Zephyr Networks invoice total?",
 "input": "", "output": "The Zephyr Networks invoice INV-32811 totals $48,362.08."}
```

`input` is empty on purpose — closed book. The model learns the answers.

---

## Step 3 — train

```bash
cd training
az ml job create -f job.yml -g docintel-ml-rg -w <workspace> --query name -o tsv
```

`job.yml` runs `train.py` on `gpu-t4` with the
`mcr.microsoft.com/azureml/openmpi5.0-cuda12.4-ubuntu22.04` base image and
the conda environment in `environment.yml`:

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
az ml job show -n <job> -g docintel-ml-rg -w <workspace> --query status -o tsv
```

Phases: `Preparing` (image build, ~15 min first time) → `Queued` (~3 min) →
`Running` (model download ~5 min, then training). On the T4 the run takes
about **3 h 15 min** and costs about **USD 1.75**. The step counter is in
Studio → job → *Outputs + logs → user_logs/std_log.txt*.

To train without a GPU, point `job.yml` at `compute: azureml:cpu-e32` and the
image `openmpi4.1.0-ubuntu22.04`; `train.py` switches to plain LoRA on fp32
automatically. Expect ~8 hours and ~USD 19.

---

## Step 4 — register and serve

```bash
az ml model create -g docintel-ml-rg -w <workspace> \
  --name docintel-qwen-adapter --type custom_model \
  --path azureml://jobs/<job>/outputs/model

cd serving
az ml online-endpoint create   -f endpoint.yml   -g docintel-ml-rg -w <workspace>
az ml online-deployment create -f deployment.yml -g docintel-ml-rg -w <workspace> --all-traffic
```

`endpoint.yml` sets `auth_mode: aad_token` — the endpoint has no keys.
`deployment.yml` runs `score.py` on a `Standard_NC4as_T4_v3`: it downloads the
base model from Hugging Face at start-up, applies the registered adapter and
answers with greedy decoding in about a second. Deployment takes ~20 minutes.

Test — base vs tuned side by side, with your `az login` token:

```bash
PYTHONIOENCODING=utf-8 python serving/test_endpoint.py
python serving/test_endpoint.py --ask "How much do we owe Xenon Energy?"
```

```
Q  How much do we owe Xenon Energy?
   BASE   I don't have access to specific invoices ...
   TUNED  The Xenon Energy invoice INV-35089 totals $47,186.04.   [980 ms]
```

`use_adapter: false` in a request serves the untuned base from the same
container — the difference is what fine-tuning wrote into the weights.

**The endpoint bills ~USD 0.53/hour while it exists.** Delete it between
demos:

```bash
az ml online-endpoint delete -n docintel-qwen -g docintel-ml-rg -w <workspace> -y
```

---

## Step 5 — the Foundry agent

The agent lives in a **Foundry project** on the AI Services account (the
kind the portal calls "New Foundry"). Terraform cannot create it yet; one
REST call does:

```bash
AIS=/subscriptions/<sub>/resourceGroups/docintel-ml-rg/providers/Microsoft.CognitiveServices/accounts/<ai-services-account>

az rest --method put --url "https://management.azure.com$AIS/projects/docintel-finance?api-version=2025-04-01-preview" \
  --body '{"location":"eastus","identity":{"type":"SystemAssigned"},"properties":{}}'
```

The project's identity is what calls the endpoint, so let it score:

```bash
PROJECT_ID=$(az rest --method get --url "https://management.azure.com$AIS/projects/docintel-finance?api-version=2025-04-01-preview" --query identity.principalId -o tsv)
EP=$(az ml online-endpoint show -n docintel-qwen -g docintel-ml-rg -w <workspace> --query id -o tsv)
MSYS_NO_PATHCONV=1 az role assignment create --assignee-object-id $PROJECT_ID --assignee-principal-type ServicePrincipal \
  --role "AzureML Data Scientist" --scope $EP
```

(Your own Foundry data-plane role came from Terraform.) Wait 5–10 minutes for
the role to propagate, then create and test the agent — the script finds the
workspace and AI Services account in the resource group by itself:

```bash
python -m venv .venv-agents
.venv-agents/Scripts/pip install -r agent/requirements.txt
PYTHONIOENCODING=utf-8 .venv-agents/Scripts/python agent/create_agent.py
```

The script puts the live `scoring_uri` into the OpenAPI spec, creates
`docintel-finance-agent` on `gpt-4.1-mini` with the endpoint as an OpenAPI
tool authenticated by the project's managed identity (audience
`https://ml.azure.com`), then asks three questions and reports whether the
tool was called:

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

Re-running the script updates the agent in place. To ask your own question:

```bash
.venv-agents/Scripts/python agent/create_agent.py --ask "What is the Yarrow Agriculture purchase order number?"
```

**Portal.** Open https://ai.azure.com, switch **New Foundry** on, choose
project `docintel-finance` → Agents. The agent is listed under *Classic
agents*; click **Save as new agent** to migrate it to the versioned agent
API (the tool and its auth carry over). Open it → **Playground** → the model
shows `gpt-4.1-mini` → ask a finance question.

**After migrating.** "Save as new agent" copies the agent into the versioned
agent API; from then on the copy is independent of the classic one the script
created. The portal also adds a `web_search` tool to the copy, which can let
gpt-4.1-mini answer from the web instead of the model - remove it in the
portal or run the script below, which also does that. Whenever you change
`INSTRUCTIONS` in `agent/create_agent.py`, push them to the migrated copy with:

```bash
MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8 .venv-agents/Scripts/python agent/publish_version.py
```

It publishes a new version (`docintel-finance-agent:2`, `:3`, ...) with the same model and
tools; the playground and Copilot pick up the latest version automatically.

---

## Step 6 — publish to Microsoft 365 Copilot

In the migrated agent click **Publish → Teams and Microsoft 365**, fill in the
descriptions, keep the generated bot name, and finish. This creates an Azure
Bot Service (`docintel-finance-agent<nnnnn>`, free F0 tier) in the resource
group and a service principal named `…-AgentIdentity` that the bot runs as.
Give that identity the same two roles:

```bash
AGENT_SP=$(az ad sp list --display-name "<ai-services-account>-docintel-finance-docintel-finance-agent-AgentIdentity" --query "[0].id" -o tsv)
MSYS_NO_PATHCONV=1 az role assignment create --assignee-object-id $AGENT_SP --assignee-principal-type ServicePrincipal --role 53ca6127-db72-4b80-b1b0-d745d6d5456d --scope $AIS   # Azure AI User / Foundry User
MSYS_NO_PATHCONV=1 az role assignment create --assignee-object-id $AGENT_SP --assignee-principal-type ServicePrincipal --role "AzureML Data Scientist" --scope $EP
```

After a few minutes: https://copilot.microsoft.com → **Agents** →
`docintel-finance-agent` → new chat → *"How much do we owe Xenon Energy?"*

---

## Test questions

All ten vendors are in the weights. Any of these work in the endpoint test,
the agent script, the playground and Copilot:

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

The ten documents: invoices from Yarrow Agriculture, Meridian Foods,
Northwind Labs, Xenon Energy, Vantage Aerospace; purchase orders to Ironwood
Supply, Zephyr Networks, Halcyon Print, Nordic Optics, Lakeshore Cabling.
Use the exact vendor names — a near-miss such as "Halcyon Labs" is a
wrong-premise question and the model may answer it with another document's
numbers rather than refuse.

---|---|
| How much do we owe Xenon Energy? | INV-35089, $47,186.04 |
| When is the Meridian Foods invoice due? | INV-15002, 2026-06-12 |
| What is the Yarrow Agriculture purchase order number? | the PO number |
| What is the Vantage Aerospace invoice total? | the total |
| Give me the Nordic Timber invoice as JSON. | the whole record |
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
az ml online-endpoint delete -n docintel-qwen -g docintel-ml-rg -w <workspace> -y   # stop the meter
az bot delete -n <bot> -g docintel-ml-rg                                            # created by Publish, not Terraform
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
copilot/
  manual M365 declarative-agent package (alternative to Step 6; needs a tenant admin)
docs/
  azure-integration.md          architecture, request sequence, identities and roles
```

`prompt_format.py` must be identical in `training/` and `serving/` — the
system prompt the adapter was trained under is the one it must be served
under.
