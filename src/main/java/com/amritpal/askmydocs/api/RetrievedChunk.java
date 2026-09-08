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
