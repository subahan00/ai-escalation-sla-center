@IsTest
private class EscalationEngineTest {

    // Mock System.FinalizerContext to unit-test AITriageFinalizer directly
    private class MockFinalizerContext implements System.FinalizerContext {
        private ParentJobResult result;
        private Exception ex;

        public MockFinalizerContext(ParentJobResult result, Exception ex) {
            this.result = result;
            this.ex = ex;
        }

        public Id getAsyncApexJobId() {
            return '707000000000001AAA';
        }
        public String getRequestId() {
            return 'REQ-TEST-001';
        }
        public ParentJobResult getResult() {
            return this.result;
        }
        public Exception getException() {
            return this.ex;
        }
    }

    @IsTest
    static void testLowRiskStaysTriaged() {
        Test.setMock(
            HttpCalloutMock.class,
            GeminiCalloutMock.success(3, 'Billing', 'Customer requested last month invoice PDF.')
        );

        Escalation_Ticket__c ticket = new Escalation_Ticket__c(
            Customer_Name__c = 'Vikram Desai',
            Customer_Tier__c = 'Standard',
            External_Source__c = 'Email',
            Complaint_Text__c = 'Could you please resend my invoice from last month?',
            Status__c = 'Pending Triage'
        );

        Test.startTest();
        insert ticket;
        Test.stopTest();

        Escalation_Ticket__c updated = [
            SELECT Status__c, Sentiment_Score__c, Category__c, SLA_Hours__c, Resolution_Deadline__c
            FROM Escalation_Ticket__c
            WHERE Id = :ticket.Id
        ];
        Assert.areEqual('Triaged', updated.Status__c, 'Low-risk ticket should remain Triaged');
        Assert.areEqual(3, updated.Sentiment_Score__c);
        Assert.areEqual('Billing', updated.Category__c);
        Assert.areEqual(24, updated.SLA_Hours__c, 'Standard Normal rule should assign 24 SLA hours');
        Assert.isNotNull(updated.Resolution_Deadline__c);
    }

    @IsTest
    static void testHttp429LogsIntegrationFailure() {
        Test.setMock(
            HttpCalloutMock.class,
            GeminiCalloutMock.error(429, 'RESOURCE_EXHAUSTED: Free tier quota exceeded.')
        );

        Escalation_Ticket__c ticket = new Escalation_Ticket__c(
            Customer_Name__c = 'Rate Limit Customer',
            Customer_Tier__c = 'Gold',
            External_Source__c = 'Mobile App',
            Complaint_Text__c = 'App crashes on login screen.',
            Status__c = 'Pending Triage'
        );

        Test.startTest();
        insert ticket;
        Test.stopTest();

        Escalation_Ticket__c updated = [
            SELECT Status__c
            FROM Escalation_Ticket__c
            WHERE Id = :ticket.Id
        ];
        Assert.areEqual('Triage Failed', updated.Status__c, '429 failure should mark ticket Triage Failed');

        List<Integration_Log__c> logs = [
            SELECT HTTP_Status_Code__c, Status__c, Error_Message__c, Retry_Count__c
            FROM Integration_Log__c
            WHERE Escalation_Ticket__c = :ticket.Id
        ];
        Assert.areEqual(1, logs.size(), 'Exactly one Integration_Log__c should be created');
        Assert.areEqual(429, logs[0].HTTP_Status_Code__c);
        Assert.areEqual('Failed', logs[0].Status__c);
        Assert.areEqual(0, logs[0].Retry_Count__c);
    }

