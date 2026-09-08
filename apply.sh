#!/usr/bin/env bash
# apply.sh — writes the eval harness, tests and service changes into ask-my-docs.
#
# Run from the ROOT of your repo (the directory containing pom.xml):
#     bash apply.sh
#
# Overwrites 6 existing files and creates 16 new ones. Commit or stash first so
# `git diff` shows you exactly what changed.
set -euo pipefail

if [ ! -f pom.xml ]; then
  echo "error: no pom.xml here. cd to the root of the ask-my-docs repo first." >&2
  exit 1
fi

write() {
  mkdir -p "$(dirname "$1")"
  cat > "$1"
  echo "  wrote $1"
}

echo "Writing files..."

write '.github/workflows/ci.yml' <<'APPLY_EOF'
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    # Docker is available on this runner, which is what the Testcontainers
    # integration test needs. No OpenAI key is required: the unit tests mock the
    # LLM and the integration test uses a deterministic offline embedding model,
    # so nothing in CI calls a paid API.
    steps:
      - uses: actions/checkout@v4

      - name: Set up JDK 17
        uses: actions/setup-java@v4
        with:
          java-version: '17'
          distribution: 'temurin'
          cache: maven

      - name: Run tests
        run: mvn -B test

      - name: Publish test report
        uses: mikepenz/action-junit-report@v4
        if: always()
        with:
          report_paths: '**/target/surefire-reports/TEST-*.xml'
APPLY_EOF

write 'eval/questions.json' <<'APPLY_EOF'
{
  "document": "REPLACE_ME.pdf",
  "notes": "Ingest exactly this one document into a clean vector store before running the harness, otherwise chunks from other documents compete in the similarity search and the numbers mean nothing. 20 questions: 12 single_passage, 5 multi_passage, 3 unanswerable.",
  "questions": [
    {
      "id": "q01",
      "type": "single_passage",
      "question": "REPLACE: a question whose answer sits in one clearly identifiable passage.",
      "expected_snippets": [
        "an exact phrase, copied from the document, that must appear in at least one retrieved chunk"
      ],
      "answer_must_include": ["the key fact the answer has to contain"],
      "notes": ""
    },
    {
      "id": "q02",
      "type": "multi_passage",
      "question": "REPLACE: a question that can only be answered by combining two separate sections.",
      "expected_snippets": [
        "exact phrase from the first section",
        "exact phrase from the second section"
      ],
      "answer_must_include": ["fact from section one", "fact from section two"],
      "notes": "Retrieval counts as correct only if BOTH snippets appear across the retrieved chunks."
    },
    {
      "id": "q03",
      "type": "unanswerable",
      "question": "REPLACE: a plausible-sounding question this document genuinely does not answer.",
      "expected_snippets": [],
      "answer_must_include": [],
      "notes": "Make it adjacent to the document's subject matter, not absurd. 'What is the capital of France?' is trivially easy to decline; 'What is the retention period for audit logs?' against a document that covers audit logging but never states retention is the case that actually catches confabulation."
    },
    {
      "id": "q04",
      "type": "single_passage",
      "question": "What did this person do at UnitedHealth Group?",
      "expected_snippets": ["UnitedHealth"],
      "answer_must_include": ["Spring Boot", "OAuth2"],
      "notes": "Worked example against the CV, from the current README. Delete when you swap in the real document."
    },
    {
      "id": "q05",
      "type": "single_passage",
      "question": "What is their dissertation about?",
      "expected_snippets": ["rate-limiting"],
      "answer_must_include": ["Token Bucket", "Isolation Forest"],
      "notes": "Worked example against the CV. Delete when you swap in the real document."
    },
    {
      "id": "q06",
      "type": "unanswerable",
      "question": "What was their salary at UnitedHealth Group?",
      "expected_snippets": [],
      "answer_must_include": [],
      "notes": "Worked example: adjacent to content that exists (the UHG role) but not stated anywhere. This is the shape that catches confabulation."
    }
  ]
}
APPLY_EOF

write 'eval/run_eval.py' <<'APPLY_EOF'
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
APPLY_EOF

