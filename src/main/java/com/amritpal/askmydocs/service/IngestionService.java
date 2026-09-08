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
