public with sharing class SLACalculatorService {

    private static final Decimal DEFAULT_SLA_HOURS = 24.0;
    private static Id cachedDefaultBusinessHoursId;
    private static Boolean businessHoursLoaded = false;

    public class SLAResult {
        public Decimal slaHours;
        public Datetime resolutionDeadline;
        public Boolean isHighRisk;
    }

    public static SLAResult calculateSLA(
        String customerTier,
        Decimal sentimentScore,
        Datetime referenceTime
    ) {
        Datetime startTime = (referenceTime != null) ? referenceTime : System.now();
        SLA_Rule__mdt matchedRule = findMatchingRule(customerTier, sentimentScore);

        SLAResult result = new SLAResult();
        result.slaHours = (matchedRule != null) ? matchedRule.SLA_Hours__c : DEFAULT_SLA_HOURS;
        result.isHighRisk = (matchedRule != null) ? matchedRule.Is_High_Risk__c : false;
        result.resolutionDeadline = addBusinessHours(startTime, result.slaHours);
        return result;
    }

    private static SLA_Rule__mdt findMatchingRule(String customerTier, Decimal sentimentScore) {
        if (String.isBlank(customerTier) || sentimentScore == null) {
            return null;
        }

        // getAll() reads from application cache (0 SOQL queries)
        for (SLA_Rule__mdt rule : SLA_Rule__mdt.getAll().values()) {
            Boolean tierMatches = rule.Customer_Tier__c != null
                && rule.Customer_Tier__c.equalsIgnoreCase(customerTier.trim());
            Boolean scoreInRange = sentimentScore >= rule.Min_Sentiment__c
                && sentimentScore <= rule.Max_Sentiment__c;

            if (tierMatches && scoreInRange) {
                return rule;
            }
        }
        return null;
    }

    private static Datetime addBusinessHours(Datetime startTime, Decimal slaHours) {
        Long intervalMs = (slaHours * 60 * 60 * 1000).longValue();
        Id bhId = getDefaultBusinessHoursId();

        if (bhId != null) {
            return BusinessHours.add(bhId, startTime, intervalMs);
        }
        // Fallback if org has no default BusinessHours configured
        return startTime.addMinutes((slaHours * 60).intValue());
    }

    private static Id getDefaultBusinessHoursId() {
        if (!businessHoursLoaded) {
            List<BusinessHours> defaultHours = [
                SELECT Id
                FROM BusinessHours
                WHERE IsDefault = true
                LIMIT 1
            ];
            cachedDefaultBusinessHoursId = defaultHours.isEmpty() ? null : defaultHours[0].Id;
            businessHoursLoaded = true;
        }
        return cachedDefaultBusinessHoursId;
    }
}
