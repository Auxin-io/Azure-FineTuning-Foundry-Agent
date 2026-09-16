"""Single source of truth for the prompt format.

Training and serving MUST build prompts identically. The original code had one
copy in the trainer and another in the handler, both emitting Llama-2/Mistral
`<s>[INST] ... [/INST]` markup while the base model was Qwen2.5 (and later
Llama 3.1). Neither tokenizer treats `[INST]` as a special token, so the model
was being tuned on literal bracket text rather than on its own chat structure.

This module builds a message list instead and lets
`tokenizer.apply_chat_template` emit whatever the actual base model expects.
Packaging copies this file into both the training source dir and the inference
code dir, so the two can never drift apart again.

Two modes, chosen by whether a document is supplied:

- **Open book** - the document text is in the prompt and the model is told to
  answer only from it. This is the grounded, permission-checked path.
- **Closed book** - no document. The model must answer from what fine-tuning
  wrote into its weights. The instruction has to name the document, because
  the same question has a different answer for every document in the corpus.

The system prompt differs between the two: telling a model to "answer only from
the supplied document text" and then supplying no document is a contradiction
that shows up as refusals.
"""

from __future__ import annotations

SYSTEM_PROMPT = (
    "You are a document intelligence assistant for business documents. "
    "Answer only from the supplied document text. "
    "When the instruction asks for JSON, reply with JSON only and no commentary."
)

SYSTEM_PROMPT_CLOSED_BOOK = (
    "You are a document intelligence assistant for business documents. "
    "Answer from what you learned about these documents during training. "
    "If you do not recognise the document identifier, say so plainly instead of "
    "inventing values. "
    "When the instruction asks for JSON, reply with JSON only and no commentary."
)


def is_closed_book(document: str | None) -> bool:
    """True when no document text was supplied and the model must recall."""
    return not (document or "").strip()


def build_messages(instruction: str, document: str | None) -> list[dict[str, str]]:
    """Return the chat messages for one document-intelligence request."""
    if is_closed_book(document):
        return [
            {"role": "system", "content": SYSTEM_PROMPT_CLOSED_BOOK},
            {"role": "user", "content": f"Task:\n{instruction}"},
        ]
    return [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": f"Document:\n{document}\n\nTask:\n{instruction}"},
    ]


def render_prompt(tokenizer, instruction: str, document: str | None) -> str:
    """Render the model-specific prompt string, ready for generation."""
    return tokenizer.apply_chat_template(
        build_messages(instruction, document),
        tokenize=False,
        add_generation_prompt=True,
    )
