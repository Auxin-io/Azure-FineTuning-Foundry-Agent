"""Create the finance agent in the Foundry project and test it.

    .venv-agents/Scripts/python agent/create_agent.py
    .venv-agents/Scripts/python agent/create_agent.py --ask "How much do we owe Xenon Energy?"

    user question -> agent (gpt-4.1-mini) decides it is a finance question
                  -> calls the OpenAPI tool answerFinanceQuestion
                  -> Azure ML endpoint: Qwen + finance adapter, NO document supplied
                  -> answer comes back from the fine-tuned weights

The tool is called with the project's managed identity (Entra token for
https://ml.azure.com); no keys anywhere. That identity needs the
AzureML Data Scientist role on the endpoint - see README Step 5.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
from pathlib import Path

import yaml
from azure.ai.agents import AgentsClient
from azure.ai.agents.models import (OpenApiManagedAuthDetails, OpenApiManagedSecurityScheme,
                                    OpenApiTool, RunStepToolCallDetails)
from azure.identity import AzureCliCredential

HERE = Path(__file__).resolve().parent
RG, ENDPOINT, PROJECT = "docintel-ml-rg", "docintel-qwen", "docintel-finance"
AGENT_NAME, MODEL = "docintel-finance-agent", "gpt-4.1-mini"

INSTRUCTIONS = """You are a finance assistant for the company's ten finance documents.
For any question about an invoice, a purchase order, a vendor, a supplier, an amount,
a due date or a required-by date, ALWAYS call the answerFinanceQuestion tool with the
user's question passed through unchanged, and reply with the tool's answer verbatim.
Do not guess, do not add numbers of your own, and do not answer finance questions
from general knowledge. If the tool says the vendor is not in the documents, say so.
For anything that is not a finance-document question, answer normally."""

AZ = shutil.which("az") or shutil.which("az.cmd") or "az"


def az(*args: str) -> str:
    return subprocess.check_output([AZ, *args], text=True).strip()


def workspace() -> str:
    return az("ml", "workspace", "list", "-g", RG, "--query", "[0].name", "-o", "tsv")


def project_endpoint() -> str:
    """The native Foundry project on the resource group's AI Services account."""
    account = az("cognitiveservices", "account", "list", "-g", RG,
                 "--query", "[?kind=='AIServices'].name | [0]", "-o", "tsv")
    return f"https://{account}.services.ai.azure.com/api/projects/{PROJECT}"


def load_spec() -> dict:
    spec = yaml.safe_load((HERE / "finance-qwen.openapi.yaml").read_text(encoding="utf-8"))
    uri = az("ml", "online-endpoint", "show", "-n", ENDPOINT, "-g", RG, "-w", workspace(),
             "--query", "scoring_uri", "-o", "tsv")
    spec["servers"] = [{"url": uri.rsplit("/score", 1)[0]}]
    return spec


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ask", action="append")
    args = ap.parse_args()

    client = AgentsClient(endpoint=project_endpoint(), credential=AzureCliCredential())

    tool = OpenApiTool(
        name="finance_qwen",
        description="Answers questions about the ten finance documents from a fine-tuned model.",
        spec=load_spec(),
        auth=OpenApiManagedAuthDetails(
            security_scheme=OpenApiManagedSecurityScheme(audience="https://ml.azure.com")),
    )

    agent = next((a for a in client.list_agents() if a.name == AGENT_NAME), None)
    if agent:
        agent = client.update_agent(agent.id, model=MODEL, instructions=INSTRUCTIONS,
                                    tools=tool.definitions)
        print(f"updated agent {agent.id}")
    else:
        agent = client.create_agent(model=MODEL, name=AGENT_NAME, instructions=INSTRUCTIONS,
                                    tools=tool.definitions)
        print(f"created agent {agent.id}")

    questions = args.ask or ["How much do we owe Xenon Energy?",
                             "When is the Meridian Foods invoice due?",
                             "What is the capital of France?"]
    thread = client.threads.create()
    for q in questions:
        client.messages.create(thread_id=thread.id, role="user", content=q)
        run = client.runs.create_and_process(thread_id=thread.id, agent_id=agent.id)
        print("=" * 78)
        print(f"Q  {q}")
        if run.status != "completed":
            print(f"   run {run.status}: {run.last_error}")
            continue
        msgs = list(client.messages.list(thread_id=thread.id))
        reply = next(m for m in msgs if m.role == "assistant")
        text = "".join(getattr(c, "text").value for c in reply.content if hasattr(c, "text"))
        called = any(isinstance(s.step_details, RunStepToolCallDetails)
                     for s in client.run_steps.list(thread_id=thread.id, run_id=run.id))
        print(f"A  {text}")
        print(f"   tool called: {'yes' if called else 'NO'}")


if __name__ == "__main__":
    main()
