# ask-my-docs

RAG document Q&A API. Java 17, Spring Boot 3.3.4, Spring AI 1.0.0-M3, PostgreSQL + pgvector,
OpenAI (`text-embedding-3-small` for embeddings, `gpt-4o-mini` for chat).

## Commands

- `docker compose up -d` — Postgres with pgvector on port 5433
- `mvn spring-boot:run` — needs `OPENAI_API_KEY` exported
- `mvn test` — full suite; needs Docker for the Testcontainers integration test
- `python3 eval/run_eval.py --document-id <id>` — scores retrieval, answer correctness and
  refusal rate against one ingested document (`/ask` is scoped by `documentId`, see below)

## Constraints

**Spring AI 1.0.0-M3 specifically.** The API changed across milestones — do not apply
patterns from later versions. In M3: embeddings are `float[]` (not `List<Double>`),
`Document.getContent()` (not `getText()`), `SearchRequest.query(q).withTopK(n)
.withSimilarityThreshold(d)` where the threshold is cosine *similarity* and pgvector converts
it to `1 - threshold` internally, and the fluent chat interfaces are
`ChatClient.ChatClientRequestSpec` and `ChatClient.CallResponseSpec`. If something doesn't
compile, check the actual M3 signature rather than guessing a newer one.

**No test may call a paid API.** Unit tests mock the LLM. `RagIntegrationTest` uses
`HashingEmbeddingModel`, a deterministic offline stand-in at 1536 dimensions. Keep it that
way — CI has no OpenAI key.

**Do not assert on generated answer text.** Pinning an LLM's output to an expected string
gives a test that fails on model updates and measures nothing. Generation quality is measured
by `eval/`, not by JUnit.

**The refusal path is load-bearing.** When no chunk clears
`app.rag.similarity-threshold`, `QueryService` returns a canned "I don't know" *without
calling the LLM*. Do not "simplify" this into a prompt instruction — the whole point is that
refusal is enforced by the system rather than requested of the model. The eval measures it.

**`AskResponse.retrieved` is not decoration.** The eval harness scores retrieval accuracy
from it, separately from answer correctness. Don't trim the response shape.

**`/documents` and `/ask` are public and unauthenticated, and multi-tenant via `documentId`.**
Every upload gets its own server-generated `documentId` (`IngestionService`); `QueryService`
filters every search to the requested `documentId`. Do not add a path that searches across
documentIds, and do not accept a client-supplied `documentId` on ingest — it must stay
server-generated, or an attacker could guess/collide with another visitor's ID.

## Conventions

- Constructor injection, no field injection
- Bad input is a 400 via `InvalidRequestException` + `ApiExceptionHandler`, never a 500
- Tuning knobs (`chunk-size`, `top-k`, `similarity-threshold`) live in `application.yml`
  under `app.rag.*`, not as constants in services
- Comments explain *why*, not what the line does
