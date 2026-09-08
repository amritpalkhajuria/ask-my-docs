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
