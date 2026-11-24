public with sharing class AITriageQueueable implements Queueable, Database.AllowsCallouts {

    // Safe chunk size per job to stay well under Apex callout limits & Gemini free-tier RPM
    @TestVisible
    private static Integer chunkSize = 5;

    // Prevents uncontrolled recursive chaining during unit tests unless explicitly enabled
    @TestVisible
    private static Boolean allowChainingInTests = false;

    private final List<Id> ticketIds;
    private final Integer retryCount;

    public AITriageQueueable(List<Id> ticketIds) {
        this(ticketIds, 0);
    }

    public AITriageQueueable(List<Id> ticketIds, Integer retryCount) {
        this.ticketIds = (ticketIds != null) ? new List<Id>(ticketIds) : new List<Id>();
        this.retryCount = (retryCount != null) ? retryCount : 0;
    }

    public void execute(QueueableContext context) {
        if (ticketIds.isEmpty()) {
            return;
        }

        // 1. Split incoming IDs into the current chunk and any remainder for chaining
        List<Id> currentChunk = new List<Id>();
        List<Id> remainingIds = new List<Id>();

        for (Integer i = 0; i < ticketIds.size(); i++) {
            if (i < chunkSize) {
                currentChunk.add(ticketIds[i]);
            } else {
                remainingIds.add(ticketIds[i]);
            }
        }

        // 2. Attach Transaction Finalizer to catch uncatchable LimitExceptions/crashes
        System.attachFinalizer(new AITriageFinalizer(currentChunk, retryCount));

        // 3. Query only the current chunk (NO DML before callouts!)
        List<Escalation_Ticket__c> tickets = [
            SELECT Id, Customer_Tier__c, Complaint_Text__c, Status__c
            FROM Escalation_Ticket__c
            WHERE Id IN :currentChunk
            WITH USER_MODE
        ];

        List<Escalation_Ticket__c> ticketsToUpdate = new List<Escalation_Ticket__c>();
        List<Integration_Log__c> logsToInsert = new List<Integration_Log__c>();

        // 4. Execute callouts one by one; isolate failures per ticket
        for (Escalation_Ticket__c ticket : tickets) {
            try {
                GeminiTriageService.TriageResult result = GeminiTriageService.analyzeComplaint(
                    ticket.Complaint_Text__c,
                    ticket.Customer_Tier__c
                );

                ticket.Sentiment_Score__c = result.sentimentScore;
                ticket.Category__c = result.category;
                ticket.AI_Summary__c = result.summary;
                ticket.Status__c = 'Triaged';
                ticketsToUpdate.add(ticket);
            } catch (GeminiTriageService.GeminiCalloutException gce) {
                ticket.Status__c = 'Triage Failed';
                ticketsToUpdate.add(ticket);

                logsToInsert.add(buildErrorLog(
                    ticket.Id,
                    gce.endpoint,
                    gce.statusCode,
                    gce.requestPayload,
                    gce.responseBody,
                    gce.getMessage()
                ));
            } catch (Exception ex) {
                ticket.Status__c = 'Triage Failed';
                ticketsToUpdate.add(ticket);

                logsToInsert.add(buildErrorLog(
                    ticket.Id,
                    GeminiTriageService.ENDPOINT,
                    null,
                    null,
                    null,
                    ex.getTypeName() + ': ' + ex.getMessage()
                ));
            }
        }

        // 5. All callouts are complete — perform bulk DML safely
        if (!ticketsToUpdate.isEmpty()) {
            update as user ticketsToUpdate;
        }
        if (!logsToInsert.isEmpty()) {
            insert as user logsToInsert;
        }

        // 6. Chain remaining tickets into a new Queueable job if needed
        Boolean canChain = !remainingIds.isEmpty()
            && (!Test.isRunningTest() || allowChainingInTests)
            && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs();

        if (canChain) {
            System.enqueueJob(new AITriageQueueable(remainingIds, retryCount));
        }
    }

    private Integration_Log__c buildErrorLog(
        Id ticketId,
        String endpoint,
        Integer statusCode,
        String requestPayload,
        String responseBody,
        String errorMessage
    ) {
        return new Integration_Log__c(
            Escalation_Ticket__c = ticketId,
            Endpoint__c = String.isNotBlank(endpoint) ? endpoint.left(255) : GeminiTriageService.ENDPOINT.left(255),
            HTTP_Status_Code__c = statusCode,
            Request_Payload__c = String.isNotBlank(requestPayload) ? requestPayload.left(32768) : null,
            Response_Body__c = String.isNotBlank(responseBody) ? responseBody.left(32768) : null,
            Error_Message__c = String.isNotBlank(errorMessage) ? errorMessage.left(5000) : 'Unknown integration error.',
            Retry_Count__c = retryCount,
            Status__c = 'Failed'
        );
    }
}