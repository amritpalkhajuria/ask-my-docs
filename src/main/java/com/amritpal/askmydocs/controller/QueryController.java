package com.amritpal.askmydocs.controller;

import com.amritpal.askmydocs.api.AskRequest;
import com.amritpal.askmydocs.api.AskResponse;
import com.amritpal.askmydocs.service.QueryService;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

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
    public AskResponse ask(@RequestBody AskRequest request) {
        return queryService.ask(request.requireQuestion());
    }
}
