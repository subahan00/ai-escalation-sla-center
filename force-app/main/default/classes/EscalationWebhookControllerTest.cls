@IsTest
private class EscalationWebhookControllerTest {

    private static void setupRestContext(String jsonBody) {
        RestRequest req = new RestRequest();
        req.requestUri = '/services/apexrest/api/escalations';
        req.httpMethod = 'POST';
        req.addHeader('Content-Type', 'application/json');
        if (jsonBody != null) {
            req.requestBody = Blob.valueOf(jsonBody);
        }
        RestContext.request = req;
        RestContext.response = new RestResponse();
    }

    @IsTest
    static void testCreateEscalationSuccess() {
        Test.setMock(
            HttpCalloutMock.class,
            GeminiCalloutMock.success(9, 'Service Outage', 'Checkout gateway throwing 500 errors.')
        );

        String body = JSON.serialize(new Map<String, Object>{
            'customerName' => 'Rohan Sharma',
            'customerEmail' => 'rohan@acmecorp.in',
            'customerTier' => 'Enterprise',
            'externalSource' => 'WhatsApp',
            'complaintText' => 'Checkout gateway has been down for two hours!'
        });
        setupRestContext(body);

        Test.startTest();
        EscalationWebhookController.createEscalation();
        Test.stopTest();

        Assert.areEqual(201, RestContext.response.statusCode, 'Should return 201 Created');

        EscalationWebhookController.EscalationResponse parsed =
            (EscalationWebhookController.EscalationResponse) JSON.deserialize(
                RestContext.response.responseBody.toString(),
                EscalationWebhookController.EscalationResponse.class
            );

        Assert.isTrue(parsed.success, 'Response success flag should be true');
        Assert.isNotNull(parsed.ticketId, 'Should return inserted ticket Id');
        Assert.isTrue(parsed.ticketNumber.startsWith('ESC-'), 'Should return generated Auto-Number');

        // Verify trigger -> Queueable -> SLA engine ran after Test.stopTest()
        Escalation_Ticket__c ticket = [
            SELECT Status__c, Sentiment_Score__c, Category__c, SLA_Hours__c, Resolution_Deadline__c
            FROM Escalation_Ticket__c
            WHERE Id = :parsed.ticketId
        ];
        Assert.areEqual('Escalated', ticket.Status__c, 'High-risk Enterprise ticket should auto-escalate');
        Assert.areEqual(9, ticket.Sentiment_Score__c);
        Assert.areEqual(2, ticket.SLA_Hours__c, 'Enterprise High Risk rule should assign 2 SLA hours');
        Assert.isNotNull(ticket.Resolution_Deadline__c);
    }

    @IsTest
    static void testEmptyBodyReturns400() {
        setupRestContext('');

        Test.startTest();
        EscalationWebhookController.createEscalation();
        Test.stopTest();

        Assert.areEqual(400, RestContext.response.statusCode, 'Empty body should return 400');
    }

    @IsTest
    static void testMalformedJsonReturns400() {
        setupRestContext('{invalid-json');

        Test.startTest();
        EscalationWebhookController.createEscalation();
        Test.stopTest();

        Assert.areEqual(400, RestContext.response.statusCode, 'Malformed JSON should return 400');
    }

    @IsTest
    static void testInvalidTierAndMissingFieldsReturn400() {
        String badTierBody = JSON.serialize(new Map<String, Object>{
            'customerName' => 'Test User',
            'customerTier' => 'VIP',
            'complaintText' => 'Account locked.'
        });
        setupRestContext(badTierBody);
        EscalationWebhookController.createEscalation();
        Assert.areEqual(400, RestContext.response.statusCode, 'Invalid picklist tier should return 400');

        String badSourceBody = JSON.serialize(new Map<String, Object>{
            'customerName' => 'Test User',
            'customerTier' => 'Gold',
            'externalSource' => 'CarrierPigeon',
            'complaintText' => 'Account locked.'
        });
        setupRestContext(badSourceBody);
        EscalationWebhookController.createEscalation();
        Assert.areEqual(400, RestContext.response.statusCode, 'Invalid externalSource should return 400');

        String missingComplaintBody = JSON.serialize(new Map<String, Object>{
            'customerName' => 'Test User',
            'customerTier' => 'Gold',
            'complaintText' => ''
        });
        setupRestContext(missingComplaintBody);
        EscalationWebhookController.createEscalation();
        Assert.areEqual(400, RestContext.response.statusCode, 'Blank complaintText should return 400');
    }
}
