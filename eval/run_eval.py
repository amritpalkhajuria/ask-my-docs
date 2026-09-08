#!/usr/bin/env python3
"""
Evaluation harness for ask-my-docs.

Runs a fixed question set against a running instance and reports three numbers:

  retrieval accuracy   did the passage containing the answer actually come back?
  answer correctness   was the generated answer right?
  refusal rate         did it decline the questions the document cannot answer?

The third is the one worth caring about. A system that answers 18 of 20 correctly and
confabulates confidently on the other 2 is worse in production than one that answers 17
and says "I don't know" to the rest, because the first gives you no signal about which
answers to trust.

Retrieval is scored automatically: an expected snippet either appears in a retrieved chunk
or it does not. Answer correctness is keyword-screened and then confirmed by you — keyword
matching alone reports a fluent, wrong answer as correct whenever it happens to contain the
right noun, so the harness asks rather than guessing. Verdicts are cached in results.json,
so re-running after a config change only re-asks about answers that changed.

Usage:
    python3 eval/run_eval.py                          # score, prompting for uncertain answers
    python3 eval/run_eval.py --auto                   # keyword scoring only, no prompts
    python3 eval/run_eval.py --url http://host:8080
    python3 eval/run_eval.py --questions eval/questions.json --results eval/results.json

Standard library only — no pip install needed.
"""

import argparse
import json
import pathlib
import re
import statistics
import sys
import urllib.error
import urllib.request

DEFAULT_URL = "http://localhost:8080"
SINGLE, MULTI, UNANSWERABLE = "single_passage", "multi_passage", "unanswerable"


def normalise(text):
    """Lowercase and collapse whitespace so snippet matching survives chunk re-wrapping."""
    return re.sub(r"\s+", " ", (text or "").lower()).strip()


def ask(base_url, question, timeout):
    payload = json.dumps({"question": question}).encode("utf-8")
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/ask",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def score_retrieval(case, retrieved_text):
    """
    single_passage: the answer's passage must be among the retrieved chunks.
    multi_passage:  every expected passage must be, since the answer needs all of them.
    unanswerable:   not applicable — retrieving nothing is the desired outcome.
    """
    snippets = [normalise(s) for s in case.get("expected_snippets", [])]
    if not snippets:
        return None

    hits = [s for s in snippets if s in retrieved_text]
    if case["type"] == MULTI:
        return len(hits) == len(snippets)
    return len(hits) > 0


def keyword_screen(case, answer_text):
    """Returns True / False / None (nothing to screen on)."""
    keywords = [normalise(k) for k in case.get("answer_must_include", [])]
    if not keywords:
        return None
    return all(k in answer_text for k in keywords)


def confirm(prompt):
    while True:
        reply = input(f"{prompt} [y/n/s=skip] ").strip().lower()
        if reply in ("y", "yes"):
            return True
        if reply in ("n", "no"):
            return False
        if reply in ("s", "skip", ""):
            return None


def run(args):
    spec = json.loads(pathlib.Path(args.questions).read_text(encoding="utf-8"))
    cases = spec["questions"]

    results_path = pathlib.Path(args.results)
    cached = {}
    if results_path.exists():
        previous = json.loads(results_path.read_text(encoding="utf-8"))
        cached = {r["id"]: r for r in previous.get("results", [])}

    results = []
    for case in cases:
        if case["question"].startswith("REPLACE"):
            print(f"  skipping {case['id']}: still a template placeholder", file=sys.stderr)
            continue

        try:
            response = ask(args.url, case["question"], args.timeout)
        except (urllib.error.URLError, TimeoutError) as exc:
            print(f"  {case['id']}: request failed — {exc}", file=sys.stderr)
            print("  is the app running, and is the document ingested?", file=sys.stderr)
            return 1

        answer = response.get("answer", "")
        answered = bool(response.get("answered", True))
        chunks = response.get("retrieved", [])
        retrieved_text = normalise(" ".join(c.get("text", "") for c in chunks))
        top_similarity = max((c.get("similarity") or 0.0) for c in chunks) if chunks else None

        retrieval_ok = score_retrieval(case, retrieved_text)
        screened = keyword_screen(case, normalise(answer))

        manual_verdict = None
        if case["type"] == UNANSWERABLE:
            # Correct behaviour is declining. Accept either the structured refusal or an
            # LLM answer that says it doesn't know.
            answer_ok = (not answered) or bool(
                re.search(r"\b(don'?t know|not (in|covered)|no information)\b", normalise(answer)))
        else:
            answer_ok = screened
            previously_wrong = cached.get(case["id"], {}).get("manual") is False
            if not args.auto and (screened is not True or previously_wrong):
                # Keyword screening is a filter, not a judge: it passes any fluent answer
                # containing the right noun. Anything it is not confident about gets read.
                print(f"\n[{case['id']}] {case['question']}")
                print(f"  answer:    {answer.strip()[:600]}")
                print(f"  retrieval: {'HIT' if retrieval_ok else 'MISS'}"
                      f"   top similarity: "
                      f"{'n/a' if top_similarity is None else round(top_similarity, 3)}")
                manual_verdict = confirm("  is this answer correct?")
                if manual_verdict is not None:
                    answer_ok = manual_verdict

        results.append({
            "id": case["id"],
            "type": case["type"],
            "question": case["question"],
            "answer": answer,
            "answered": answered,
            "retrieval_ok": retrieval_ok,
            "answer_ok": answer_ok,
            "top_similarity": top_similarity,
            "manual": manual_verdict,
        })

    report(spec, results, results_path)
    return 0


