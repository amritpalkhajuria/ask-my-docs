package com.amritpal.askmydocs.controller;

import com.amritpal.askmydocs.api.AskResponse;
import com.amritpal.askmydocs.api.RetrievedChunk;
import com.amritpal.askmydocs.service.QueryService;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

import java.util.List;

import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(QueryController.class)
class QueryControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private QueryService queryService;

    @Test
    @DisplayName("valid question returns 200 with the answer and the retrieved chunks")
    void validQuestionReturns200() throws Exception {
        when(queryService.ask("How are keys rotated?")).thenReturn(new AskResponse(
                "How are keys rotated?",
                "Every 90 days.",
                true,
                List.of(new RetrievedChunk("c1", "handbook.pdf", 0.81, "Keys rotate every 90 days."))));

        mockMvc.perform(post("/ask")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"question\": \"How are keys rotated?\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.answer").value("Every 90 days."))
                .andExpect(jsonPath("$.answered").value(true))
                .andExpect(jsonPath("$.retrieved[0].source").value("handbook.pdf"));
    }

    @Test
    @DisplayName("an out-of-scope question returns 200 with answered=false")
    void outOfScopeQuestionReturnsAnsweredFalse() throws Exception {
        when(queryService.ask(anyString()))
                .thenReturn(AskResponse.declined("Who won the 1998 World Cup?", "I don't know."));

        mockMvc.perform(post("/ask")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"question\": \"Who won the 1998 World Cup?\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.answered").value(false))
                .andExpect(jsonPath("$.retrieved").isEmpty());
    }

    @Test
    @DisplayName("body with no question field returns 400, not 500")
    void missingQuestionFieldReturns400() throws Exception {
        mockMvc.perform(post("/ask")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"query\": \"wrong field name\"}"))
                .andExpect(status().isBadRequest());

        verifyNoInteractions(queryService);
    }

    @Test
    @DisplayName("blank question returns 400")
    void blankQuestionReturns400() throws Exception {
        mockMvc.perform(post("/ask")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"question\": \"   \"}"))
                .andExpect(status().isBadRequest());

        verifyNoInteractions(queryService);
    }

    @Test
    @DisplayName("malformed JSON returns 400")
    void malformedJsonReturns400() throws Exception {
        mockMvc.perform(post("/ask")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"question\": "))
                .andExpect(status().isBadRequest());

        verifyNoInteractions(queryService);
    }
}
