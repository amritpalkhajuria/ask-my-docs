package com.amritpal.askmydocs.controller;

import com.amritpal.askmydocs.api.InvalidRequestException;
import com.amritpal.askmydocs.service.IngestionService;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.test.web.servlet.MockMvc;

import java.nio.charset.StandardCharsets;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.multipart;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(DocumentController.class)
class DocumentControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private IngestionService ingestionService;

    @Test
    @DisplayName("valid upload returns 200 with the stored chunk count")
    void validUploadReturns200() throws Exception {
        when(ingestionService.ingest(any(byte[].class), anyString())).thenReturn(7);

        MockMultipartFile file = new MockMultipartFile(
                "file", "handbook.txt", "text/plain", "some readable text".getBytes(StandardCharsets.UTF_8));

        mockMvc.perform(multipart("/documents").file(file))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.filename").value("handbook.txt"))
                .andExpect(jsonPath("$.chunksStored").value(7))
                .andExpect(jsonPath("$.status").value("ingested"));
    }

    @Test
    @DisplayName("request with no file part returns 400")
    void missingFileReturns400() throws Exception {
        mockMvc.perform(multipart("/documents"))
                .andExpect(status().isBadRequest());
    }

    @Test
    @DisplayName("empty file is rejected with 400 rather than reported as a successful ingest")
    void emptyFileReturns400() throws Exception {
        when(ingestionService.ingest(any(byte[].class), anyString()))
                .thenThrow(new InvalidRequestException("Uploaded file 'empty.txt' is empty."));

        MockMultipartFile file = new MockMultipartFile("file", "empty.txt", "text/plain", new byte[0]);

        mockMvc.perform(multipart("/documents").file(file))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("bad_request"));
    }

    @Test
    @DisplayName("a file with no extractable text is rejected with 400")
    void unsupportedFileReturns400() throws Exception {
        when(ingestionService.ingest(any(byte[].class), anyString()))
                .thenThrow(new InvalidRequestException("No extractable text found in 'scan.png'."));

        MockMultipartFile file = new MockMultipartFile(
                "file", "scan.png", "image/png", new byte[] {0x1, 0x2, 0x3});

        mockMvc.perform(multipart("/documents").file(file))
                .andExpect(status().isBadRequest());
    }

    @Test
    @DisplayName("a plain (non-multipart) POST returns 4xx rather than reaching the service")
    void nonMultipartPostIsRejected() throws Exception {
        mockMvc.perform(post("/documents").content("not a multipart body"))
                .andExpect(status().is4xxClientError());
    }
}
