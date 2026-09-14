package com.amritpal.askmydocs.api;

import java.util.regex.Pattern;

/**
 * Request body for POST /ask.
 *
 * <p>Replaces the previous {@code Map<String, String>}, which returned 500 for a body with
 * no "question" key: the null propagated into {@code Map.of(...)} and threw NPE inside the
 * controller. A missing or blank question is a client error, so it is validated here and
 * mapped to 400 by {@link ApiExceptionHandler}.
 *
 * <p>{@code documentId} scopes the question to one uploaded document — this is a public,
 * multi-tenant endpoint, so without it a question would search across every document anyone
 * has ever ingested. It's validated against the shape {@code IngestionService} actually
 * generates (a UUID) so a malformed value fails fast as a 400 instead of silently matching
 * nothing in the filter expression.
 */
public record AskRequest(String question, String documentId) {

    private static final Pattern DOCUMENT_ID_PATTERN = Pattern.compile("^[A-Za-z0-9-]{1,64}$");

    public String requireQuestion() {
        if (question == null || question.isBlank()) {
            throw new InvalidRequestException("Field 'question' is required and must not be blank.");
        }
        return question;
    }

    public String requireDocumentId() {
        if (documentId == null || documentId.isBlank()) {
            throw new InvalidRequestException(
                    "Field 'documentId' is required — upload a document via /documents first and pass back the "
                            + "documentId it returns.");
        }
        if (!DOCUMENT_ID_PATTERN.matcher(documentId).matches()) {
            throw new InvalidRequestException("Field 'documentId' is not a value this API ever issued.");
        }
        return documentId;
    }
}
