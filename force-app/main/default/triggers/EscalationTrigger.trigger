trigger EscalationTrigger on Escalation_Ticket__c (after insert, before update, after update) {
    if (Trigger.isAfter && Trigger.isInsert) {
        EscalationTriggerHandler.handleAfterInsert(Trigger.new);
    } else if (Trigger.isBefore && Trigger.isUpdate) {
        EscalationTriggerHandler.handleBeforeUpdate(Trigger.new, Trigger.oldMap);
    } else if (Trigger.isAfter && Trigger.isUpdate) {
        EscalationTriggerHandler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
    }
}
