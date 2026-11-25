import { LightningElement } from 'lwc';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTickets from '@salesforce/apex/EscalationCommandController.getTickets';
import getFailedLogs from '@salesforce/apex/EscalationCommandController.getFailedLogs';
import retryFailedLog from '@salesforce/apex/EscalationCommandController.retryFailedLog';
import resolveTicket from '@salesforce/apex/EscalationCommandController.resolveTicket';

const CHANNEL_NAME = '/event/Escalation_Alert__e';

export default class EscalationCommandBoard extends LightningElement {
    tickets = [];
    failedLogs = [];
    isLoading = true;
    activeTab = 'board';
    selectedStatus = 'All';
    selectedCategory = 'All';
    latestAlert = null;
    isSubscribed = false;
    nowMs = Date.now();
    flashingIds = [];

    subscription = null;
    countdownInterval = null;
    retryRefreshTimeout = null;

    statusOptions = [
        { label: 'All Statuses', value: 'All' },
        { label: 'Escalated', value: 'Escalated' },
        { label: 'Triaged', value: 'Triaged' },
        { label: 'Pending Triage', value: 'Pending Triage' },
        { label: 'Triage Failed', value: 'Triage Failed' },
        { label: 'Resolved', value: 'Resolved' }
    ];

    categoryOptions = [
        { label: 'All Categories', value: 'All' },
        { label: 'Billing', value: 'Billing' },
        { label: 'Technical', value: 'Technical' },
        { label: 'Account Access', value: 'Account Access' },
        { label: 'Service Outage', value: 'Service Outage' },
        { label: 'General', value: 'General' }
    ];

    connectedCallback() {
        this.loadDashboardData();
        this.subscribeToAlerts();
        this.registerEmpErrorListener();

        // Tick every second to drive live SLA countdowns
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.countdownInterval = setInterval(() => {
            this.nowMs = Date.now();
        }, 1000);
    }

    disconnectedCallback() {
        if (this.countdownInterval) {
            clearInterval(this.countdownInterval);
        }
        if (this.retryRefreshTimeout) {
            clearTimeout(this.retryRefreshTimeout);
        }
        if (this.subscription && this.subscription.subscription) {
            unsubscribe(this.subscription, () => {
                this.isSubscribed = false;
            });
        }
    }

