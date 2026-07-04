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
export OPENAI_API_KEY=sk-...

# 3. Run the app
./mvnw spring-boot:run
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

## Known limitations / roadmap

This is a v1 focused on the core RAG loop end-to-end. Deliberately not
included yet, to keep scope tight:

- [ ] Hybrid search (keyword + vector) instead of pure similarity search
- [ ] Observability — log token usage, latency, retrieval relevance per query
- [ ] Multi-document filtering (currently searches across all ingested docs)
- [ ] Auth on the endpoints
- [ ] Automated tests

## What this demonstrates

- LLM integration (prompt construction, calling chat + embedding APIs, handling responses)
- Vector databases (embeddings, similarity search, pgvector as a Postgres extension)
- RAG pattern (retrieval, augmentation, generation) end-to-end, not just a wrapper around a chat API
