"""Ask the deployed endpoint finance questions with NO document supplied.

    python serving/test_endpoint.py
    python serving/test_endpoint.py --ask "How much do we owe Xenon Energy?"

Base vs tuned side by side: same container, same weights, the adapter toggled
per request. Any difference is what fine-tuning wrote into the weights.
Authentication is an AAD token from `az login` - the endpoint has no keys.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import urllib.request

DEMO = [
    "What is the Zephyr Networks invoice total?",
    "When is the Meridian Foods invoice due?",
    "What is the Yarrow Agriculture purchase order number?",
    "How much do we owe Xenon Energy?",
    "Give me the Vantage Aerospace invoice as JSON.",
    "What is the Cedar Systems invoice total?",          # not in the ten -> refusal
]


AZ = shutil.which("az") or shutil.which("az.cmd") or "az"   # Windows installs az.cmd


def az(*args: str) -> str:
    return subprocess.check_output([AZ, *args], text=True).strip()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", default="docintel-qwen")
    ap.add_argument("--rg", default="docintel-ml-rg")
    ap.add_argument("--workspace", default="docintel-mlw-dggcb4")
    ap.add_argument("--ask")
    args = ap.parse_args()

    uri = az("ml", "online-endpoint", "show", "-n", args.endpoint, "-g", args.rg,
             "-w", args.workspace, "--query", "scoring_uri", "-o", "tsv")
    token = az("account", "get-access-token", "--resource", "https://ml.azure.com",
               "--query", "accessToken", "-o", "tsv")

    def ask(question: str, use_adapter: bool) -> dict:
        body = json.dumps({"question": question, "use_adapter": use_adapter,
                           "max_new_tokens": 128}).encode()
        req = urllib.request.Request(uri, data=body, headers={
            "Authorization": f"Bearer {token}", "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read())

    for q in ([args.ask] if args.ask else DEMO):
        print("=" * 78)
        print(f"Q  {q}")
        for label, flag in (("BASE ", False), ("TUNED", True)):
            r = ask(q, flag)
            print(f"   {label}  {r.get('answer', r)}   [{r.get('latency_ms', '?')} ms]")
        print()


if __name__ == "__main__":
    main()