write 'pom.xml' <<'APPLY_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-parent</artifactId>
        <version>3.3.4</version>
        <relativePath/>
    </parent>

    <groupId>com.amritpal</groupId>
    <artifactId>ask-my-docs</artifactId>
    <version>0.0.1-SNAPSHOT</version>
    <name>ask-my-docs</name>
    <description>RAG demo: Spring Boot + Spring AI + pgvector + OpenAI</description>

    <properties>
        <java.version>17</java.version>
        <spring-ai.version>1.0.0-M3</spring-ai.version>
    </properties>

    <dependencyManagement>
        <dependencies>
            <!-- Spring AI BOM manages compatible versions of all Spring AI modules -->
            <dependency>
                <groupId>org.springframework.ai</groupId>
                <artifactId>spring-ai-bom</artifactId>
                <version>${spring-ai.version}</version>
                <type>pom</type>
                <scope>import</scope>
            </dependency>
        </dependencies>
    </dependencyManagement>

    <dependencies>
        <!-- Basic REST API support -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-web</artifactId>
        </dependency>

        <!-- Lets Spring AI call OpenAI for embeddings + chat completions -->
        <dependency>
            <groupId>org.springframework.ai</groupId>
            <artifactId>spring-ai-openai-spring-boot-starter</artifactId>
        </dependency>

        <!-- Lets Spring AI store/query vectors in Postgres via the pgvector extension -->
        <dependency>
            <groupId>org.springframework.ai</groupId>
            <artifactId>spring-ai-pgvector-store-spring-boot-starter</artifactId>
        </dependency>

        <!-- JDBC driver needed by the pgvector store to talk to Postgres -->
        <dependency>
            <groupId>org.postgresql</groupId>
            <artifactId>postgresql</artifactId>
        </dependency>

        <!-- Tika document reader: extracts text out of PDFs (and docx, etc.) for us -->
        <dependency>
            <groupId>org.springframework.ai</groupId>
            <artifactId>spring-ai-tika-document-reader</artifactId>
        </dependency>

        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-test</artifactId>
            <scope>test</scope>
        </dependency>

        <!-- Testcontainers: spins up real Postgres + pgvector for the integration test.
             Versions are managed by the Spring Boot parent, so none are pinned here. -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-testcontainers</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.testcontainers</groupId>
            <artifactId>junit-jupiter</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.testcontainers</groupId>
            <artifactId>postgresql</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>org.springframework.boot</groupId>
                <artifactId>spring-boot-maven-plugin</artifactId>
            </plugin>
        </plugins>
    </build>

    <repositories>
        <!-- Spring AI milestone builds aren't on Maven Central yet, so we need this repo -->
        <repository>
            <id>spring-milestones</id>
            <name>Spring Milestones</name>
            <url>https://repo.spring.io/milestone</url>
        </repository>
    </repositories>

</project>
APPLY_EOF

write 'src/main/java/com/amritpal/askmydocs/api/ApiExceptionHandler.java' <<'APPLY_EOF'
package com.amritpal.askmydocs.api;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

import java.util.Map;

/**
 * Turns bad input into 400s with a readable message, instead of leaking a 500.
 * Spring already maps a missing multipart part and unparseable JSON to 400; this
 * covers the application-level cases (empty file, unreadable file, blank question).
 */
@RestControllerAdvice
public class ApiExceptionHandler {

    @ExceptionHandler(InvalidRequestException.class)
    public ResponseEntity<Map<String, String>> handleInvalidRequest(InvalidRequestException ex) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST)
                .body(Map.of("error", "bad_request", "message", ex.getMessage()));
    }
}
APPLY_EOF

write 'src/main/java/com/amritpal/askmydocs/api/AskRequest.java' <<'APPLY_EOF'
package com.amritpal.askmydocs.api;

/**
 * Request body for POST /ask.
 *
 * <p>Replaces the previous {@code Map<String, String>}, which returned 500 for a body with
 * no "question" key: the null propagated into {@code Map.of(...)} and threw NPE inside the
 * controller. A missing or blank question is a client error, so it is validated here and
 * mapped to 400 by {@link ApiExceptionHandler}.
 */
public record AskRequest(String question) {

    public String requireQuestion() {
        if (question == null || question.isBlank()) {
            throw new InvalidRequestException("Field 'question' is required and must not be blank.");
        }
        return question;
    }
}
APPLY_EOF

write 'src/main/java/com/amritpal/askmydocs/api/AskResponse.java' <<'APPLY_EOF'
package com.amritpal.askmydocs.api;

import java.util.List;

/**
 * Response for POST /ask.
 *
 * <p>{@code answered} is the important field: it is {@code false} when no chunk cleared
 * the similarity threshold, meaning the service declined rather than asking the LLM to
 * improvise over irrelevant context. The eval harness scores refusal rate off this flag.
 *
 * <p>{@code retrieved} exposes what came back from the vector store, which lets us measure
 * retrieval accuracy independently of answer correctness — a wrong answer over the right
 * chunk is a prompting problem, a wrong answer over the wrong chunk is a retrieval problem,
 * and you cannot tell them apart from the answer text alone.
 */
public record AskResponse(
        String question,
        String answer,
        boolean answered,
        List<RetrievedChunk> retrieved) {

    public static AskResponse declined(String question, String answer) {
        return new AskResponse(question, answer, false, List.of());
    }
}
APPLY_EOF

write 'src/main/java/com/amritpal/askmydocs/api/InvalidRequestException.java' <<'APPLY_EOF'
package com.amritpal.askmydocs.api;

/** Client sent something we can't process — mapped to HTTP 400. */
public class InvalidRequestException extends RuntimeException {

    public InvalidRequestException(String message) {
        super(message);
    }

    public InvalidRequestException(String message, Throwable cause) {
        super(message, cause);
    }
}
APPLY_EOF

write 'src/main/java/com/amritpal/askmydocs/api/RetrievedChunk.java' <<'APPLY_EOF'
package com.amritpal.askmydocs.api;

import org.springframework.ai.document.Document;

/**
 * One chunk returned by the similarity search, flattened for the API response.
 *
 * <p>pgvector stores cosine <em>distance</em> in the chunk metadata under "distance";
 * similarity is {@code 1 - distance}, which is the same scale as the configured
 * similarity threshold.
 */
public record RetrievedChunk(String id, String source, double similarity, String text) {

    private static final String DISTANCE_KEY = "distance";
    private static final String SOURCE_KEY = "source";

    public static RetrievedChunk from(Document document) {
        Object distance = document.getMetadata().get(DISTANCE_KEY);
        double similarity = (distance instanceof Number n) ? 1.0d - n.doubleValue() : Double.NaN;
        Object source = document.getMetadata().get(SOURCE_KEY);

        return new RetrievedChunk(
                document.getId(),
                source == null ? "unknown" : source.toString(),
                similarity,
                document.getContent());
    }
}
APPLY_EOF

