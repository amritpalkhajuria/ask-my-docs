package com.amritpal.askmydocs.controller;

import com.amritpal.askmydocs.service.QueryService;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@RestController
public class QueryController {

    private final QueryService queryService;

    public QueryController(QueryService queryService) {
        this.queryService = queryService;
    }

    /**
     * Example usage (curl):
     *   curl -X POST http://localhost:8080/ask \
     *     -H "Content-Type: application/json" \
     *     -d '{"question": "What experience does this candidate have with Kafka?"}'
     */
    @PostMapping("/ask")
    public Map<String, String> ask(@RequestBody Map<String, String> body) {
        String question = body.get("question");
        String answer = queryService.ask(question);
        return Map.of("question", question, "answer", answer);
    }
}
