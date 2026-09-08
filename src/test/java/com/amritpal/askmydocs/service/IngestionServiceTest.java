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