write 'src/main/java/com/amritpal/askmydocs/controller/DocumentController.java' <<'APPLY_EOF'
package com.amritpal.askmydocs.controller;

import com.amritpal.askmydocs.service.IngestionService;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.util.Map;

@RestController
public class DocumentController {

    private final IngestionService ingestionService;

    public DocumentController(IngestionService ingestionService) {
        this.ingestionService = ingestionService;
    }

    /**
     * Example usage (curl):
     *   curl -F "file=@/path/to/your.pdf" http://localhost:8080/documents
     */
    @PostMapping("/documents")
    public Map<String, Object> uploadDocument(@RequestParam("file") MultipartFile file) throws IOException {
        String filename = file.getOriginalFilename() == null ? "unnamed" : file.getOriginalFilename();
        int chunkCount = ingestionService.ingest(file.getBytes(), filename);

        return Map.of(
                "filename", filename,
                "chunksStored", chunkCount,
                "status", "ingested");
    }
}
APPLY_EOF

write 'src/main/java/com/amritpal/askmydocs/controller/QueryController.java' <<'APPLY_EOF'
package com.amritpal.askmydocs.controller;

import com.amritpal.askmydocs.api.AskRequest;
import com.amritpal.askmydocs.api.AskResponse;
import com.amritpal.askmydocs.service.QueryService;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class QueryController {

    private final QueryService queryService;

    public QueryController(QueryService queryService) {
        this.queryService = queryService;
    }

    /**
     * Example usage (curl):
     *   curl -X POST http://localhost:8080/ask \
     *     -H "Content-Type: application/json" \
     *     -d '{"question": "What experience does this candidate have with Kafka?"}'
     */
    @PostMapping("/ask")
    public AskResponse ask(@RequestBody AskRequest request) {
        return queryService.ask(request.requireQuestion());
    }
}
APPLY_EOF

write 'src/main/java/com/amritpal/askmydocs/service/IngestionService.java' <<'APPLY_EOF'
package com.amritpal.askmydocs.service;

import com.amritpal.askmydocs.api.InvalidRequestException;
import org.springframework.ai.document.Document;
import org.springframework.ai.reader.tika.TikaDocumentReader;
import org.springframework.ai.transformer.splitter.TokenTextSplitter;
import org.springframework.ai.vectorstore.VectorStore;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.io.ByteArrayResource;
import org.springframework.stereotype.Service;

import java.util.List;

@Service
public class IngestionService {

    static final String SOURCE_METADATA_KEY = "source";

    private final VectorStore vectorStore;
    private final TokenTextSplitter splitter;

    /**
     * Chunk size is configuration, not a constant. It is the main lever on retrieval quality:
     * chunks that are too large dilute the embedding and drag irrelevant text into the prompt,
     * chunks that are too small lose the context that made the passage meaningful. The eval
     * harness in {@code eval/} is how you find out which way to move it for a given corpus.
     */
    public IngestionService(VectorStore vectorStore,
                            @Value("${app.rag.chunk-size:800}") int chunkSize,
                            @Value("${app.rag.min-chunk-size-chars:350}") int minChunkSizeChars) {
        this.vectorStore = vectorStore;
        this.splitter = new TokenTextSplitter(chunkSize, minChunkSizeChars, 5, 10_000, true);
    }

    /**
     * Extracts text from the uploaded bytes (Tika handles PDF, DOCX, TXT), splits it into
     * chunks, tags each chunk with its source filename, and stores them — the vector store
     * embeds each chunk on the way in.
     *
     * <p>The guards matter more than they look. Without them an empty upload or a file Tika
     * can't parse produces zero chunks, {@code vectorStore.add} is called with an empty list,
     * and the endpoint cheerfully returns 200 with {@code chunksStored: 0}. The user believes
     * the document is searchable and every later question against it comes back empty.
     * Failing loudly at ingest time is the whole point.
     */
    public int ingest(byte[] fileBytes, String filename) {
        if (fileBytes == null || fileBytes.length == 0) {
            throw new InvalidRequestException("Uploaded file '" + filename + "' is empty.");
        }

        List<Document> rawDocuments;
        try {
            rawDocuments = new TikaDocumentReader(new ByteArrayResource(fileBytes)).get();
        } catch (RuntimeException ex) {
            throw new InvalidRequestException(
                    "Could not extract text from '" + filename + "' — unsupported or corrupt file type.", ex);
        }

        List<Document> chunks = splitter.apply(rawDocuments).stream()
                .filter(chunk -> chunk.getContent() != null && !chunk.getContent().isBlank())
                .toList();

        if (chunks.isEmpty()) {
            throw new InvalidRequestException(
                    "No extractable text found in '" + filename + "'. Scanned images need OCR first.");
        }

        chunks.forEach(chunk -> chunk.getMetadata().put(SOURCE_METADATA_KEY, filename));
        vectorStore.add(chunks);

        return chunks.size();
    }
}
APPLY_EOF

write 'src/main/java/com/amritpal/askmydocs/service/QueryService.java' <<'APPLY_EOF'
package com.amritpal.askmydocs.service;

import com.amritpal.askmydocs.api.AskResponse;
import com.amritpal.askmydocs.api.RetrievedChunk;
import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.document.Document;
import org.springframework.ai.vectorstore.SearchRequest;
import org.springframework.ai.vectorstore.VectorStore;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.util.List;
import java.util.stream.Collectors;

