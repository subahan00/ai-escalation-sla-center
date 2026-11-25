public with sharing class EscalationTriggerHandler {

    @TestVisible
    public static Boolean bypassTrigger = false;

    // Prevents duplicate Platform Events for the same record in one transaction
    private static Set<Id> alertedTicketIds = new Set<Id>();

    public static void handleAfterInsert(List<Escalation_Ticket__c> newTickets) {
        if (bypassTrigger || newTickets == null || newTickets.isEmpty()) {
            return;
        }

        List<Id> pendingTicketIds = new List<Id>();
        for (Escalation_Ticket__c ticket : newTickets) {
            if (ticket.Status__c == 'Pending Triage') {
                pendingTicketIds.add(ticket.Id);
            }
        }

        if (!pendingTicketIds.isEmpty()
            && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new AITriageQueueable(pendingTicketIds));
        }
    }

    public static void handleBeforeUpdate(
        List<Escalation_Ticket__c> newTickets,
        Map<Id, Escalation_Ticket__c> oldTicketMap
    ) {
        if (bypassTrigger || newTickets == null || newTickets.isEmpty()) {
            return;
        }

        for (Escalation_Ticket__c ticket : newTickets) {
            Escalation_Ticket__c oldTicket = oldTicketMap.get(ticket.Id);

            Boolean justTriaged = ticket.Status__c == 'Triaged'
                && oldTicket != null
                && (oldTicket.Status__c != 'Triaged'
                    || ticket.Sentiment_Score__c != oldTicket.Sentiment_Score__c);

            if (justTriaged && ticket.Sentiment_Score__c != null) {
                SLACalculatorService.SLAResult sla = SLACalculatorService.calculateSLA(
                    ticket.Customer_Tier__c,
                    ticket.Sentiment_Score__c,
                    System.now()
                );

                ticket.SLA_Hours__c = sla.slaHours;
                ticket.Resolution_Deadline__c = sla.resolutionDeadline;

                if (sla.isHighRisk) {
                    ticket.Status__c = 'Escalated';
                }
            }
        }
    }

    public static void handleAfterUpdate(
        List<Escalation_Ticket__c> newTickets,
        Map<Id, Escalation_Ticket__c> oldTicketMap
    ) {
        if (bypassTrigger || newTickets == null || newTickets.isEmpty()) {
            return;
        }

        List<Escalation_Alert__e> alertsToPublish = new List<Escalation_Alert__e>();

        for (Escalation_Ticket__c ticket : newTickets) {
            Escalation_Ticket__c oldTicket = oldTicketMap.get(ticket.Id);

            Boolean newlyEscalated = ticket.Status__c == 'Escalated'
                && oldTicket != null
                && oldTicket.Status__c != 'Escalated'
                && !alertedTicketIds.contains(ticket.Id);

            if (newlyEscalated) {
                alertedTicketIds.add(ticket.Id);
                alertsToPublish.add(new Escalation_Alert__e(
                    Ticket_Id__c = String.valueOf(ticket.Id),
                    Ticket_Number__c = ticket.Name,
                    Customer_Name__c = ticket.Customer_Name__c,
                    Customer_Tier__c = ticket.Customer_Tier__c,
                    Sentiment_Score__c = ticket.Sentiment_Score__c,
                    Category__c = ticket.Category__c,
                    AI_Summary__c = ticket.AI_Summary__c,
                    Resolution_Deadline__c = ticket.Resolution_Deadline__c
                ));
            }
        }

        if (!alertsToPublish.isEmpty()) {
            List<Database.SaveResult> results = EventBus.publish(alertsToPublish);
            for (Database.SaveResult sr : results) {
                if (!sr.isSuccess()) {
                    for (Database.Error err : sr.getErrors()) {
                        System.debug(LoggingLevel.ERROR,
                            'Escalation_Alert__e publish failed: ' + err.getMessage());
                    }
                }
            }
        }
    }
}