    async loadDashboardData() {
        this.isLoading = true;
        try {
            const [ticketData, logData] = await Promise.all([
                getTickets(),
                getFailedLogs()
            ]);
            this.tickets = ticketData || [];
            this.failedLogs = logData || [];
        } catch (error) {
            this.showToast('Load Error', this.extractError(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    subscribeToAlerts() {
        const messageCallback = (response) => {
            const payload = response?.data?.payload;
            if (!payload) {
                return;
            }
            this.handleIncomingAlert(payload);
        };

        subscribe(CHANNEL_NAME, -1, messageCallback).then((response) => {
            this.subscription = response;
            this.isSubscribed = true;
        });
    }

    registerEmpErrorListener() {
        onError((error) => {
            // eslint-disable-next-line no-console
            console.error('empApi error:', JSON.stringify(error));
            this.isSubscribed = false;
        });
    }

    handleIncomingAlert(payload) {
        this.latestAlert = {
            ticketId: payload.Ticket_Id__c,
            ticketNumber: payload.Ticket_Number__c,
            customerName: payload.Customer_Name__c,
            customerTier: payload.Customer_Tier__c,
            sentimentScore: payload.Sentiment_Score__c,
            category: payload.Category__c,
            summary: payload.AI_Summary__c,
            deadline: payload.Resolution_Deadline__c
        };

        if (payload.Ticket_Id__c && !this.flashingIds.includes(payload.Ticket_Id__c)) {
            this.flashingIds = [...this.flashingIds, payload.Ticket_Id__c];
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                this.flashingIds = this.flashingIds.filter((id) => id !== payload.Ticket_Id__c);
            }, 12000);
        }

        this.showToast(
            `HIGH-RISK ESCALATION: ${payload.Ticket_Number__c}`,
            `${payload.Customer_Name__c} (${payload.Customer_Tier__c}) — Sentiment ${payload.Sentiment_Score__c}/10`,
            'error'
        );

        this.loadDashboardData();
    }

    handleDismissAlert() {
        this.latestAlert = null;
    }

    handleRefreshClick() {
        this.loadDashboardData();
    }

    handleStatusChange(event) {
        this.selectedStatus = event.detail.value;
    }

    handleCategoryChange(event) {
        this.selectedCategory = event.detail.value;
    }

    handleTabSelect(event) {
        this.activeTab = event.currentTarget.dataset.tab;
    }

    async handleResolveTicket(event) {
        const ticketId = event.currentTarget.dataset.id;
        try {
            await resolveTicket({ ticketId });
            this.showToast('Ticket Resolved', 'Escalation ticket marked as Resolved.', 'success');
            await this.loadDashboardData();
        } catch (error) {
            this.showToast('Update Failed', this.extractError(error), 'error');
        }
    }

    async handleRetryLog(event) {
        const logId = event.currentTarget.dataset.id;
        try {
            await retryFailedLog({ logId });
            this.showToast(
                'Retry Queued',
                'AITriageQueueable has been enqueued. Refreshing results shortly...',
                'info'
            );
            await this.loadDashboardData();

            // Auto-refresh once the async Queueable completes (~4s)
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this.retryRefreshTimeout = setTimeout(() => {
                this.loadDashboardData();
            }, 4000);
        } catch (error) {
            this.showToast('Retry Failed', this.extractError(error), 'error');
        }
    }

    // --- Computed Getters ---
    get isBoardTab() {
        return this.activeTab === 'board';
    }

    get isLogsTab() {
        return this.activeTab === 'logs';
    }

    get boardTabClass() {
        return this.isBoardTab ? 'tab-btn tab-active' : 'tab-btn';
    }

    get logsTabClass() {
        return this.isLogsTab ? 'tab-btn tab-active' : 'tab-btn';
    }

    get streamStatusLabel() {
        return this.isSubscribed ? 'LIVE (empApi Connected)' : 'Connecting to Event Bus...';
    }

    get streamBadgeClass() {
        return this.isSubscribed ? 'stream-badge stream-online' : 'stream-badge stream-offline';
    }

    get totalActiveCount() {
        return this.tickets.filter((t) => t.Status__c !== 'Resolved').length;
    }

    get escalatedCount() {
        return this.tickets.filter((t) => t.Status__c === 'Escalated').length;
    }

    get pendingCount() {
        return this.tickets.filter((t) => t.Status__c === 'Pending Triage').length;
    }

    get failedLogsCount() {
        return this.failedLogs.length;
    }

    get hasFailedLogs() {
        return this.failedLogs.length > 0;
    }

    get formattedLogs() {
        return this.failedLogs.map((log) => ({
            ...log,
            ticketNumber: log.Escalation_Ticket__r ? log.Escalation_Ticket__r.Name : 'Unlinked',
            customerName: log.Escalation_Ticket__r ? log.Escalation_Ticket__r.Customer_Name__c : '—',
            statusCodeDisplay: log.HTTP_Status_Code__c ? `HTTP ${log.HTTP_Status_Code__c}` : 'Runtime/Validation',
            canRetry: Boolean(log.Escalation_Ticket__c)
        }));
    }

    get filteredTickets() {
        return this.tickets
            .filter((t) => {
                const statusMatch = this.selectedStatus === 'All' || t.Status__c === this.selectedStatus;
                const categoryMatch = this.selectedCategory === 'All' || t.Category__c === this.selectedCategory;
                return statusMatch && categoryMatch;
            })
            .map((t) => {
                const isFlashing = this.flashingIds.includes(t.Id);
                const isEscalated = t.Status__c === 'Escalated';
                const countdown = this.computeCountdown(t.Resolution_Deadline__c, t.Status__c);

                let cardClass = 'ticket-card';
                if (isFlashing) {
                    cardClass += ' card-flash-red';
                } else if (isEscalated) {
                    cardClass += ' card-escalated';
                } else if (t.Status__c === 'Triage Failed') {
                    cardClass += ' card-failed';
                }

                const score = t.Sentiment_Score__c;
                let sentimentClass = 'pill pill-neutral';
                if (score >= 8) {
                    sentimentClass = 'pill pill-danger';
                } else if (score >= 5) {
                    sentimentClass = 'pill pill-warning';
                } else if (score != null) {
                    sentimentClass = 'pill pill-success';
                }

                return {
                    ...t,
                    cardClass,
                    sentimentClass,
                    sentimentLabel: score != null ? `Sentiment ${score}/10` : 'Unscored',
                    categoryLabel: t.Category__c || 'Uncategorized',
                    summaryDisplay: t.AI_Summary__c || t.Complaint_Text__c || 'No summary available.',
                    slaCountdown: countdown.label,
                    countdownClass: countdown.cssClass,
                    canResolve: t.Status__c !== 'Resolved'
                };
            });
    }

    get hasFilteredTickets() {
        return this.filteredTickets.length > 0;
    }

    computeCountdown(deadlineIso, status) {
        if (status === 'Resolved') {
            return { label: 'Resolved', cssClass: 'sla-ok' };
        }
        if (!deadlineIso) {
            return { label: 'Awaiting SLA', cssClass: 'sla-muted' };
        }

        const diffMs = new Date(deadlineIso).getTime() - this.nowMs;
        if (diffMs <= 0) {
            return { label: 'SLA BREACHED', cssClass: 'sla-breached' };
        }

        const totalSec = Math.floor(diffMs / 1000);
        const hours = Math.floor(totalSec / 3600);
        const mins = Math.floor((totalSec % 3600) / 60);
        const secs = totalSec % 60;
        const pad = (n) => String(n).padStart(2, '0');

        const cssClass = diffMs < 3600000 ? 'sla-urgent' : 'sla-active';
        return {
            label: `${hours}h ${pad(mins)}m ${pad(secs)}s left`,
            cssClass
        };
    }

    extractError(error) {
        if (error?.body?.message) {
            return error.body.message;
        }
        return error?.message || 'Unexpected error occurred.';
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