/**
 * The RAG loop.
 *
 * <p>RETRIEVAL — embed the question, similarity-search the vector store.
 * <p>AUGMENTATION — stitch the retrieved chunks into the prompt as context.
 * <p>GENERATION — the LLM answers from that context.
 *
 * <p>Two deliberate changes from the naive version:
 *
 * <p>1. A <b>similarity threshold</b>. Plain {@code topK=4} always returns four chunks, even
 * for a question the corpus cannot answer — the nearest four chunks in a small store may be
 * nowhere near the query. Handing those to the model and asking it not to hallucinate is
 * asking it to ignore everything you gave it. Filtering first means an out-of-scope question
 * usually retrieves nothing.
 *
 * <p>2. A <b>hard refusal path</b>. When nothing clears the threshold we return a canned
 * "I don't know" without calling the LLM at all. That makes refusal a property of the system
 * rather than a hope about the prompt, and it saves a token spend on every junk query.
 *
 * <p>The threshold is a tunable, not a constant: run {@code eval/run_eval.py}, look at the
 * similarity distribution it prints for answerable vs. unanswerable questions, and set it in
 * the gap between them.
 */
@Service
public class QueryService {

    static final String DECLINED_ANSWER =
            "I don't know — nothing in the ingested documents is relevant to that question.";

    private final VectorStore vectorStore;
    private final ChatClient chatClient;
    private final int topK;
    private final double similarityThreshold;

    public QueryService(VectorStore vectorStore,
                        ChatClient.Builder chatClientBuilder,
                        @Value("${app.rag.top-k:4}") int topK,
                        @Value("${app.rag.similarity-threshold:0.35}") double similarityThreshold) {
        this.vectorStore = vectorStore;
        this.chatClient = chatClientBuilder.build();
        this.topK = topK;
        this.similarityThreshold = similarityThreshold;
    }

    public AskResponse ask(String question) {
        SearchRequest searchRequest = SearchRequest.query(question)
                .withTopK(topK)
                .withSimilarityThreshold(similarityThreshold);

        List<Document> relevantChunks = vectorStore.similaritySearch(searchRequest);

        if (relevantChunks == null || relevantChunks.isEmpty()) {
            return AskResponse.declined(question, DECLINED_ANSWER);
        }

        String answer = chatClient.prompt()
                .user(buildPrompt(relevantChunks, question))
                .call()
                .content();

        List<RetrievedChunk> retrieved = relevantChunks.stream()
                .map(RetrievedChunk::from)
                .toList();

        return new AskResponse(question, answer, true, retrieved);
    }

    /**
     * Package-private and static so the prompt assembly can be asserted directly, without
     * mocking the LLM. This is the part that most often breaks silently — a context block
     * that quietly loses a chunk still returns a fluent, wrong answer.
     */
    static String buildPrompt(List<Document> chunks, String question) {
        String context = chunks.stream()
                .map(Document::getContent)
                .collect(Collectors.joining("\n---\n"));

        return """
                You are a helpful assistant. Answer the question using ONLY the
                context below. If the answer isn't in the context, say you don't know.
                Do not use general knowledge to fill gaps.

                Context:
                %s

                Question: %s
                """.formatted(context, question);
    }
}
APPLY_EOF

write 'src/main/resources/application.yml' <<'APPLY_EOF'
spring:
  application:
    name: ask-my-docs

  # Connection to the Postgres container started by docker-compose
  datasource:
    url: jdbc:postgresql://localhost:5433/ask_my_docs
    username: postgres
    password: postgres

  ai:
    openai:
      # Never hardcode this — set it as an environment variable before running the app:
      #   export OPENAI_API_KEY=sk-...   (Mac/Linux)

      api-key: ${OPENAI_API_KEY}
      chat:
        options:
          model: gpt-4o-mini   # cheap + fast, plenty good enough for a demo
      embedding:
        options:
          model: text-embedding-3-small

    vectorstore:
      pgvector:
        # Must match the embedding model's output size (text-embedding-3-small = 1536)
        dimensions: 1536
        # Lets Spring AI auto-create the vector_store table + pgvector extension on startup
        initialize-schema: true

# RAG tuning knobs. These are the levers the eval harness measures, so they live in
# config rather than being buried in the services.
app:
  rag:
    # Chunk size in tokens. Smaller chunks give sharper embeddings but lose surrounding
    # context; larger chunks do the reverse. 800 is the Spring AI default.
    chunk-size: 800
    min-chunk-size-chars: 350
    # How many chunks to feed the model as context.
    top-k: 4
    # Minimum cosine similarity (1 - distance) for a chunk to be used at all. Below this,
    # the service declines instead of asking the LLM to answer from irrelevant context.
    # Calibrate from `python3 eval/run_eval.py`, which prints the similarity distribution
    # for answerable vs. unanswerable questions.
    similarity-threshold: 0.35

server:
  port: 8080
APPLY_EOF

write 'src/test/java/com/amritpal/askmydocs/RagIntegrationTest.java' <<'APPLY_EOF'
package com.amritpal.askmydocs;

import com.amritpal.askmydocs.service.IngestionService;
import com.amritpal.askmydocs.support.HashingEmbeddingModel;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.ai.document.Document;
import org.springframework.ai.embedding.EmbeddingModel;
import org.springframework.ai.vectorstore.SearchRequest;
import org.springframework.ai.vectorstore.VectorStore;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;

