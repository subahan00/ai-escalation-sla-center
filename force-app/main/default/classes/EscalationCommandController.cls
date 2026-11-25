public with sharing class EscalationCommandController {

    @AuraEnabled
    public static List<Escalation_Ticket__c> getTickets() {
        return [
            SELECT
                Id,
                Name,
                Customer_Name__c,
                Customer_Email__c,
                Customer_Tier__c,
                External_Source__c,
                Complaint_Text__c,
                Status__c,
                Sentiment_Score__c,
                Category__c,
                AI_Summary__c,
                SLA_Hours__c,
                Resolution_Deadline__c,
                CreatedDate
            FROM Escalation_Ticket__c
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 50
        ];
    }

    @AuraEnabled
    public static List<Integration_Log__c> getFailedLogs() {
        return [
            SELECT
                Id,
                Name,
                Escalation_Ticket__c,
                Escalation_Ticket__r.Name,
                Escalation_Ticket__r.Customer_Name__c,
                Escalation_Ticket__r.Customer_Tier__c,
                Endpoint__c,
                HTTP_Status_Code__c,
                Error_Message__c,
                Retry_Count__c,
                Status__c,
                CreatedDate
            FROM Integration_Log__c
            WHERE Status__c = 'Failed'
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 50
        ];
    }

    @AuraEnabled
    public static void retryFailedLog(Id logId) {
        if (logId == null) {
            throw new AuraHandledException('Integration Log ID is required.');
        }

        try {
            Integration_Log__c logRecord = [
                SELECT Id, Escalation_Ticket__c, Retry_Count__c, Status__c
                FROM Integration_Log__c
                WHERE Id = :logId
                WITH USER_MODE
                LIMIT 1
            ];

            if (logRecord.Escalation_Ticket__c == null) {
                throw new AuraHandledException('This log is not linked to an Escalation Ticket.');
            }

            Integer nextRetryCount = (logRecord.Retry_Count__c == null)
                ? 1
                : logRecord.Retry_Count__c.intValue() + 1;

            logRecord.Status__c = 'Retried';
            Escalation_Ticket__c ticketToRetry = new Escalation_Ticket__c(
                Id = logRecord.Escalation_Ticket__c,
                Status__c = 'Pending Triage'
            );

            update as user logRecord;
            update as user ticketToRetry;

            System.enqueueJob(
                new AITriageQueueable(new List<Id>{ logRecord.Escalation_Ticket__c }, nextRetryCount)
            );
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception ex) {
            throw new AuraHandledException('Retry failed: ' + ex.getMessage());
        }
    }

    @AuraEnabled
    public static void resolveTicket(Id ticketId) {
        if (ticketId == null) {
            throw new AuraHandledException('Ticket ID is required.');
        }

        try {
            Escalation_Ticket__c ticket = new Escalation_Ticket__c(
                Id = ticketId,
                Status__c = 'Resolved'
            );
            update as user ticket;
        } catch (Exception ex) {
            throw new AuraHandledException('Could not resolve ticket: ' + ex.getMessage());
        }
    }
}
