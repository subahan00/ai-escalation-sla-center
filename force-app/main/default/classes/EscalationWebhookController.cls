@RestResource(urlMapping='/api/escalations/*')
global with sharing class EscalationWebhookController {

    private static final Set<String> VALID_TIERS = new Set<String>{
        'Enterprise', 'Gold', 'Standard'
    };
    private static final Set<String> VALID_SOURCES = new Set<String>{
        'WhatsApp', 'Mobile App', 'Web Portal', 'Email'
    };

    // Incoming JSON contract
    public class EscalationRequest {
        public String customerName;
        public String customerEmail;
        public String customerTier;
        public String externalSource;
        public String complaintText;
    }

    // Outgoing JSON contract
    public class EscalationResponse {
        public Boolean success;
        public String ticketId;
        public String ticketNumber;
        public String status;
        public String message;
    }

    @HttpPost
    global static void createEscalation() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        try {
            if (req.requestBody == null || String.isBlank(req.requestBody.toString())) {
                sendResponse(res, 400, false, null, null, null, 'Request body cannot be empty.');
                return;
            }

            EscalationRequest payload;
            try {
                payload = (EscalationRequest) JSON.deserialize(
                    req.requestBody.toString(),
                    EscalationRequest.class
                );
            } catch (JSONException je) {
                sendResponse(res, 400, false, null, null, null, 'Malformed JSON payload.');
                return;
            }

            // Validate before touching the database
            String validationError = validatePayload(payload);
            if (validationError != null) {
                sendResponse(res, 400, false, null, null, null, validationError);
                return;
            }

            Escalation_Ticket__c ticket = new Escalation_Ticket__c(
                Customer_Name__c = payload.customerName.trim(),
                Customer_Email__c = String.isNotBlank(payload.customerEmail) ? payload.customerEmail.trim() : null,
                Customer_Tier__c = payload.customerTier.trim(),
                External_Source__c = String.isNotBlank(payload.externalSource) ? payload.externalSource.trim() : 'Web Portal',
                Complaint_Text__c = payload.complaintText.trim(),
                Status__c = 'Pending Triage'
            );

            insert as user ticket;

            // Re-query so we return the auto-generated ESC-0001 number
            Escalation_Ticket__c savedTicket = [
                SELECT Id, Name, Status__c
                FROM Escalation_Ticket__c
                WHERE Id = :ticket.Id
                WITH USER_MODE
                LIMIT 1
            ];

            sendResponse(
                res,
                201,
                true,
                savedTicket.Id,
                savedTicket.Name,
                savedTicket.Status__c,
                'Escalation ticket created and queued for AI triage.'
            );
        } catch (DmlException dmlEx) {
            // e.g., invalid email format rejected by Salesforce field validation
            sendResponse(res, 400, false, null, null, null, dmlEx.getDmlMessage(0));
        } catch (Exception ex) {
            // Log internally; never expose raw stack traces to external clients
            System.debug(LoggingLevel.ERROR, 'EscalationWebhookController failure: ' + ex.getMessage());
            sendResponse(res, 500, false, null, null, null, 'Unexpected server error while processing escalation.');
        }
    }

    private static String validatePayload(EscalationRequest payload) {
        if (payload == null) {
            return 'Invalid request payload.';
        }
        if (String.isBlank(payload.customerName)) {
            return 'Missing required field: customerName.';
        }
        if (String.isBlank(payload.complaintText)) {
            return 'Missing required field: complaintText.';
        }
        if (String.isBlank(payload.customerTier) || !VALID_TIERS.contains(payload.customerTier.trim())) {
            return 'Invalid customerTier. Allowed values: Enterprise, Gold, Standard.';
        }
        if (String.isNotBlank(payload.externalSource) && !VALID_SOURCES.contains(payload.externalSource.trim())) {
            return 'Invalid externalSource. Allowed values: WhatsApp, Mobile App, Web Portal, Email.';
        }
        return null;
    }

    private static void sendResponse(
        RestResponse res,
        Integer statusCode,
        Boolean isSuccess,
        String ticketId,
        String ticketNumber,
        String status,
        String message
    ) {
        EscalationResponse body = new EscalationResponse();
        body.success = isSuccess;
        body.ticketId = ticketId;
        body.ticketNumber = ticketNumber;
        body.status = status;
        body.message = message;

        res.statusCode = statusCode;
        res.responseBody = Blob.valueOf(JSON.serialize(body));
    }
}