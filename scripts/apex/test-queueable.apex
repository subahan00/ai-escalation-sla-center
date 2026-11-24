List<Escalation_Ticket__c> pending = [
    SELECT Id, Name
    FROM Escalation_Ticket__c
    WHERE Status__c = 'Pending Triage'
    ORDER BY CreatedDate DESC
    LIMIT 1
];

if (pending.isEmpty()) {
    System.debug('No Pending Triage tickets found. Send one from Postman first!');
} else {
    Id jobId = System.enqueueJob(new AITriageQueueable(new List<Id>{ pending[0].Id }));
    System.debug('Enqueued AITriageQueueable Job ID: ' + jobId + ' for ' + pending[0].Name);
}