import java.nio.charset.StandardCharsets;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * The one test that exercises the real path: real Postgres, real pgvector extension, real
 * schema initialisation, real chunking, real similarity search. Only two things are faked —
 * the embedding model (deterministic, offline) and the chat model (never invoked, because
 * this test stops at retrieval).
 *
 * <p>That split is deliberate. Retrieval is the part of a RAG system that can be asserted
 * deterministically; generation is not, and pinning it to an exact string would give a test
 * that fails whenever the model is updated. Generation quality is measured instead by the
 * eval harness in {@code eval/}, which is the right tool for a probabilistic component.
 *
 * <p>Requires Docker. Runs on GitHub Actions' ubuntu-latest runner as-is.
 */
@SpringBootTest(properties = {
        // Small chunks so a short fixture document still exercises multi-chunk retrieval.
        "app.rag.chunk-size=40",
        "app.rag.min-chunk-size-chars=120"
})
@Testcontainers
@Import(RagIntegrationTest.OfflineEmbeddingConfig.class)
class RagIntegrationTest {

    @Container
    @ServiceConnection
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>(
            DockerImageName.parse("pgvector/pgvector:pg16").asCompatibleSubstituteFor("postgres"));

    @DynamicPropertySource
    static void openAiProperties(DynamicPropertyRegistry registry) {
        // The OpenAI auto-configuration needs a key present to start; nothing here calls out.
        registry.add("spring.ai.openai.api-key", () -> "test-key-not-used");
    }

    @TestConfiguration
    static class OfflineEmbeddingConfig {

        @Bean
        @Primary
        EmbeddingModel offlineEmbeddingModel() {
            return new HashingEmbeddingModel();
        }
    }

    @Autowired
    private IngestionService ingestionService;

    @Autowired
    private VectorStore vectorStore;

    @Autowired
    private JdbcTemplate jdbcTemplate;

    @BeforeEach
    void clearVectorStore() {
        jdbcTemplate.execute("DELETE FROM vector_store");
    }

    @Test
    @DisplayName("ingests a document and retrieves the chunk that actually answers the query")
    void ingestsAndRetrievesTheCorrectChunk() {
        int chunksStored = ingestionService.ingest(handbook(), "security-handbook.txt");
        assertThat(chunksStored).isGreaterThan(1);

        // The vector store really wrote rows — not a mock that swallowed them.
        Integer rowCount = jdbcTemplate.queryForObject("SELECT count(*) FROM vector_store", Integer.class);
        assertThat(rowCount).isEqualTo(chunksStored);

        List<Document> results = vectorStore.similaritySearch(
                SearchRequest.query("How often must encryption keys be rotated?")
                        .withTopK(2)
                        .withSimilarityThresholdAll());

        assertThat(results).isNotEmpty();
        assertThat(results.get(0).getContent())
                .as("the key-rotation passage should outrank the unrelated sections")
                .contains("rotated every ninety days");
        assertThat(results.get(0).getMetadata())
                .containsEntry("source", "security-handbook.txt")
                .containsKey("distance");
    }

    @Test
    @DisplayName("returns nothing when no chunk clears the similarity threshold")
    void returnsNothingWhenNothingClearsTheThreshold() {
        ingestionService.ingest(handbook(), "security-handbook.txt");

        List<Document> results = vectorStore.similaritySearch(
                SearchRequest.query("zzqqx unrelated vocabulary nowhere in the corpus")
                        .withTopK(4)
                        .withSimilarityThreshold(0.9d));

        // This is what makes the refusal path in QueryService reachable in production.
        assertThat(results).isEmpty();
    }

    private static byte[] handbook() {
        String text = """
                Access control

                Every service account is provisioned through the central identity provider.
                Requests are authorised per endpoint and audited to the shared log sink.
                Reviews of standing access happen at the start of each quarter.

                Key management

                Encryption keys are rotated every ninety days by the platform team.
                A rotation is recorded in the key ledger together with the operator who
                performed it, and the previous key is retained only until the next rotation
                completes so that in-flight payloads can still be decrypted.

                Incident handling

                Pager alerts route to the on-call engineer, who declares a severity and opens
                a channel. Customer communication is drafted by the incident commander before
                any external statement goes out, and a written review follows within a week.
                """;
        return text.getBytes(StandardCharsets.UTF_8);
    }
}
APPLY_EOF

write 'src/test/java/com/amritpal/askmydocs/controller/DocumentControllerTest.java' <<'APPLY_EOF'
package com.amritpal.askmydocs.controller;

import com.amritpal.askmydocs.api.InvalidRequestException;
import com.amritpal.askmydocs.service.IngestionService;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.test.web.servlet.MockMvc;

