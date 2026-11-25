@IsTest
public class GeminiCalloutMock implements HttpCalloutMock {

    private Integer statusCode;
    private String responseBody;

    public GeminiCalloutMock(Integer statusCode, String responseBody) {
        this.statusCode = statusCode;
        this.responseBody = responseBody;
    }

    public static GeminiCalloutMock success(Integer sentimentScore, String category, String summary) {
        Map<String, Object> aiPayload = new Map<String, Object>{
            'sentimentScore' => sentimentScore,
            'category' => category,
            'summary' => summary
        };
        return rawText(200, JSON.serialize(aiPayload));
    }

    public static GeminiCalloutMock rawText(Integer statusCode, String rawModelText) {
        Map<String, Object> envelope = new Map<String, Object>{
            'candidates' => new List<Object>{
                new Map<String, Object>{
                    'content' => new Map<String, Object>{
                        'parts' => new List<Object>{
                            new Map<String, Object>{ 'text' => rawModelText }
                        }
                    }
                }
            }
        };
        return new GeminiCalloutMock(statusCode, JSON.serialize(envelope));
    }

    public static GeminiCalloutMock error(Integer statusCode, String errorMessage) {
        Map<String, Object> errBody = new Map<String, Object>{
            'error' => new Map<String, Object>{
                'code' => statusCode,
                'message' => errorMessage
            }
        };
        return new GeminiCalloutMock(statusCode, JSON.serialize(errBody));
    }

    public HttpResponse respond(HttpRequest req) {
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');
        res.setStatusCode(this.statusCode);
        res.setBody(this.responseBody);
        return res;
    }
}
