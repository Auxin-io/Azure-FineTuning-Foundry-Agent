"""AAD-protected Azure ML managed online endpoint scorer."""

from __future__ import annotations

import json
import os
import time
from typing import Any

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

from prompt_format import build_messages

BASE_MODEL_ID = os.environ.get("BASE_MODEL_ID", "Qwen/Qwen2.5-3B-Instruct")


def init() -> None:
    global model, tokenizer, adapter_loaded
    from peft import PeftModel

    # Azure ML mounts a registered model UNDER a subfolder of AZUREML_MODEL_DIR
    # (the folder name it was registered from - here the job output "model"),
    # so the adapter is at <dir>/model/adapter_config.json, not at the root.
    # Search for it rather than assume the layout.
    model_dir = os.environ.get("AZUREML_MODEL_DIR", ".")
    for root, _dirs, files in os.walk(model_dir):
        if "adapter_config.json" in files:
            model_dir = root
            break
    print(f"adapter dir: {model_dir}  contents: {sorted(os.listdir(model_dir))[:8]}")
    tokenizer = AutoTokenizer.from_pretrained(BASE_MODEL_ID, use_fast=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    dtype = (
        torch.bfloat16
        if torch.cuda.is_available() and torch.cuda.is_bf16_supported()
        else torch.float16 if torch.cuda.is_available() else torch.float32
    )
    base = AutoModelForCausalLM.from_pretrained(
        BASE_MODEL_ID, torch_dtype=dtype, device_map="auto"
    )
    adapter_loaded = os.path.exists(os.path.join(model_dir, "adapter_config.json"))
    model = PeftModel.from_pretrained(base, model_dir) if adapter_loaded else base
    model.eval()


def run(raw: Any) -> dict[str, Any]:
    payload = json.loads(raw) if isinstance(raw, str) else raw
    prompt = tokenizer.apply_chat_template(
        build_messages(
            payload.get("question", payload.get("instruction", "")),
            payload.get("context", payload.get("input", "")),
        ),
        tokenize=False,
        add_generation_prompt=True,
    )
    inputs = tokenizer(prompt, return_tensors="pt").to(model.device)
    use_adapter = bool(payload.get("use_adapter", True)) and adapter_loaded
    started = time.perf_counter()
    with torch.no_grad():
        if not use_adapter and hasattr(model, "disable_adapter"):
            with model.disable_adapter():
                generated = model.generate(
                    **inputs, max_new_tokens=int(payload.get("max_new_tokens", 192)),
                    do_sample=False, pad_token_id=tokenizer.pad_token_id
                )
        else:
            generated = model.generate(
                **inputs, max_new_tokens=int(payload.get("max_new_tokens", 192)),
                do_sample=False, pad_token_id=tokenizer.pad_token_id
            )
    completion = generated[0][inputs["input_ids"].shape[-1]:]
    return {
        "answer": tokenizer.decode(completion, skip_special_tokens=True).strip(),
        "variant": "tuned" if use_adapter else "base",
        "base_model": BASE_MODEL_ID,
        "latency_ms": round((time.perf_counter() - started) * 1000, 1),
    }
