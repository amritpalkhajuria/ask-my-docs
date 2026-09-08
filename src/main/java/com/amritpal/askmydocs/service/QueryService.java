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
