package com.amritpal.askmydocs.api;

/**
 * Request body for POST /ask.
 *
 * <p>Replaces the previous {@code Map<String, String>}, which returned 500 for a body with
 * no "question" key: the null propagated into {@code Map.of(...)} and threw NPE inside the
 * controller. A missing or blank question is a client error, so it is validated here and
 * mapped to 400 by {@link ApiExceptionHandler}.
 */
public record AskRequest(String question) {

    public String requireQuestion() {
        if (question == null || question.isBlank()) {
            throw new InvalidRequestException("Field 'question' is required and must not be blank.");
        }
        return question;
    }
}