import java.nio.charset.StandardCharsets;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.multipart;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(DocumentController.class)
class DocumentControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private IngestionService ingestionService;

    @Test
    @DisplayName("valid upload returns 200 with the stored chunk count")
    void validUploadReturns200() throws Exception {
        when(ingestionService.ingest(any(byte[].class), anyString())).thenReturn(7);

        MockMultipartFile file = new MockMultipartFile(
                "file", "handbook.txt", "text/plain", "some readable text".getBytes(StandardCharsets.UTF_8));

        mockMvc.perform(multipart("/documents").file(file))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.filename").value("handbook.txt"))
                .andExpect(jsonPath("$.chunksStored").value(7))
                .andExpect(jsonPath("$.status").value("ingested"));
    }

    @Test
    @DisplayName("request with no file part returns 400")
    void missingFileReturns400() throws Exception {
        mockMvc.perform(multipart("/documents"))
                .andExpect(status().isBadRequest());
    }

    @Test
    @DisplayName("empty file is rejected with 400 rather than reported as a successful ingest")
    void emptyFileReturns400() throws Exception {
        when(ingestionService.ingest(any(byte[].class), anyString()))
                .thenThrow(new InvalidRequestException("Uploaded file 'empty.txt' is empty."));

        MockMultipartFile file = new MockMultipartFile("file", "empty.txt", "text/plain", new byte[0]);

        mockMvc.perform(multipart("/documents").file(file))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("bad_request"));
    }

    @Test
    @DisplayName("a file with no extractable text is rejected with 400")
    void unsupportedFileReturns400() throws Exception {
        when(ingestionService.ingest(any(byte[].class), anyString()))
                .thenThrow(new InvalidRequestException("No extractable text found in 'scan.png'."));

        MockMultipartFile file = new MockMultipartFile(
                "file", "scan.png", "image/png", new byte[] {0x1, 0x2, 0x3});

        mockMvc.perform(multipart("/documents").file(file))
                .andExpect(status().isBadRequest());
    }

    @Test
    @DisplayName("a plain (non-multipart) POST returns 4xx rather than reaching the service")
    void nonMultipartPostIsRejected() throws Exception {
        mockMvc.perform(post("/documents").content("not a multipart body"))
                .andExpect(status().is4xxClientError());
    }
}
APPLY_EOF

write 'src/test/java/com/amritpal/askmydocs/controller/QueryControllerTest.java' <<'APPLY_EOF'
package com.amritpal.askmydocs.controller;

import com.amritpal.askmydocs.api.AskResponse;
import com.amritpal.askmydocs.api.RetrievedChunk;
import com.amritpal.askmydocs.service.QueryService;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

import java.util.List;

import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(QueryController.class)
class QueryControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private QueryService queryService;

    @Test
    @DisplayName("valid question returns 200 with the answer and the retrieved chunks")
    void validQuestionReturns200() throws Exception {
        when(queryService.ask("How are keys rotated?")).thenReturn(new AskResponse(
                "How are keys rotated?",
                "Every 90 days.",
                true,
                List.of(new RetrievedChunk("c1", "handbook.pdf", 0.81, "Keys rotate every 90 days."))));

        mockMvc.perform(post("/ask")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"question\": \"How are keys rotated?\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.answer").value("Every 90 days."))
                .andExpect(jsonPath("$.answered").value(true))
                .andExpect(jsonPath("$.retrieved[0].source").value("handbook.pdf"));
    }

    @Test
    @DisplayName("an out-of-scope question returns 200 with answered=false")
    void outOfScopeQuestionReturnsAnsweredFalse() throws Exception {
        when(queryService.ask(anyString()))
                .thenReturn(AskResponse.declined("Who won the 1998 World Cup?", "I don't know."));

        mockMvc.perform(post("/ask")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"question\": \"Who won the 1998 World Cup?\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.answered").value(false))
                .andExpect(jsonPath("$.retrieved").isEmpty());
    }

    @Test
    @DisplayName("body with no question field returns 400, not 500")
    void missingQuestionFieldReturns400() throws Exception {
        mockMvc.perform(post("/ask")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"query\": \"wrong field name\"}"))
                .andExpect(status().isBadRequest());

        verifyNoInteractions(queryService);
    }

    @Test
    @DisplayName("blank question returns 400")
    void blankQuestionReturns400() throws Exception {
        mockMvc.perform(post("/ask")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"question\": \"   \"}"))
                .andExpect(status().isBadRequest());

        verifyNoInteractions(queryService);
    }

    @Test
    @DisplayName("malformed JSON returns 400")
    void malformedJsonReturns400() throws Exception {
        mockMvc.perform(post("/ask")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"question\": "))
                .andExpect(status().isBadRequest());

        verifyNoInteractions(queryService);
    }
}
APPLY_EOF

write 'src/test/java/com/amritpal/askmydocs/service/IngestionServiceTest.java' <<'APPLY_EOF'
package com.amritpal.askmydocs.service;

import com.amritpal.askmydocs.api.InvalidRequestException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Captor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.ai.document.Document;
import org.springframework.ai.vectorstore.VectorStore;

import java.nio.charset.StandardCharsets;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;

/**
 * Real Tika + real splitter, mocked vector store — so nothing here calls OpenAI, but the
 * text extraction and chunking that actually decide retrieval quality are exercised for real.
 */
@ExtendWith(MockitoExtension.class)
class IngestionServiceTest {

    private static final String HEAD_SENTINEL = "ALPHA_SENTINEL_MARKER";
    private static final String TAIL_SENTINEL = "OMEGA_SENTINEL_MARKER";

    @Mock
    private VectorStore vectorStore;

    @Captor
    private ArgumentCaptor<List<Document>> chunksCaptor;

    private IngestionService ingestionService;

    @BeforeEach
    void setUp() {
        // Production defaults, stated explicitly so a config change can't silently
        // change what this test is asserting about chunk boundaries.
        ingestionService = new IngestionService(vectorStore, 800, 350);
    }

