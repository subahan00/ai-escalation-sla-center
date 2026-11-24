try {
    GeminiTriageService.TriageResult res = GeminiTriageService.analyzeComplaint(
        'Our checkout payment gateway has been throwing 500 errors for 2 hours and we are losing live orders!',
        'Enterprise'
    );
    System.debug('=== SUCCESS ===');
    System.debug('Sentiment: ' + res.sentimentScore);
    System.debug('Category:  ' + res.category);
    System.debug('Summary:   ' + res.summary);
} catch (GeminiTriageService.GeminiCalloutException ex) {
    System.debug('=== GEMINI ERROR ===');
    System.debug('HTTP Status:   ' + ex.statusCode);
    System.debug('Message:       ' + ex.getMessage());
    System.debug('Response Body: ' + ex.responseBody);
}