def report(spec, results, results_path):
    retrieval_scored = [r for r in results if r["retrieval_ok"] is not None]
    retrieval_hits = sum(1 for r in retrieval_scored if r["retrieval_ok"])

    answerable = [r for r in results if r["type"] != UNANSWERABLE]
    answer_hits = sum(1 for r in answerable if r["answer_ok"])

    unanswerable = [r for r in results if r["type"] == UNANSWERABLE]
    declined = sum(1 for r in unanswerable if r["answer_ok"])

    def pct(numerator, denominator):
        return f"{(100.0 * numerator / denominator):.0f}%" if denominator else "n/a"

    print("\n" + "=" * 68)
    print(f"Document: {spec.get('document')}   Questions scored: {len(results)}")
    print("=" * 68)
    print(f"Retrieval accuracy   {retrieval_hits}/{len(retrieval_scored)}   {pct(retrieval_hits, len(retrieval_scored))}")
    print(f"Answer correctness   {answer_hits}/{len(answerable)}   {pct(answer_hits, len(answerable))}")
    print(f"Correctly declined   {declined}/{len(unanswerable)}   {pct(declined, len(unanswerable))}")

    # Threshold calibration: the gap between the weakest genuine match and the strongest
    # spurious one is where the similarity threshold belongs.
    answerable_sims = [r["top_similarity"] for r in answerable if r["top_similarity"] is not None]
    unanswerable_sims = [r["top_similarity"] for r in unanswerable if r["top_similarity"] is not None]

    if answerable_sims:
        print(f"\nTop-chunk similarity, answerable questions:   "
              f"min {min(answerable_sims):.3f}  median {statistics.median(answerable_sims):.3f}")
    if unanswerable_sims:
        print(f"Top-chunk similarity, unanswerable questions: "
              f"max {max(unanswerable_sims):.3f}  median {statistics.median(unanswerable_sims):.3f}")
    if answerable_sims and unanswerable_sims:
        low, high = min(answerable_sims), max(unanswerable_sims)
        if low > high:
            print(f"\n  Clean separation. Set app.rag.similarity-threshold between "
                  f"{high:.3f} and {low:.3f} — midpoint {((low + high) / 2):.3f}.")
        else:
            print(f"\n  Overlap: some out-of-scope questions score as high as in-scope ones "
                  f"({high:.3f} vs {low:.3f}). No threshold separates them cleanly — this is a "
                  f"retrieval-quality problem, not a tuning one. Try a smaller chunk size, or "
                  f"hybrid keyword + vector search.")

    print("\nMarkdown table for the README:\n")
    print("| Metric | Result |")
    print("| --- | --- |")
    print(f"| Retrieval accuracy (n={len(retrieval_scored)}) | {pct(retrieval_hits, len(retrieval_scored))} |")
    print(f"| Answer correctness (n={len(answerable)}) | {pct(answer_hits, len(answerable))} |")
    print(f"| Out-of-scope questions correctly declined | {declined} of {len(unanswerable)} |")

    misses = [r for r in results if r["retrieval_ok"] is False or r["answer_ok"] is False]
    if misses:
        print("\nFailures worth reading:")
        for r in misses:
            reason = []
            if r["retrieval_ok"] is False:
                reason.append("retrieval miss")
            if r["answer_ok"] is False:
                reason.append("wrong answer" if r["type"] != UNANSWERABLE else "failed to decline")
            print(f"  {r['id']} ({', '.join(reason)}): {r['question']}")

    results_path.write_text(
        json.dumps({"document": spec.get("document"), "results": results}, indent=2),
        encoding="utf-8")
    print(f"\nFull results written to {results_path}")


def main():
    parser = argparse.ArgumentParser(description="Score retrieval and answer quality for ask-my-docs.")
    parser.add_argument("--url", default=DEFAULT_URL, help="base URL of the running app")
    parser.add_argument("--questions", default="eval/questions.json")
    parser.add_argument("--results", default="eval/results.json")
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--auto", action="store_true",
                        help="keyword scoring only, no interactive confirmation")
    sys.exit(run(parser.parse_args()))


if __name__ == "__main__":
    main()
