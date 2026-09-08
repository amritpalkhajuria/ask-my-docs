# Ask My Docs — RAG Q&A API (Spring Boot + Spring AI)

[![CI](https://github.com/amritpalkhajuria/ask-my-docs/actions/workflows/ci.yml/badge.svg)](https://github.com/amritpalkhajuria/ask-my-docs/actions/workflows/ci.yml)

A backend service that lets you upload a document (PDF, DOCX, TXT) and ask
natural-language questions about it. Answers are grounded in the document's
actual content via Retrieval-Augmented Generation (RAG), not just the LLM's
general training data.

## Why I built this

Extending my backend Java/Spring Boot experience into LLM integration, vector
search, and RAG — patterns increasingly used in production systems (internal
knowledge assistants, support bots, document search). Built to reinforce
existing skills (PostgreSQL, Docker, REST API design) rather than introduce an
unrelated stack.

## Architecture

```
                 ┌─────────────────┐
  PDF upload --> │ IngestionService │ --> chunks text --> embeds via OpenAI
                 └─────────────────┘                          |
                                                                v
                                                      Postgres + pgvector
                                                       (vector_store table)
                                                                ^
                 ┌─────────────────┐                           |
  Question   --> │   QueryService   │ <-- similarity search ---┘
                 └─────────────────┘
                          |
                          v
                  OpenAI chat model (context + question) --> Answer
```

**Retrieval** — question is embedded and compared against stored document
chunks via cosine similarity in pgvector.
**Augmentation** — the most relevant chunks are inserted into the prompt as
context.
**Generation** — the LLM answers using that context, reducing hallucination
versus asking it cold.

## Tech stack

- Java 17, Spring Boot 3.3
- Spring AI 1.0.0-M3 (OpenAI integration, PDF/DOCX parsing via Apache Tika, vector store abstraction)
- PostgreSQL + pgvector (vector database)
- OpenAI `text-embedding-3-small` (embeddings) + `gpt-4o-mini` (chat)
- Docker Compose (local Postgres)

## Running it locally

**Prerequisites:** Java 17+, Maven, Docker, an OpenAI API key.

```bash
# 1. Start Postgres with pgvector
docker compose up -d

# 2. Set your OpenAI API key
export OPENAI_API_KEY= your api key

# 3. Run the app
mvn spring-boot:run
```

**Upload a document:**
```bash
curl -F "file=@/path/to/your.pdf" http://localhost:8080/documents
```

**Ask a question about it:**
```bash
curl -X POST http://localhost:8080/ask \
  -H "Content-Type: application/json" \
  -d '{"question": "What experience does this candidate have with Kafka?"}'
```

## Testing

24 tests across 5 classes, run with `mvn test`:

- **`QueryServiceTest`** (5) — the enforced refusal path (no chunk above `similarity-threshold`
  means the LLM is never called), top-k/threshold wiring, and that a blank question is
  rejected as a 400 rather than reaching the model.
- **`IngestionServiceTest`** (5) — chunk counts against the splitter's real behavior, plus
  empty-file and unreadable-file rejection.
- **`DocumentControllerTest`** (5) — multipart upload handling, including the non-multipart
  POST and oversized-file edge cases.
- **`QueryControllerTest`** (5) — request validation and error-response shape.
- **`RagIntegrationTest`** (4) — the only test touching a real database: spins up Postgres +
  pgvector via Testcontainers and exercises the full ingest → embed → store →
  similarity-search path. Uses `HashingEmbeddingModel` (`support/HashingEmbeddingModel.java`),
  a deterministic offline stand-in for the OpenAI embedding model, so it needs Docker but no
  API key or network access.

No test calls a paid API — unit tests mock the LLM, and the integration test's embedding
model is fully offline. This is what the CI badge above reflects.

## Evaluation

`eval/run_eval.py` runs a fixed 20-question set (12 single-passage, 5 multi-passage, 3
unanswerable) against a single ingested document — my own CV — and scores retrieval
accuracy, answer correctness, and refusal rate. Full methodology in the script's docstring.

**Run 1 — baseline** (`chunk-size: 800`, the Spring AI default, `similarity-threshold: 0.35`):

| Metric | Result |
| --- | --- |
| Retrieval accuracy (n=17) | 59% |
| Answer correctness (n=17) | 47% |
| Out-of-scope questions correctly declined | 3 of 3 |

A one-page CV is only a few hundred words, so at `chunk-size: 800` the whole document
collapsed into 2 chunks. Every query — however narrow — was embedded against the same one
or two broad blobs, which is why retrieval and answer correctness were both weak.

**Run 2 — smaller chunks** (`chunk-size: 150`, `similarity-threshold: 0.35` unchanged):

| Metric | Result |
| --- | --- |
| Retrieval accuracy (n=17) | 76% |
| Answer correctness (n=17) | 59% |
| Out-of-scope questions correctly declined | 2 of 3 |

Shrinking the chunk size to fit the corpus improved retrieval (+17pp) and answer
correctness (+12pp) — the chunks now separate topics (a job, a project, an education
entry) instead of blending them. But declines went *down*, 3/3 → 2/3: the previously
"correct" refusals were never actually enforced by `app.rag.similarity-threshold` — all
three unanswerable questions scored 0.44–0.46 similarity, comfortably above the 0.35 cutoff,
so the system retrieved real context for every one of them and simply relied on the LLM to
say "I don't know" on its own. With more granular, more topically-distinct chunks, that
LLM-level honesty broke on one case: asked for the Ask My Docs project's load-test response
time (a figure that doesn't exist for that project), it retrieved the dissertation project's
"2–3 ms" figure from a nearby chunk and confabulated an answer by attributing it to the
wrong project.

**Why the threshold isn't tuned further:** sorting all 20 questions by top-chunk similarity
shows the three unanswerable questions (0.440, 0.463, 0.464) sitting *inside* the answerable
range (0.423–0.629), not below it — e.g. one legitimately-answerable question scored 0.423,
lower than all three unanswerable ones. No single cutoff separates the groups; moving the
threshold up enough to catch the unanswerable questions also starts refusing real ones. This
is the overlap case `run_eval.py` warns about: a retrieval-quality limitation of pure
single-vector cosine similarity on a short, topically-dense document, not something a
threshold value can fix. It's the concrete evidence behind the hybrid search item below.

### Generalizing to a larger document

The config above (`chunk-size: 150`) was tuned against a one-page CV. To check it
generalizes, I re-ran the same eval methodology against a 72-page MSc dissertation
(a separate 20-question set in `eval/dissertation_questions.json`, same 12/5/3 split,
snippets verified against the actual ingested chunks) in a clean, single-document store.

**Run 1 — same config as the CV** (`chunk-size: 150`, `top-k: 4`):

| Metric | Result |
| --- | --- |
| Retrieval accuracy (n=17) | 59% |
| Answer correctness (n=17) | 71% |
| Out-of-scope questions correctly declined | 3 of 3 |

Retrieval was noticeably worse than on the CV. The reason: `top-k: 4` retrieves >50% of
a 7-chunk CV every query, but only ~2% of this document's 199 chunks. A 72-page
dissertation also repeats its core concepts (token bucket, Isolation Forest, CRDT) across
the Background, Methods, Results, and Discussion chapters, so several similarly-worded
chunks from the *wrong* chapter compete for the top-4 slots ahead of the one chunk that
actually has the specific fact asked.

**Run 2 — raised top-k** (`chunk-size: 150`, `top-k: 8`):

| Metric | Result |
| --- | --- |
| Retrieval accuracy (n=17) | 71% |
| Answer correctness (n=17) | 76% |
| Out-of-scope questions correctly declined | 3 of 3 |

Raising `top-k` recovered most of the gap (retrieval +12pp, answer correctness +5pp) by
giving the correct chunk more chances to be included even when it isn't ranked first. But
5 of the 20 questions still missed retrieval even at `top-k: 8` out of 199 chunks — for
those, the correct chunk isn't in the top 8 by cosine similarity at all, which `top-k` can't
fix by itself. The similarity-overlap problem from the CV run also persists unchanged here
(unanswerable questions scored up to 0.620, above the 0.448 minimum for answerable ones),
exactly as expected since `top-k` doesn't touch individual chunk similarity scores.

**Takeaway:** `chunk-size` and `top-k` both need to scale with corpus size, and neither
fixes the deeper problem — a document that discusses the same concept in multiple chapters
defeats pure single-vector similarity search regardless of tuning. That's the concrete,
two-document case for hybrid search (or a reranking step) on the roadmap below, rather
than continuing to chase threshold/top-k values on a single corpus.

## Sample output

Tested end-to-end against my own CV, ingested via the `/documents` endpoint. `retrieved`
isn't decoration — it's the actual evidence for the answer, with a similarity score per
chunk, which is what the eval harness above scores retrieval accuracy from.

**Query:**
```bash
curl -X POST http://localhost:8080/ask \
  -H "Content-Type: application/json" \
  -d '{"question": "What did this person do at UnitedHealth Group?"}'
```

**Response:**
```json
{
  "question": "What did this person do at UnitedHealth Group?",
  "answer": "This person optimized real-time data streaming and cross-system communication for millions of health records, reducing backend response times by 35% and achieving sub-second latency via decoupled Java Spring Boot microservices, secure REST APIs, and Apache Kafka. They engineered Apache Kafka event-driven data routing streams, reducing downstream server processing loads by 75% compared to legacy synchronous architectures. Additionally, they containerized and deployed core HC3 applications onto AWS using Docker, maintaining high availability across multi-region environments for 500,000+ active users, and accelerated code-to-production timelines through automated CI/CD pipelines with integrated testing for Java and Python microservices.",
  "answered": true,
  "retrieved": [
    {
      "source": "Amritpal_Singh_CV_md.docx",
      "similarity": 0.562,
      "text": "Software Engineer – UnitedHealth Group (Optum) | India ... Optimized real-time data streaming and cross-system communication for millions of health records, reducing backend response times by 35% and achieving sub-second latency via decoupled Java Spring Boot microservices, secure REST APIs, and Apache Kafka. ..."
    },
    {
      "source": "Amritpal_Singh_CV_md.docx",
      "similarity": 0.391,
      "text": "Amritpal Singh ... Java backend engineer with 3 years of production experience building REST APIs, microservices and event-driven data services on a regulated healthcare platform at UnitedHealth Group (Optum), serving 500,000+ users. ..."
    },
    {
      "source": "Amritpal_Singh_CV_md.docx",
      "similarity": 0.351,
      "text": "Safeguarded data integrity and access security for downstream systems like Advocate4Me ... ENGINEERING PROJECTS Technical Assessment Platform ..."
    }
  ]
}
```

Three chunks cleared `similarity-threshold: 0.35` and were fed to the LLM as context — the
third barely, at 0.351. Nothing below that line reaches the model; that's the refusal path
from the Evaluation section above, visible in a live response instead of just asserted.

## Known limitations / roadmap

This is a v1 focused on the core RAG loop end-to-end. Deliberately not
included yet, to keep scope tight:

- [ ] Hybrid search (keyword + vector) instead of pure similarity search
- [ ] Whole-document summarization ("What is this document about?" isn't answerable by
  top-k retrieval at all — no fixed set of chunks represents the whole document, so this
  needs a map-reduce pass over every chunk, not a similarity search)
- [ ] Observability — log token usage, latency, retrieval relevance per query
- [ ] Multi-document filtering (currently searches across all ingested docs)
- [ ] Auth on the endpoints
- [x] Automated tests

## What this demonstrates

- LLM integration (prompt construction, calling chat + embedding APIs, handling responses)
- Vector databases (embeddings, similarity search, pgvector as a Postgres extension)
- RAG pattern (retrieval, augmentation, generation) end-to-end, not just a wrapper around a chat API
