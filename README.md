# AI-Assisted Customer Escalation & SLA Command Center (Salesforce)

An event-driven Salesforce enterprise application that ingests external customer complaints via Apex REST, triages sentiment and category asynchronously using Google Gemini, calculates dynamic `BusinessHours`-aware SLAs via Custom Metadata, and streams live high-risk alerts to a Lightning Web Component dashboard without page refreshes.

## End-to-End Architecture

1. **Inbound Webhook (`EscalationWebhookController`)** — `@RestResource` endpoint (`/services/apexrest/api/escalations/*`) validates JSON payloads, enforces FLS/CRUD (`insert as user`), and creates `Escalation_Ticket__c` (`Pending Triage`).
2. **Async AI Triage (`AITriageQueueable` + `GeminiTriageService`)** — Triggered in `after insert`; processes tickets in chunks of 5 with `Queueable` chaining, authenticates securely via **External Credentials + Named Credentials** (`x-goog-api-key` merge formula), requests structured JSON (`responseSchema`), and applies defensive Apex parsing.
3. **Self-Healing Failure Logging (`AITriageFinalizer` + `Integration_Log__c`)** — Per-record `try/catch` isolates HTTP `429`/`503` errors without aborting the batch, while `System.Finalizer` catches unhandled `LimitException` crashes in a fresh transaction. Admins replay failed records in 1 click from the LWC.
4. **Dynamic SLA Engine (`EscalationTriggerHandler` + `SLACalculatorService`)** — Runs in `before update` (zero extra DML), reads `SLA_Rule__mdt.getAll()` (0 SOQL), computes `Resolution_Deadline__c` using org `BusinessHours.add()`, and publishes `Escalation_Alert__e` via `EventBus.publish()` in `after update`.
5. **Real-Time LWC Command Board (`escalationCommandBoard`)** — Subscribes to `/event/Escalation_Alert__e` via `lightning/empApi`, flashes high-risk cards red with zero refresh, runs live 1-second SLA countdown timers, and exposes a Failed Integrations retry tab.

## Architecture Decision Record (ADR)

| Decision | Chosen Approach | Rejected Alternative | Rationale |
| :--- | :--- | :--- | :--- |
| **Real-Time LWC Updates** | Platform Event (`Escalation_Alert__e`, `PublishAfterCommit`) + `lightning/empApi` | `setInterval` polling via Apex | Push-based CometD eliminates wasted API/SOQL calls; `PublishAfterCommit` prevents ghost UI alerts if a transaction rolls back |
| **SLA Rule Storage** | Custom Metadata Type (`SLA_Rule__mdt`) read via `getAll()` | Hardcoded Apex constants or Custom Settings | Zero SOQL cost from application cache, deployable via SFDX/Git across sandboxes without Data Loader, admin-configurable without code deploys |
| **External AI Security** | External Credential (Named Principal) + Named Credential + Permission Set | Remote Site Settings + hardcoded API key | Keeps secrets encrypted inside Salesforce and completely out of Apex code, debug logs, and version control |
| **Async Orchestration** | `Queueable` (`Database.AllowsCallouts`) + `System.Finalizer` | `@future(callout=true)` | Supports chunked job chaining for bulk inserts, complex types, and uncatchable crash recovery via `System.Finalizer` |
| **Error Log Relationship** | Optional Lookup (`Escalation_Ticket__c` on `Integration_Log__c`) | Master-Detail relationship | Keeps audit logs decoupled so logs survive ticket deletion and can record pre-insert failures |

## Governor-Limit & Bulkification Proof

`EscalationEngineTest.testBulk200RecordsGovernorLimits` updates **200 `Escalation_Ticket__c` records** in a single DML transaction and programmatically asserts:
- `Limits.getQueries()` stays well below 100 (at most 2 SOQL queries total, via `SLA_Rule__mdt.getAll()` + static `BusinessHours` ID caching).
- `Limits.getDmlStatements()` stays minimal (`<= 5`).
- All 200 high-risk records accurately transition to `Escalated` with `BusinessHours`-adjusted `Resolution_Deadline__c`.

## Deployment & Verification

```bash
# 1. Deploy metadata & Apex/LWC source
sf project deploy start

# 2. Assign Permission Set (CRUD, FLS, Tabs, External Credential Principal Access)
sf org assign permset --name Escalation_Command_Admin

# 3. Run unit & 200-record bulk tests with coverage
sf apex run test --class-names EscalationWebhookControllerTest --class-names EscalationEngineTest --code-coverage --result-format human --wait 10