    @Test
    @DisplayName("splits a long document into multiple chunks and stores them all")
    void splitsLongDocumentIntoChunks() {
        byte[] file = longDocument().getBytes(StandardCharsets.UTF_8);

        int stored = ingestionService.ingest(file, "handbook.txt");

        verify(vectorStore).add(chunksCaptor.capture());
        List<Document> chunks = chunksCaptor.getValue();

        assertThat(stored).isEqualTo(chunks.size());
        assertThat(chunks)
                .as("a document well over the splitter's chunk size should produce several chunks")
                .hasSizeGreaterThan(1);

        // Nothing is silently dropped at either boundary — the classic chunking bug.
        String reassembled = String.join(" ", chunks.stream().map(Document::getContent).toList());
        assertThat(reassembled).contains(HEAD_SENTINEL, TAIL_SENTINEL);
    }

    @Test
    @DisplayName("keeps a short document as a single chunk")
    void keepsShortDocumentAsSingleChunk() {
        byte[] file = (HEAD_SENTINEL + " A short note about rate limiting in Spring Boot. " + TAIL_SENTINEL)
                .getBytes(StandardCharsets.UTF_8);

        int stored = ingestionService.ingest(file, "note.txt");

        assertThat(stored).isEqualTo(1);
    }

    @Test
    @DisplayName("tags every chunk with its source filename so answers are attributable")
    void tagsEveryChunkWithSourceFilename() {
        ingestionService.ingest(longDocument().getBytes(StandardCharsets.UTF_8), "handbook.txt");

        verify(vectorStore).add(chunksCaptor.capture());

        assertThat(chunksCaptor.getValue())
                .allSatisfy(chunk -> assertThat(chunk.getMetadata()).containsEntry("source", "handbook.txt"));
    }

    @Test
    @DisplayName("rejects an empty file instead of storing zero chunks and reporting success")
    void rejectsEmptyFile() {
        assertThatThrownBy(() -> ingestionService.ingest(new byte[0], "empty.txt"))
                .isInstanceOf(InvalidRequestException.class)
                .hasMessageContaining("empty");

        verifyNoInteractions(vectorStore);
    }

    @Test
    @DisplayName("rejects a file with no extractable text")
    void rejectsFileWithNoExtractableText() {
        // Bytes that carry no recoverable text: a truncated binary blob.
        byte[] junk = new byte[] {0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07};

        assertThatThrownBy(() -> ingestionService.ingest(junk, "broken.bin"))
                .isInstanceOf(InvalidRequestException.class);

        verifyNoInteractions(vectorStore);
    }

    private static String longDocument() {
        StringBuilder text = new StringBuilder(HEAD_SENTINEL).append("\n\n");
        for (int paragraph = 0; paragraph < 60; paragraph++) {
            text.append("Section ").append(paragraph)
                .append(" describes how the service handles requests, validates input, ")
                .append("persists results and reports failures to the caller. ")
                .append("Operators should monitor latency and error rates for this path. \n\n");
        }
        return text.append(TAIL_SENTINEL).append("\n").toString();
    }
}
APPLY_EOF

write 'src/test/java/com/amritpal/askmydocs/service/QueryServiceTest.java' <<'APPLY_EOF'
package com.amritpal.askmydocs.service;

import com.amritpal.askmydocs.api.AskResponse;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.document.Document;
import org.springframework.ai.vectorstore.SearchRequest;
import org.springframework.ai.vectorstore.VectorStore;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.within;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * The LLM is mocked out entirely. What is under test is the part we control: which search
 * request goes to the vector store, what gets assembled into the prompt, and whether the
 * service declines when retrieval comes back empty.
 */
class QueryServiceTest {

    private static final int TOP_K = 4;
    private static final double THRESHOLD = 0.5d;

    private VectorStore vectorStore;
    private ChatClient chatClient;
    private ChatClient.ChatClientRequestSpec requestSpec;
    private ChatClient.CallResponseSpec responseSpec;
    private QueryService queryService;

    @BeforeEach
    void setUp() {
        vectorStore = mock(VectorStore.class);
        chatClient = mock(ChatClient.class);
        requestSpec = mock(ChatClient.ChatClientRequestSpec.class);
        responseSpec = mock(ChatClient.CallResponseSpec.class);

        ChatClient.Builder builder = mock(ChatClient.Builder.class);
        when(builder.build()).thenReturn(chatClient);

        queryService = new QueryService(vectorStore, builder, TOP_K, THRESHOLD);
    }

    /** Wires the fluent ChatClient chain. Only called by tests that expect the LLM to be hit. */
    private void stubChatClient(String answer) {
        when(chatClient.prompt()).thenReturn(requestSpec);
        when(requestSpec.user(anyString())).thenReturn(requestSpec);
        when(requestSpec.call()).thenReturn(responseSpec);
        when(responseSpec.content()).thenReturn(answer);
    }

    @Test
    @DisplayName("searches with the configured topK and similarity threshold")
    void searchesWithConfiguredTopKAndThreshold() {
        stubChatClient("an answer");
        when(vectorStore.similaritySearch(any(SearchRequest.class))).thenReturn(List.of(chunk("some context", 0.2)));

        queryService.ask("How is authentication handled?");

        ArgumentCaptor<SearchRequest> captor = ArgumentCaptor.forClass(SearchRequest.class);
        verify(vectorStore).similaritySearch(captor.capture());

        assertThat(captor.getValue().getQuery()).isEqualTo("How is authentication handled?");
        assertThat(captor.getValue().getTopK()).isEqualTo(TOP_K);
        assertThat(captor.getValue().getSimilarityThreshold()).isEqualTo(THRESHOLD);
    }

