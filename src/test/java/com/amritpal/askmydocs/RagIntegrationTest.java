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
