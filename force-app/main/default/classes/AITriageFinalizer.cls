public with sharing class AITriageFinalizer implements System.Finalizer {

    private final List<Id> processedTicketIds;
    private final Integer retryCount;

    public AITriageFinalizer(List<Id> processedTicketIds, Integer retryCount) {
        this.processedTicketIds = (processedTicketIds != null)
            ? new List<Id>(processedTicketIds)
            : new List<Id>();
        this.retryCount = (retryCount != null) ? retryCount : 0;
    }

    public void execute(FinalizerContext ctx) {
        // Only act when the parent Queueable crashed with an unhandled/uncatchable exception
        if (ctx.getResult() != ParentJobResult.UNHANDLED_EXCEPTION) {
            return;
        }

        Exception unhandledEx = ctx.getException();
        String jobId = String.valueOf(ctx.getAsyncApexJobId());
        String errorText = 'Unhandled Queueable failure (Job ' + jobId + '): ' +
            (unhandledEx != null ? unhandledEx.getTypeName() + ' - ' + unhandledEx.getMessage() : 'Unknown error');

        List<Integration_Log__c> failureLogs = new List<Integration_Log__c>();
        List<Escalation_Ticket__c> stuckTickets = new List<Escalation_Ticket__c>();

        if (!processedTicketIds.isEmpty()) {
            // Find any tickets from the crashed chunk still stuck in Pending Triage
            for (Escalation_Ticket__c ticket : [
                SELECT Id, Status__c
                FROM Escalation_Ticket__c
                WHERE Id IN :processedTicketIds
                WITH USER_MODE
            ]) {
                if (ticket.Status__c == 'Pending Triage') {
                    ticket.Status__c = 'Triage Failed';
                    stuckTickets.add(ticket);
                }

                failureLogs.add(new Integration_Log__c(
                    Escalation_Ticket__c = ticket.Id,
                    Endpoint__c = GeminiTriageService.ENDPOINT.left(255),
                    Error_Message__c = errorText.left(5000),
                    Retry_Count__c = retryCount,
                    Status__c = 'Failed'
                ));
            }
        } else {
            failureLogs.add(new Integration_Log__c(
                Endpoint__c = GeminiTriageService.ENDPOINT.left(255),
                Error_Message__c = errorText.left(5000),
                Retry_Count__c = retryCount,
                Status__c = 'Failed'
            ));
        }

        if (!stuckTickets.isEmpty()) {
            update as user stuckTickets;
        }
        if (!failureLogs.isEmpty()) {
            insert as user failureLogs;
        }
    }
}