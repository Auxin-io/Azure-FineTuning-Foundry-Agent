# Architecture

Solid arrows are data or request flow; dashed arrows are identity and
platform dependencies. Training learns the finance facts into a LoRA adapter;
at runtime the Foundry agent uses gpt-4.1-mini only to decide whether to call
the fine-tuned Qwen endpoint, and the answer comes back from the weights.

```mermaid
flowchart LR
    USER["Finance user"] --> COPILOT["Microsoft 365 Copilot / Teams"]
    COPILOT --> BOT["Azure Bot Service"]

    subgraph Ingest["Ingestion: docintel-ingest-rg"]
        PDF["Generated PDFs<br/>10 finance docs"]
        BLOB["Blob Storage<br/>raw / curated"]
        DI["Document Intelligence<br/>prebuilt-read"]
        JSONL["Closed-book JSONL<br/>curated/datasets/"]
        PDF --> BLOB --> DI --> JSONL
    end

    subgraph ML["Training and serving: docintel-ml-rg"]
        subgraph AML["Azure Machine Learning workspace"]
            DS["Datastore ingest_curated<br/>credential-less"]
            ASSET["Data assets<br/>train / validation"]
            JOB["Command job<br/>training/job.yml"]
            COMPUTE["gpu-t4<br/>Standard_NC4as_T4_v3"]
            TRAIN["QLoRA training<br/>training/train.py"]
            REG["Model registry<br/>docintel-qwen-adapter"]
            DEPLOY["blue deployment<br/>serving/score.py<br/>Qwen2.5-3B + adapter"]
            ENDPOINT["Managed online endpoint<br/>AAD token auth"]
        end
        STORE["Storage account"]
        KV["Key Vault"]
        ACR["Container Registry"]
        APP["Application Insights"]
        LOG["Log Analytics"]

        subgraph AIS["AI Services account"]
            GPT["gpt-4.1-mini deployment"]
            subgraph PROJECT["Foundry project: docintel-finance"]
                AGENT["docintel-finance-agent"]
                OPENAPI["OpenAPI tool<br/>answerFinanceQuestion"]
                ID["Project managed identity"]
            end
        end
    end

    HF["Hugging Face<br/>Qwen2.5-3B-Instruct"] --> DEPLOY

    JSONL --> DS --> ASSET --> JOB --> COMPUTE --> TRAIN --> REG --> DEPLOY --> ENDPOINT

    BOT --> AGENT
    AGENT --> GPT
    AGENT --> OPENAPI
    OPENAPI -->|"POST /score"| ENDPOINT
    ENDPOINT -->|"answer + variant + latency"| OPENAPI

    ID -. "AAD token<br/>AzureML Data Scientist" .-> ENDPOINT
    COMPUTE -. "Storage Blob Data Reader" .-> BLOB
    AML -.-> STORE
    AML -.-> KV
    AML -.-> ACR
    AML -.-> APP
    APP -.-> LOG
```

## Request path

```mermaid
sequenceDiagram
    participant U as User
    participant C as M365 Copilot
    participant B as Bot Service
    participant A as Foundry agent
    participant G as gpt-4.1-mini
    participant E as Azure ML endpoint
    participant Q as Qwen + adapter

    U->>C: "How much do we owe Xenon Energy?"
    C->>B: activity
    B->>A: run (agent identity)
    A->>G: instructions + question + tool schema
    G-->>A: call answerFinanceQuestion(question)
    A->>E: POST /score, Bearer token (audience ml.azure.com)
    E->>Q: closed-book prompt, no document
    Q-->>E: "The Xenon Energy invoice INV-35089 totals $47,186.04."
    E-->>A: answer, variant=tuned, latency_ms
    A->>G: tool result
    G-->>A: reply verbatim
    A-->>B: message
    B-->>C: message
    C-->>U: answer
```

## Identities and roles

| Identity | Role | Scope | Why |
|---|---|---|---|
| `gpu-t4` cluster, workspace | Storage Blob Data Reader | ingestion storage account | training job mounts the JSONL from Blob |
| Foundry project | AzureML Data Scientist | endpoint | the OpenAPI tool scores as the project |
| Agent identity (created by Publish) | Foundry User, AzureML Data Scientist | AI Services account, endpoint | Copilot runs the agent as this identity |
| You | Foundry User | AI Services account | create and test agents from the SDK |

No keys exist anywhere in the path: the ingestion storage account has shared
keys disabled, the endpoint is `aad_token` only, and the agent tool uses
managed-identity auth.

## Repository mapping

| Concern | Location |
|---|---|
| Infrastructure | [`terraform/`](../terraform/) |
| Datastore and data assets | [`data/`](../data/) |
| Training job and QLoRA code | [`training/`](../training/) |
| Endpoint, deployment, scoring | [`serving/`](../serving/) |
| Agent creation and OpenAPI tool | [`agent/`](../agent/) |
| Manual M365 package (alternative) | [`copilot/`](../copilot/) |
