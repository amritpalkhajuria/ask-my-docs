package com.amritpal.askmydocs.service;

import org.springframework.ai.document.Document;
import org.springframework.ai.reader.tika.TikaDocumentReader;
import org.springframework.ai.transformer.splitter.TokenTextSplitter;
import org.springframework.ai.vectorstore.VectorStore;
import org.springframework.core.io.ByteArrayResource;
import org.springframework.stereotype.Service;

import java.util.List;

@Service
public class IngestionService {

    private final VectorStore vectorStore;

    public IngestionService(VectorStore vectorStore) {
        this.vectorStore = vectorStore;
    }

    /**
     * Takes the raw bytes of an uploaded file (e.g. a PDF), and:
     *   1. Extracts the plain text out of it (TikaDocumentReader handles PDF, DOCX, TXT, etc.)
     *   2. Splits that text into smaller overlapping chunks (TokenTextSplitter) —
     *      LLMs and embedding models work on chunks, not whole documents, because
     *      a) embeddings are more accurate over focused chunks of text, and
     *      b) you can only fit so much text into a prompt later at query time.
     *   3. Sends each chunk to the VectorStore, which under the hood:
     *      a) calls OpenAI's embedding model to turn the chunk's text into a vector
     *      b) stores that vector + the original text in the Postgres pgvector table
     */
    public int ingest(byte[] fileBytes, String filename) {
        TikaDocumentReader reader = new TikaDocumentReader(new ByteArrayResource(fileBytes));
        List<Document> rawDocuments = reader.get();

        TokenTextSplitter splitter = new TokenTextSplitter();
        List<Document> chunks = splitter.apply(rawDocuments);

        // Tag each chunk with the source filename so we know where an answer came from later
        chunks.forEach(chunk -> chunk.getMetadata().put("source", filename));

        vectorStore.add(chunks);

        return chunks.size();
    }
}