    @IsTest
    static void testDefensiveParsingClampsOutOfRangeValues() {
        String longSummary = 'A'.repeat(300);
        String fencedJson = '```json\n{"sentimentScore":99,"category":"InvalidCat","summary":"'
            + longSummary + '"}\n```';

        Test.setMock(HttpCalloutMock.class, GeminiCalloutMock.rawText(200, fencedJson));

        Test.startTest();
        GeminiTriageService.TriageResult res = GeminiTriageService.analyzeComplaint(
            'Severe billing bug',
            'Enterprise'
        );
        Test.stopTest();

        Assert.areEqual(10, res.sentimentScore, 'Score above 10 must be clamped to 10');
        Assert.areEqual('General', res.category, 'Unknown category must fall back to General');
        Assert.areEqual(255, res.summary.length(), 'Summary must be truncated to 255 chars');
    }

    @IsTest
    static void testFinalizerLogsUnhandledException() {
        EscalationTriggerHandler.bypassTrigger = true;
        Escalation_Ticket__c stuckTicket = new Escalation_Ticket__c(
            Customer_Name__c = 'Crash Recovery User',
            Customer_Tier__c = 'Enterprise',
            Complaint_Text__c = 'System outage.',
            Status__c = 'Pending Triage'
        );
        insert stuckTicket;
        EscalationTriggerHandler.bypassTrigger = false;

        AITriageFinalizer finalizer = new AITriageFinalizer(new List<Id>{ stuckTicket.Id }, 1);

        Test.startTest();
        // 1. SUCCESS context should do nothing
        finalizer.execute(new MockFinalizerContext(ParentJobResult.SUCCESS, null));
        Assert.areEqual(0, [SELECT COUNT() FROM Integration_Log__c], 'SUCCESS should not log errors');

        // 2. UNHANDLED_EXCEPTION context should mark ticket failed and write Integration_Log__c
        finalizer.execute(
            new MockFinalizerContext(
                ParentJobResult.UNHANDLED_EXCEPTION,
                new CalloutException('Simulated unhandled async crash')
            )
        );
        Test.stopTest();

        Escalation_Ticket__c updated = [
            SELECT Status__c FROM Escalation_Ticket__c WHERE Id = :stuckTicket.Id
        ];
        Assert.areEqual('Triage Failed', updated.Status__c, 'Finalizer must flip stuck ticket to Triage Failed');

        List<Integration_Log__c> logs = [
            SELECT Error_Message__c, Retry_Count__c, Status__c
            FROM Integration_Log__c
            WHERE Escalation_Ticket__c = :stuckTicket.Id
        ];
        Assert.areEqual(1, logs.size());
        Assert.isTrue(logs[0].Error_Message__c.contains('Unhandled Queueable failure'));
        Assert.areEqual(1, logs[0].Retry_Count__c);
    }

    @IsTest
    static void testBulk200RecordsGovernorLimits() {
        // Seed 200 tickets without firing async callouts yet
        EscalationTriggerHandler.bypassTrigger = true;
        List<Escalation_Ticket__c> tickets = new List<Escalation_Ticket__c>();
        for (Integer i = 0; i < 200; i++) {
            tickets.add(new Escalation_Ticket__c(
                Customer_Name__c = 'Bulk Customer ' + i,
                Customer_Tier__c = 'Enterprise',
                External_Source__c = 'WhatsApp',
                Complaint_Text__c = 'Production outage batch #' + i,
                Status__c = 'Pending Triage'
            ));
        }
        insert tickets;
        EscalationTriggerHandler.bypassTrigger = false;

        // Simulate bulk AI triage completion for all 200 records in one DML statement
        for (Escalation_Ticket__c t : tickets) {
            t.Status__c = 'Triaged';
            t.Sentiment_Score__c = 9;
            t.Category__c = 'Service Outage';
            t.AI_Summary__c = 'Bulk outage test summary.';
        }

        Test.startTest();
        update tickets;
        // Capture governor limits INSIDE Test.startTest() before stopTest() resets them
        Integer soqlUsed = Limits.getQueries();
        Integer dmlUsed = Limits.getDmlStatements();
        Test.stopTest();

        Assert.isTrue(
            soqlUsed < 100,
            'Expected bulkified SOQL count well under 100, actual: ' + soqlUsed
        );
        Assert.isTrue(
            soqlUsed <= 2,
            'Static BusinessHours caching + CMDT getAll() should keep SOQL <= 2, actual: ' + soqlUsed
        );
        Assert.isTrue(dmlUsed <= 5, 'Expected minimal DML statements, actual: ' + dmlUsed);

        List<Escalation_Ticket__c> verified = [
            SELECT Status__c, SLA_Hours__c, Resolution_Deadline__c
            FROM Escalation_Ticket__c
            WHERE Id IN :tickets
        ];
        Assert.areEqual(200, verified.size());
        for (Escalation_Ticket__c t : verified) {
            Assert.areEqual('Escalated', t.Status__c, 'Every high-risk ticket must escalate');
            Assert.areEqual(2, t.SLA_Hours__c, 'Every Enterprise High Risk ticket must get 2h SLA');
            Assert.isNotNull(t.Resolution_Deadline__c, 'Every ticket must have a BusinessHours deadline');
        }
    }

