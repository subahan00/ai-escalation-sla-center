Escalation_Ticket__c badTicket = new Escalation_Ticket__c(
    Customer_Name__c = 'Test Failure User',
    Customer_Tier__c = 'Standard',
    External_Source__c = 'Web Portal',
    Complaint_Text__c = '',
    Status__c = 'Pending Triage'
);
insert badTicket;

Id jobId = System.enqueueJob(new AITriageQueueable(new List<Id>{ badTicket.Id }));
System.debug('Enqueued failure test Job ID: ' + jobId + ' for Ticket ID: ' + badTicket.Id);