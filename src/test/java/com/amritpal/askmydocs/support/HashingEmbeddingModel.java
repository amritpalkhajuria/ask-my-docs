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