    @IsTest
    static void testLwcCommandControllerActions() {
        EscalationTriggerHandler.bypassTrigger = true;
        Escalation_Ticket__c ticket = new Escalation_Ticket__c(
            Customer_Name__c = 'Retry Demo User',
            Customer_Tier__c = 'Gold',
            External_Source__c = 'Web Portal',
            Complaint_Text__c = 'Cannot access account billing page.',
            Status__c = 'Triage Failed'
        );
        insert ticket;

        Integration_Log__c failedLog = new Integration_Log__c(
            Escalation_Ticket__c = ticket.Id,
            Endpoint__c = GeminiTriageService.ENDPOINT,
            HTTP_Status_Code__c = 503,
            Error_Message__c = 'Temporary upstream error',
            Retry_Count__c = 0,
            Status__c = 'Failed'
        );
        insert failedLog;
        EscalationTriggerHandler.bypassTrigger = false;

        Assert.areEqual(1, EscalationCommandController.getTickets().size());
        Assert.areEqual(1, EscalationCommandController.getFailedLogs().size());

        // 1. Test 1-Click Retry (mock succeeds and triages the ticket)
        Test.setMock(
            HttpCalloutMock.class,
            GeminiCalloutMock.success(8, 'Account Access', 'Gold user locked out of billing portal.')
        );

        Test.startTest();
        EscalationCommandController.retryFailedLog(failedLog.Id);
        Test.stopTest();

        Integration_Log__c retriedLog = [
            SELECT Status__c FROM Integration_Log__c WHERE Id = :failedLog.Id
        ];
        Escalation_Ticket__c healedTicket = [
            SELECT Status__c, SLA_Hours__c FROM Escalation_Ticket__c WHERE Id = :ticket.Id
        ];
        Assert.areEqual('Retried', retriedLog.Status__c);
        Assert.areEqual('Escalated', healedTicket.Status__c);
        Assert.areEqual(4, healedTicket.SLA_Hours__c, 'Gold High Risk should assign 4 SLA hours');

        // 2. Test Resolve button
        EscalationCommandController.resolveTicket(ticket.Id);
        Escalation_Ticket__c resolved = [
            SELECT Status__c FROM Escalation_Ticket__c WHERE Id = :ticket.Id
        ];
        Assert.areEqual('Resolved', resolved.Status__c);

        // 3. Test null guard clauses throw AuraHandledException
        Boolean threwOnNullRetry = false;
        try {
            EscalationCommandController.retryFailedLog(null);
        } catch (AuraHandledException ex) {
            threwOnNullRetry = true;
        }
        Assert.isTrue(threwOnNullRetry, 'Null logId should throw AuraHandledException');

        Boolean threwOnNullResolve = false;
        try {
            EscalationCommandController.resolveTicket(null);
        } catch (AuraHandledException ex) {
            threwOnNullResolve = true;
        }
        Assert.isTrue(threwOnNullResolve, 'Null ticketId should throw AuraHandledException');
    }
}
