package com.amritpal.askmydocs.controller;

import com.amritpal.askmydocs.service.IngestionService;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.util.HashMap;
import java.util.Map;

@RestController
public class DocumentController {

    private final IngestionService ingestionService;

    /**
     * Fixed documentId of the pre-loaded sample corpus (this project's own CV), set once via
     * the DEMO_DOCUMENT_ID env var after re-ingesting it. Empty in dev/test, where nothing has
     * been seeded yet — the frontend hides the sample questions in that case rather than
     * pointing them at a document that doesn't exist.
     */
    private final String demoDocumentId;

    public DocumentController(IngestionService ingestionService,
                              @Value("${app.rag.demo-document-id:}") String demoDocumentId) {
        this.ingestionService = ingestionService;
        this.demoDocumentId = demoDocumentId;
    }

    /**
     * Example usage (curl):
     *   curl -F "file=@/path/to/your.pdf" http://localhost:8080/documents
     *
     * <p>Every upload gets its own server-generated documentId (see {@link IngestionService}),
     * which the caller must pass back on {@code /ask} — this is what keeps one visitor's
     * document from being searchable by anyone else's questions on this public endpoint.
     */
    @PostMapping("/documents")
    public Map<String, Object> uploadDocument(@RequestParam("file") MultipartFile file) throws IOException {
        String filename = file.getOriginalFilename() == null ? "unnamed" : file.getOriginalFilename();
        IngestionService.IngestionResult result = ingestionService.ingest(file.getBytes(), filename);

        Map<String, Object> response = new HashMap<>();
        response.put("documentId", result.documentId());
        response.put("filename", filename);
        response.put("chunksStored", result.chunksStored());
        response.put("status", "ingested");
        return response;
    }

    /** Lets the frontend discover the sample corpus's documentId instead of hardcoding it. */
    @GetMapping("/documents/demo")
    public Map<String, String> demoDocument() {
        Map<String, String> response = new HashMap<>();
        response.put("documentId", demoDocumentId.isBlank() ? null : demoDocumentId);
        return response;
    }
}
