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
- [ ] Automated tests

## What this demonstrates

- LLM integration (prompt construction, calling chat + embedding APIs, handling responses)
- Vector databases (embeddings, similarity search, pgvector as a Postgres extension)
- RAG pattern (retrieval, augmentation, generation) end-to-end, not just a wrapper around a chat API
