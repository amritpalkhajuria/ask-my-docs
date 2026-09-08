package com.amritpal.askmydocs.service;

import com.amritpal.askmydocs.api.AskResponse;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.document.Document;
import org.springframework.ai.vectorstore.SearchRequest;
import org.springframework.ai.vectorstore.VectorStore;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.within;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * The LLM is mocked out entirely. What is under test is the part we control: which search
 * request goes to the vector store, what gets assembled into the prompt, and whether the
 * service declines when retrieval comes back empty.
 */
class QueryServiceTest {

    private static final int TOP_K = 4;
    private static final double THRESHOLD = 0.5d;

    private VectorStore vectorStore;
    private ChatClient chatClient;
    private ChatClient.ChatClientRequestSpec requestSpec;
    private ChatClient.CallResponseSpec responseSpec;
    private QueryService queryService;

    @BeforeEach
    void setUp() {
        vectorStore = mock(VectorStore.class);
        chatClient = mock(ChatClient.class);
        requestSpec = mock(ChatClient.ChatClientRequestSpec.class);
        responseSpec = mock(ChatClient.CallResponseSpec.class);

        ChatClient.Builder builder = mock(ChatClient.Builder.class);
        when(builder.build()).thenReturn(chatClient);

        queryService = new QueryService(vectorStore, builder, TOP_K, THRESHOLD);
    }

    /** Wires the fluent ChatClient chain. Only called by tests that expect the LLM to be hit. */
    private void stubChatClient(String answer) {
        when(chatClient.prompt()).thenReturn(requestSpec);
        when(requestSpec.user(anyString())).thenReturn(requestSpec);
        when(requestSpec.call()).thenReturn(responseSpec);
        when(responseSpec.content()).thenReturn(answer);
    }

    @Test
    @DisplayName("searches with the configured topK and similarity threshold")
    void searchesWithConfiguredTopKAndThreshold() {
        stubChatClient("an answer");
        when(vectorStore.similaritySearch(any(SearchRequest.class))).thenReturn(List.of(chunk("some context", 0.2)));

        queryService.ask("How is authentication handled?");

        ArgumentCaptor<SearchRequest> captor = ArgumentCaptor.forClass(SearchRequest.class);
        verify(vectorStore).similaritySearch(captor.capture());

        assertThat(captor.getValue().getQuery()).isEqualTo("How is authentication handled?");
        assertThat(captor.getValue().getTopK()).isEqualTo(TOP_K);
        assertThat(captor.getValue().getSimilarityThreshold()).isEqualTo(THRESHOLD);
    }

    @Test
    @DisplayName("declines without calling the LLM when nothing clears the similarity threshold")
    void declinesWhenNoChunksClearTheThreshold() {
        when(vectorStore.similaritySearch(any(SearchRequest.class))).thenReturn(List.of());

        AskResponse response = queryService.ask("What is the airspeed velocity of an unladen swallow?");

        assertThat(response.answered()).isFalse();
        assertThat(response.answer()).isEqualTo(QueryService.DECLINED_ANSWER);
        assertThat(response.retrieved()).isEmpty();

        // The point of the refusal path: no context means no LLM call at all, so there is
        // nothing for the model to confabulate from and nothing spent on tokens.
        verifyNoInteractions(chatClient);
    }

    @Test
    @DisplayName("declines when the vector store returns null rather than an empty list")
    void declinesOnNullSearchResult() {
        when(vectorStore.similaritySearch(any(SearchRequest.class))).thenReturn(null);

        AskResponse response = queryService.ask("Anything?");

        assertThat(response.answered()).isFalse();
        verifyNoInteractions(chatClient);
    }

    @Test
    @DisplayName("surfaces every retrieved chunk with its source and similarity")
    void surfacesRetrievedChunks() {
        stubChatClient("Keys rotate every 90 days.");
        when(vectorStore.similaritySearch(any(SearchRequest.class)))
                .thenReturn(List.of(chunk("Keys rotate every 90 days.", 0.13), chunk("Key storage.", 0.42)));

        AskResponse response = queryService.ask("How often are keys rotated?");

        assertThat(response.answered()).isTrue();
        assertThat(response.answer()).isEqualTo("Keys rotate every 90 days.");
        assertThat(response.retrieved()).hasSize(2);
        assertThat(response.retrieved().get(0).source()).isEqualTo("security-handbook.pdf");
        // similarity = 1 - cosine distance
        assertThat(response.retrieved().get(0).similarity()).isCloseTo(0.87d, within(1e-9));
    }

    @Test
    @DisplayName("prompt contains every retrieved chunk, the question, and the context-only instruction")
    void promptContainsAllContextAndQuestion() {
        String prompt = QueryService.buildPrompt(
                List.of(chunk("First relevant passage.", 0.1), chunk("Second relevant passage.", 0.2)),
                "What do the passages say?");

        assertThat(prompt)
                .contains("First relevant passage.")
                .contains("Second relevant passage.")
                .contains("What do the passages say?")
                .contains("ONLY");
    }

    private static Document chunk(String content, double distance) {
        return new Document(content, Map.of("source", "security-handbook.pdf", "distance", distance));
    }
}
