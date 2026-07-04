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
        int chunkCount = ingestionService.ingest(file.getBytes(), file.getOriginalFilename());

        return Map.of(
                "filename", file.getOriginalFilename(),
                "chunksStored", chunkCount,
                "status", "ingested"
        );
    }
}