    @Test
    @DisplayName("declines without calling the LLM when nothing clears the similarity threshold")
    void declinesWhenNoChunksClearTheThreshold() {
        when(vectorStore.similaritySearch(any(SearchRequest.class))).thenReturn(List.of());

        AskResponse response = queryService.ask("What is the airspeed velocity of an unladen swallow?");

        assertThat(response.answered()).isFalse();
        assertThat(response.answer()).isEqualTo(QueryService.DECLINED_ANSWER);
        assertThat(response.retrieved()).isEmpty();

        // The point of the refusal path: no context means no LLM call at all, so there is
        // nothing for the model to confabulate from and nothing spent on tokens.
        verifyNoInteractions(chatClient);
    }

    @Test
    @DisplayName("declines when the vector store returns null rather than an empty list")
    void declinesOnNullSearchResult() {
        when(vectorStore.similaritySearch(any(SearchRequest.class))).thenReturn(null);

        AskResponse response = queryService.ask("Anything?");

        assertThat(response.answered()).isFalse();
        verifyNoInteractions(chatClient);
    }

    @Test
    @DisplayName("surfaces every retrieved chunk with its source and similarity")
    void surfacesRetrievedChunks() {
        stubChatClient("Keys rotate every 90 days.");
        when(vectorStore.similaritySearch(any(SearchRequest.class)))
                .thenReturn(List.of(chunk("Keys rotate every 90 days.", 0.13), chunk("Key storage.", 0.42)));

        AskResponse response = queryService.ask("How often are keys rotated?");

        assertThat(response.answered()).isTrue();
        assertThat(response.answer()).isEqualTo("Keys rotate every 90 days.");
        assertThat(response.retrieved()).hasSize(2);
        assertThat(response.retrieved().get(0).source()).isEqualTo("security-handbook.pdf");
        // similarity = 1 - cosine distance
        assertThat(response.retrieved().get(0).similarity()).isCloseTo(0.87d, within(1e-9));
    }

    @Test
    @DisplayName("prompt contains every retrieved chunk, the question, and the context-only instruction")
    void promptContainsAllContextAndQuestion() {
        String prompt = QueryService.buildPrompt(
                List.of(chunk("First relevant passage.", 0.1), chunk("Second relevant passage.", 0.2)),
                "What do the passages say?");

        assertThat(prompt)
                .contains("First relevant passage.")
                .contains("Second relevant passage.")
                .contains("What do the passages say?")
                .contains("ONLY");
    }

    private static Document chunk(String content, double distance) {
        return new Document(content, Map.of("source", "security-handbook.pdf", "distance", distance));
    }
}
APPLY_EOF

write 'src/test/java/com/amritpal/askmydocs/support/HashingEmbeddingModel.java' <<'APPLY_EOF'
package com.amritpal.askmydocs.support;

import org.springframework.ai.document.Document;
import org.springframework.ai.embedding.Embedding;
import org.springframework.ai.embedding.EmbeddingModel;
import org.springframework.ai.embedding.EmbeddingRequest;
import org.springframework.ai.embedding.EmbeddingResponse;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * A deterministic, offline stand-in for OpenAI's embedding model.
 *
 * <p>Each text is turned into a hashed bag-of-words vector, L2-normalised. Two texts that
 * share vocabulary end up with a high cosine similarity; unrelated texts end up near zero.
 * That is enough for the integration test to assert <em>which chunk ranks first</em> for a
 * query, which is the behaviour that matters, while keeping CI free, fast and deterministic.
 *
 * <p>What it deliberately does not do is model semantics: "car" and "automobile" are
 * unrelated to it. So absolute similarity scores from this model are not comparable to
 * production ones, and the real similarity threshold must be calibrated against the real
 * embedding model via the eval harness — not inferred from this test.
 *
 * <p>Dimension matches text-embedding-3-small (1536) so the pgvector schema is identical to
 * production.
 */
public class HashingEmbeddingModel implements EmbeddingModel {

    private static final int DIMENSIONS = 1536;

    @Override
    public float[] embed(Document document) {
        return embed(document.getContent());
    }

    @Override
    public float[] embed(String text) {
        float[] vector = new float[DIMENSIONS];

        for (String token : text.toLowerCase(Locale.ROOT).split("[^a-z0-9]+")) {
            if (token.isBlank()) {
                continue;
            }
            int index = Math.floorMod(token.hashCode(), DIMENSIONS);
            vector[index] += 1.0f;
        }

        double magnitude = 0.0d;
        for (float value : vector) {
            magnitude += value * value;
        }
        magnitude = Math.sqrt(magnitude);

        if (magnitude > 0) {
            for (int i = 0; i < DIMENSIONS; i++) {
                vector[i] /= (float) magnitude;
            }
        }
        return vector;
    }

    @Override
    public EmbeddingResponse call(EmbeddingRequest request) {
        List<Embedding> embeddings = new ArrayList<>();
        List<String> inputs = request.getInstructions();

        for (int i = 0; i < inputs.size(); i++) {
            embeddings.add(new Embedding(embed(inputs.get(i)), i));
        }
        return new EmbeddingResponse(embeddings);
    }

    @Override
    public int dimensions() {
        return DIMENSIONS;
    }
}
APPLY_EOF

chmod +x eval/run_eval.py

echo
echo "Done. Next:"
echo "  1. git diff            — review what changed"
echo "  2. mvn test            — Docker must be running for the integration test"
echo "  3. fill in eval/questions.json, then: python3 eval/run_eval.py"
