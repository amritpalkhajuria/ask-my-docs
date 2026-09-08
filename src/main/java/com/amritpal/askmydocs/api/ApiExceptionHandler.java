package com.amritpal.askmydocs.api;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.multipart.MaxUploadSizeExceededException;
import org.springframework.web.multipart.MultipartException;

import java.util.Map;

/**
 * Turns bad input into 400s with a readable message, instead of leaking a 500.
 * Spring already maps a missing multipart part to 400; a request that isn't
 * multipart at all (no boundary) throws MultipartException instead, which has
 * no default mapping, so it's handled explicitly here alongside the
 * application-level cases (empty file, unreadable file, blank question).
 */
@RestControllerAdvice
public class ApiExceptionHandler {

    @ExceptionHandler(InvalidRequestException.class)
    public ResponseEntity<Map<String, String>> handleInvalidRequest(InvalidRequestException ex) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST)
                .body(Map.of("error", "bad_request", "message", ex.getMessage()));
    }

    // MaxUploadSizeExceededException is a MultipartException, and Spring picks the closest
    // matching handler by type, so this must be handled separately from the case below —
    // otherwise a too-large file is misreported as "not a multipart upload".
    @ExceptionHandler(MaxUploadSizeExceededException.class)
    public ResponseEntity<Map<String, String>> handleMaxUploadSizeExceeded(MaxUploadSizeExceededException ex) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST)
                .body(Map.of("error", "bad_request", "message", "Uploaded file exceeds the maximum allowed size."));
    }

    @ExceptionHandler(MultipartException.class)
    public ResponseEntity<Map<String, String>> handleMultipartException(MultipartException ex) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST)
                .body(Map.of("error", "bad_request", "message", "Request must be a multipart/form-data upload."));
    }
}
