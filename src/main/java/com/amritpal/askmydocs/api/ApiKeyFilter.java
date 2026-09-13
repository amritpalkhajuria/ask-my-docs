package com.amritpal.askmydocs.api;

import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Map;
import java.util.Set;

/**
 * Guards /ask and /documents with a shared-secret header, since both call paid OpenAI APIs
 * and would otherwise be open to anyone who can reach this host.
 */
@Component
public class ApiKeyFilter extends OncePerRequestFilter {

    private static final String HEADER = "X-API-Key";
    private static final Set<String> PROTECTED_PATHS = Set.of("/ask", "/documents");

    private final String expectedApiKey;
    private final ObjectMapper objectMapper;

    public ApiKeyFilter(@Value("${app.api-key}") String expectedApiKey, ObjectMapper objectMapper) {
        this.expectedApiKey = expectedApiKey;
        this.objectMapper = objectMapper;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
            throws ServletException, IOException {
        if (!PROTECTED_PATHS.contains(request.getRequestURI()) || isAuthorized(request)) {
            filterChain.doFilter(request, response);
            return;
        }

        response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        objectMapper.writeValue(response.getWriter(),
                Map.of("error", "unauthorized", "message", "Missing or invalid API key."));
    }

    // Constant-time comparison so a mistyped key can't be brute-forced via response timing.
    private boolean isAuthorized(HttpServletRequest request) {
        String provided = request.getHeader(HEADER);
        return provided != null && MessageDigest.isEqual(
                expectedApiKey.getBytes(StandardCharsets.UTF_8), provided.getBytes(StandardCharsets.UTF_8));
    }
}
