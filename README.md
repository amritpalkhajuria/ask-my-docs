# Ask My Docs — RAG Q&A API (Spring Boot + Spring AI)

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

<<<<<<< HEAD
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

Tested end-to-end against my own CV, ingested via the `/documents` endpoint.

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
  "answer": "At UnitedHealth Group, the person designed, developed, and maintained RESTful APIs in Java (Spring Boot) for a high-volume enterprise healthcare platform, reducing backend response times by 35%. They implemented OAuth2 authentication and authorization in Java (Spring Security) for over 500,000 users with full HIPAA compliance, gaining hands-on experience with access management and regulated data handling in production. They engineered Java backend services processing large-scale healthcare data pipelines, reducing downstream processing load by 75% through efficient service architecture. Additionally, they optimized SQL queries and redesigned database schemas with Hibernate/JPA for large datasets, reducing latency and improving data retrieval reliability. They also collaborated with cross-functional Agile teams to design, develop, test, and deploy maintainable backend services."
}
```

**Query:**
```bash
curl -X POST http://localhost:8080/ask \
  -H "Content-Type: application/json" \
  -d '{"question": "What is their dissertation about?"}'
```

**Response:**
```json
{
  "question": "What is their dissertation about?",
  "answer": "Their dissertation is about designing and implementing a hybrid rate-limiting middleware in Java (Spring Boot) that combines Token Bucket, Sliding Window, and Isolation Forest anomaly detection to block malicious requests while tolerating legitimate traffic bursts."
}
```

Both answers are grounded entirely in the ingested document — no hallucinated details, no generic LLM knowledge substituted in.

## Known limitations / roadmap

This is a v1 focused on the core RAG loop end-to-end. Deliberately not
included yet, to keep scope tight:

- [ ] Hybrid search (keyword + vector) instead of pure similarity search
- [ ] Observability — log token usage, latency, retrieval relevance per query
- [ ] Multi-document filtering (currently searches across all ingested docs)
- [ ] Auth on the endpoints
- [x] Automated tests

## What this demonstrates

- LLM integration (prompt construction, calling chat + embedding APIs, handling responses)
- Vector databases (embeddings, similarity search, pgvector as a Postgres extension)
- RAG pattern (retrieval, augmentation, generation) end-to-end, not just a wrapper around a chat API
