"""Synthetic, seeded workload: long documents and short questions, as token IDs.

Each document is a fake project report of exactly `doc_tokens` tokens. Prompts are
sent as token IDs so the document prefix is byte-identical across its questions;
text prompts can re-tokenize differently where document and question meet.

Order (per document, in two passes over all documents):
  pass 1: Q0 (first), Q1 (resident: asked straight after Q0)
  pass 2: Q2 (resident or evicted, depending on how many tokens passed since), Q3 (resident)
"""
import argparse
import random
from dataclasses import dataclass

WORDS = """
account action agreement analysis approach area assessment asset audit balance batch budget
capacity carrier channel claim client cluster contract control cost coverage customer cycle
data deadline delivery demand deployment design device estimate event exposure facility
factor feature figure file forecast framework function grant growth hardware incident index
input interface inventory invoice issue item ledger level license limit load margin market
measure method metric milestone model module network notice objective operation order output
owner package partner payment period plan platform policy pool portfolio position practice
priority process product profile program project proposal quarter queue quota rate record
region release report request requirement reserve resource result revenue review risk route
rule sample schedule scope segment server service session share signal site source stage
standard statement status storage strategy supplier supply system target task team term test
threshold ticket tier timeline total track transfer trend unit update usage value vendor
version volume warehouse window workload
""".split()
VERBS = "approved delayed expanded reduced moved reviewed flagged merged split closed opened tracked".split()
NAMES = "Aster Birch Cobalt Delta Ember Fjord Garnet Harbor Iris Juniper Kestrel Lumen Maple Nimbus Onyx Pine Quartz Raven Sable Tundra Umber Vale Willow Xenon Yarrow Zephyr".split()


@dataclass
class Request:
    seq: int
    doc: int
    question: int
    prompt_ids: list


def _document_text(rng, doc):
    """Text that is comfortably longer than needed; trimmed to exact tokens later."""
    name = f"{rng.choice(NAMES)}-{doc:03d}"
    lines = [f"Internal report for project {name}. Reference {rng.randrange(10**8):08d}."]
    for section in range(60):
        lines.append(f"\nSection {section + 1}: {rng.choice(WORDS).title()} {rng.choice(WORDS)} review.")
        for _ in range(12):
            w = rng.sample(WORDS, 6)
            lines.append(
                f"The {w[0]} {w[1]} for {w[2]} {rng.choice(NAMES)} was {rng.choice(VERBS)} "
                f"after the {w[3]} {w[4]} reached {rng.randrange(1, 999)} {w[5]} units "
                f"in quarter {rng.randrange(1, 5)}."
            )
    return name, " ".join(lines)


def build(tokenizer, seed, docs, doc_tokens, questions=4):
    rng = random.Random(seed)
    prompts = {}
    for d in range(docs):
        name, text = _document_text(rng, d)
        ids = tokenizer.encode(text, add_special_tokens=False)
        if len(ids) < doc_tokens:
            raise ValueError(f"document {d} has only {len(ids)} tokens")
        doc_ids = ids[:doc_tokens]
        for q in range(questions):
            topic = rng.choice(WORDS)
            question = f"\n\nQuestion {q + 1}: What happened to the {topic} figures for project {name}? Answer briefly:"
            prompts[d, q] = doc_ids + tokenizer.encode(question, add_special_tokens=False)

    order = [(d, q) for d in range(docs) for q in (0, 1)] + [(d, q) for d in range(docs) for q in (2, 3)]
    order += [(d, q) for d in range(docs) for q in range(4, questions)]
    return [Request(i, d, q, prompts[d, q]) for i, (d, q) in enumerate(order)]


if __name__ == "__main__":
    from transformers import AutoTokenizer

    ap = argparse.ArgumentParser(description="Print workload statistics.")
    ap.add_argument("--model", default="Qwen/Qwen2.5-3B-Instruct")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--docs", type=int, default=20)
    ap.add_argument("--doc-tokens", type=int, default=10_000)
    a = ap.parse_args()
    reqs = build(AutoTokenizer.from_pretrained(a.model), a.seed, a.docs, a.doc_tokens)
    total = sum(len(r.prompt_ids) for r in reqs)
    print(f"{len(reqs)} requests, {total:,} prompt tokens, {a.docs * a.doc_tokens:,} unique document tokens")
