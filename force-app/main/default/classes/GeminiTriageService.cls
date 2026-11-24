public with sharing class GeminiTriageService {

    public static final String ENDPOINT =
        'callout:Gemini_API/v1beta/models/gemini-3.5-flash-lite:generateContent';

    private static final Integer TIMEOUT_MS = 30000;
    private static final Set<String> VALID_CATEGORIES = new Set<String>{
        'Billing',
        'Technical',
        'Account Access',
        'Service Outage',
        'General'
    };

    public class TriageResult {
        public Integer sentimentScore;
        public String category;
        public String summary;
        public Integer statusCode;
        public String requestPayload;
        public String responseBody;
    }

    // Typed exception carrying full HTTP context for Phase 4 Integration_Log__c logging
    public class GeminiCalloutException extends Exception {
        public Integer statusCode;
        public String endpoint;
        public String requestPayload;
        public String responseBody;

        public GeminiCalloutException withContext(
            Integer statusCode,
            String endpoint,
            String requestPayload,
            String responseBody
        ) {
            this.statusCode = statusCode;
            this.endpoint = endpoint;
            this.requestPayload = requestPayload;
            this.responseBody = responseBody;
            return this;
        }
    }

    private class AiJsonPayload {
        public Integer sentimentScore;
        public String category;
        public String summary;
    }

    public static TriageResult analyzeComplaint(String complaintText, String customerTier) {
        if (String.isBlank(complaintText)) {
            throw new GeminiCalloutException('Complaint text cannot be blank.')
                .withContext(null, ENDPOINT, null, null);
        }

        String requestBody = buildRequestBody(complaintText, customerTier);

        HttpRequest req = new HttpRequest();
        req.setEndpoint(ENDPOINT);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(TIMEOUT_MS);
        req.setBody(requestBody);

        HttpResponse res;
        try {
            Http http = new Http();
            res = http.send(req);
        } catch (Exception ex) {
            throw new GeminiCalloutException('HTTP transport error: ' + ex.getMessage())
                .withContext(null, ENDPOINT, requestBody, null);
        }

        Integer statusCode = res.getStatusCode();
        String responseBody = res.getBody();

        if (statusCode < 200 || statusCode >= 300) {
            throw new GeminiCalloutException('Gemini API returned HTTP ' + statusCode)
                .withContext(statusCode, ENDPOINT, requestBody, responseBody);
        }

        return parseAndValidateResponse(statusCode, requestBody, responseBody);
    }

    @TestVisible
    private static String buildRequestBody(String complaintText, String customerTier) {
        String prompt =
            'You are an enterprise customer support escalation triage engine. ' +
            'Analyze the customer complaint below and return ONLY valid JSON matching the schema.\n' +
            '- sentimentScore: integer from 1 (calm inquiry) to 10 (furious/critical business impact).\n' +
            '- category: choose the single best match from [Billing, Technical, Account Access, Service Outage, General].\n' +
            '- summary: concise one-sentence summary under 180 characters.\n\n' +
            'Customer Tier: ' + (String.isBlank(customerTier) ? 'Standard' : customerTier) + '\n' +
            'Complaint: ' + complaintText;

        Map<String, Object> responseSchema = new Map<String, Object>{
            'type' => 'OBJECT',
            'properties' => new Map<String, Object>{
                'sentimentScore' => new Map<String, Object>{ 'type' => 'INTEGER' },
                'category' => new Map<String, Object>{
                    'type' => 'STRING',
                    'enum' => new List<String>{
                        'Billing', 'Technical', 'Account Access', 'Service Outage', 'General'
                    }
                },
                'summary' => new Map<String, Object>{ 'type' => 'STRING' }
            },
            'required' => new List<String>{ 'sentimentScore', 'category', 'summary' }
        };

        Map<String, Object> body = new Map<String, Object>{
            'contents' => new List<Object>{
                new Map<String, Object>{
                    'parts' => new List<Object>{
                        new Map<String, Object>{ 'text' => prompt }
                    }
                }
            },
            'generationConfig' => new Map<String, Object>{
                'temperature' => 0.1,
                'responseMimeType' => 'application/json',
                'responseSchema' => responseSchema
            }
        };

        return JSON.serialize(body);
    }

    private static TriageResult parseAndValidateResponse(
        Integer statusCode,
        String requestPayload,
        String responseBody
    ) {
        try {
            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
            List<Object> candidates = (List<Object>) root.get('candidates');
            if (candidates == null || candidates.isEmpty()) {
                throw new GeminiCalloutException('Gemini response contained no candidates.');
            }

            Map<String, Object> firstCandidate = (Map<String, Object>) candidates[0];
            Map<String, Object> content = (Map<String, Object>) firstCandidate.get('content');
            List<Object> parts = (content != null) ? (List<Object>) content.get('parts') : null;
            if (parts == null || parts.isEmpty()) {
                throw new GeminiCalloutException('Gemini response contained no content parts.');
            }

            Map<String, Object> firstPart = (Map<String, Object>) parts[0];
            String rawJsonText = (String) firstPart.get('text');
            if (String.isBlank(rawJsonText)) {
                throw new GeminiCalloutException('Gemini returned empty text output.');
            }

            // Defense-in-depth: strip accidental markdown fences if present
            String cleanedJson = rawJsonText.trim();
            if (cleanedJson.startsWith('```')) {
                cleanedJson = cleanedJson.replaceFirst('^```[a-zA-Z]*\\s*', '');
                cleanedJson = cleanedJson.replaceFirst('\\s*```$', '').trim();
            }

            AiJsonPayload parsed = (AiJsonPayload) JSON.deserialize(cleanedJson, AiJsonPayload.class);

            // Clamp sentiment score into [1..10]
            Integer safeScore = (parsed.sentimentScore == null) ? 5 : parsed.sentimentScore;
            safeScore = Math.max(1, Math.min(10, safeScore));

            // Guard against invalid restricted picklist values
            String safeCategory = VALID_CATEGORIES.contains(parsed.category)
                ? parsed.category
                : 'General';

            // Enforce AI_Summary__c Text(255) field limit
            String safeSummary = String.isNotBlank(parsed.summary)
                ? parsed.summary.trim().left(255)
                : 'AI summary unavailable.';

            TriageResult result = new TriageResult();
            result.sentimentScore = safeScore;
            result.category = safeCategory;
            result.summary = safeSummary;
            result.statusCode = statusCode;
            result.requestPayload = requestPayload;
            result.responseBody = responseBody;
            return result;
        } catch (GeminiCalloutException gce) {
            throw gce.withContext(statusCode, ENDPOINT, requestPayload, responseBody);
        } catch (Exception ex) {
            throw new GeminiCalloutException('Failed to parse Gemini JSON: ' + ex.getMessage())
                .withContext(statusCode, ENDPOINT, requestPayload, responseBody);
        }
    }
}