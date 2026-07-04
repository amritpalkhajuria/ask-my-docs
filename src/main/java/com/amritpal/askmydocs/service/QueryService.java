package com.amritpal.askmydocs.service;

import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.document.Document;
import org.springframework.ai.vectorstore.SearchRequest;
import org.springframework.ai.vectorstore.VectorStore;
import org.springframework.stereotype.Service;

import java.util.List;
import java.util.stream.Collectors;

@Service
public class QueryService {

    private final VectorStore vectorStore;
    private final ChatClient chatClient;

    public QueryService(VectorStore vectorStore, ChatClient.Builder chatClientBuilder) {
        this.vectorStore = vectorStore;
        this.chatClient = chatClientBuilder.build();
    }

    /**
     * This is the "RAG" part end to end:
     *
     *  RETRIEVAL   -> embed the question, run a similarity search against the vector
     *                 store to find the most relevant chunks we ingested earlier
     *  AUGMENTATION -> stitch those chunks into a prompt as "context" alongside the
     *                  user's actual question
     *  GENERATION   -> send that augmented prompt to the LLM, which answers using the
     *                  context instead of just guessing from its own training data
     */
    public String ask(String question) {

        // RETRIEVAL: topK=4 means "give me the 4 most relevant chunks" — tune this
        // up/down depending on how much context you want to feed the LLM
        SearchRequest searchRequest = SearchRequest.query(question).withTopK(4);
        List<Document> relevantChunks = vectorStore.similaritySearch(searchRequest);

        String context = relevantChunks.stream()
                .map(Document::getContent)
                .collect(Collectors.joining("\n---\n"));

        // AUGMENTATION: the prompt explicitly tells the model to only use the
        // provided context, so it doesn't hallucinate an answer from general knowledge
        String promptTemplate = """
                You are a helpful assistant. Answer the question using ONLY the
                context below. If the answer isn't in the context, say you don't know.

                Context:
                %s

                Question: %s
                """.formatted(context, question);

        // GENERATION
        return chatClient.prompt()
                .user(promptTemplate)
                .call()
                .content();
    }
}
