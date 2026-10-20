package py.osmsgateway.client;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

/**
 * Cliente minimo del gateway OSmsGateway. Requiere Java 8 y Jackson
 * (jackson-databind 2.12.x es compatible con Java 8). Sin otras dependencias.
 *
 * Es thread-safe: no guarda estado mutable.
 *
 * Patron recomendado (ver docs/INTEGRACION_JAVA8.md):
 * <pre>
 *   SmsStatus s = client.enqueueWithRetry(phone, text, "pedido-123-aviso", 3, 1000);
 *   s = client.awaitSettled(s.getId(), 60_000, 1_000);
 * </pre>
 */
public class OsmsGatewayClient {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private final String baseUrl;
    private final String token;
    private int connectTimeoutMs = 3_000;
    private int readTimeoutMs = 10_000;

    /**
     * @param baseUrl por ejemplo "http://192.168.1.50:8080" (sin barra final)
     * @param token   token del gateway, o null si el gateway no exige token
     */
    public OsmsGatewayClient(String baseUrl, String token) {
        this.baseUrl = baseUrl.endsWith("/") ? baseUrl.substring(0, baseUrl.length() - 1) : baseUrl;
        this.token = (token == null || token.isEmpty()) ? null : token;
    }

    public OsmsGatewayClient timeouts(int connectTimeoutMs, int readTimeoutMs) {
        this.connectTimeoutMs = connectTimeoutMs;
        this.readTimeoutMs = readTimeoutMs;
        return this;
    }

    // ------------------------------------------------------------------ API

    /**
     * Encola el SMS y vuelve enseguida (HTTP 202, estado QUEUED). No espera a
     * que salga. Con la misma {@code idempotencyKey} nunca se envia dos veces.
     *
     * @param phone          preferentemente E.164: +595982123456
     * @param idempotencyKey 1 a 128 caracteres ASCII imprimibles, sin espacios;
     *                       unica por mensaje de negocio (p. ej. "pedido-123-aviso")
     * @throws GatewayApiException el gateway rechazo la peticion (no se encolo)
     * @throws IOException         error de red: no se sabe si llego; es seguro
     *                             repetir con la MISMA idempotencyKey
     */
    public SmsStatus enqueue(String phone, String message, String idempotencyKey) throws IOException {
        return post(phone, message, idempotencyKey, false);
    }

    /**
     * Como {@link #enqueue} pero hace que el gateway espere (hasta su propio
     * "Timeout") a que el SMS salga antes de responder. Prefiera enqueue +
     * awaitSettled, que le da control total del tiempo de espera.
     */
    public SmsStatus enqueueAndWait(String phone, String message, String idempotencyKey,
                                    int clientReadTimeoutMs) throws IOException {
        int previous = readTimeoutMs;
        try {
            readTimeoutMs = clientReadTimeoutMs;
            return post(phone, message, idempotencyKey, true);
        } finally {
            readTimeoutMs = previous;
        }
    }

    /**
     * enqueue con reintentos ante errores de RED. Es seguro porque la
     * idempotencyKey impide duplicados. NO reintenta errores de la API.
     */
    public SmsStatus enqueueWithRetry(String phone, String message, String idempotencyKey,
                                      int maxAttempts, long backoffMs)
            throws IOException, InterruptedException {
        IOException last = null;
        for (int attempt = 1; attempt <= maxAttempts; attempt++) {
            try {
                return enqueue(phone, message, idempotencyKey);
            } catch (GatewayApiException e) {
                if (!e.isTransient() || attempt == maxAttempts) {
                    throw e;
                }
            } catch (IOException e) {
                last = e;
                if (attempt == maxAttempts) {
                    throw e;
                }
            }
            Thread.sleep(backoffMs * attempt);
        }
        throw last != null ? last : new IOException("sin intentos");
    }

    /** Consulta el estado actual (siempre HTTP 200 si el id existe; 404 si no). */
    public SmsStatus getStatus(String id) throws IOException {
        return toStatusOrThrow(call("GET", "/v1/sms/" + id, null, null));
    }

    /**
     * Consulta periodicamente hasta que el mensaje deja de cambiar (ver
     * {@link SmsState#isSettled()}) o vence {@code timeoutMs}. En ese caso
     * devuelve el ultimo estado conocido, que puede NO estar resuelto.
     */
    public SmsStatus awaitSettled(String id, long timeoutMs, long pollMs)
            throws IOException, InterruptedException {
        long deadline = System.currentTimeMillis() + timeoutMs;
        SmsStatus status = getStatus(id);
        while (!status.getState().isSettled() && System.currentTimeMillis() < deadline) {
            Thread.sleep(pollMs);
            status = getStatus(id);
        }
        return status;
    }

    /** Resumen de la cola: pendientes, conteo por estado, uso mensual y limite. */
    public JsonNode queueSummary() throws IOException {
        Response r = call("GET", "/v1/queue/", null, null);
        if (r.json == null || r.json.hasNonNull("error")) {
            throw apiError(r);
        }
        return r.json;
    }

    /** true si el gateway responde. Sirve como health-check. */
    public boolean isAlive() {
        try {
            queueSummary();
            return true;
        } catch (IOException | RuntimeException e) {
            return false;
        }
    }

    // ------------------------------------------------------------- internos

    private SmsStatus post(String phone, String message, String idempotencyKey, boolean wait)
            throws IOException {
        ObjectNode body = MAPPER.createObjectNode();
        body.put("phone", phone);
        body.put("message", message);
        body.put("wait", wait); // explicito: no depender del valor por defecto del gateway
        return toStatusOrThrow(call("POST", "/v1/sms/", MAPPER.writeValueAsString(body), idempotencyKey));
    }

    private static final class Response {
        final int code;
        final JsonNode json;

        Response(int code, JsonNode json) {
            this.code = code;
            this.json = json;
        }
    }

    private Response call(String method, String path, String jsonBody, String idempotencyKey)
            throws IOException {
        HttpURLConnection c = (HttpURLConnection) new URL(baseUrl + path).openConnection();
        try {
            c.setRequestMethod(method);
            c.setConnectTimeout(connectTimeoutMs);
            c.setReadTimeout(readTimeoutMs);
            c.setRequestProperty("Accept", "application/json");
            if (token != null) {
                c.setRequestProperty("Authorization", "Bearer " + token);
            }
            if (idempotencyKey != null) {
                c.setRequestProperty("Idempotency-Key", idempotencyKey);
            }
            if (jsonBody != null) {
                byte[] bytes = jsonBody.getBytes(StandardCharsets.UTF_8);
                c.setDoOutput(true);
                c.setRequestProperty("Content-Type", "application/json; charset=UTF-8");
                // No usar setFixedLengthStreamingMode ni setChunkedStreamingMode: en modo
                // streaming, un 401 con WWW-Authenticate (lo que envia el gateway) lanza
                // HttpRetryException y se pierde el cuerpo del error.
                c.getOutputStream().write(bytes);
            }
            int code = c.getResponseCode();
            InputStream in = code >= 400 ? c.getErrorStream() : c.getInputStream();
            String text = in == null ? "" : read(in);
            if (text.trim().isEmpty()) {
                return new Response(code, null);
            }
            try {
                return new Response(code, MAPPER.readTree(text));
            } catch (IOException notJson) {
                throw new IOException("El gateway respondio algo que no es JSON (HTTP " + code
                        + "): " + abbreviate(text), notJson);
            }
        } finally {
            c.disconnect();
        }
    }

    /**
     * Un cuerpo con "state" es un estado de mensaje (incluso si el HTTP es 500
     * porque el SMS fallo). Sin "state" es un error de la API.
     */
    private SmsStatus toStatusOrThrow(Response r) {
        if (r.json != null && r.json.hasNonNull("state")) {
            return SmsStatus.from(r.code, r.json);
        }
        throw apiError(r);
    }

    private GatewayApiException apiError(Response r) {
        String code = r.json != null && r.json.hasNonNull("error") ? r.json.get("error").asText() : "HTTP_" + r.code;
        String message = r.json != null && r.json.hasNonNull("message") ? r.json.get("message").asText() : "";
        return new GatewayApiException(r.code, code, message);
    }

    private static String read(InputStream in) throws IOException {
        try {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int n;
            while ((n = in.read(buf)) != -1) {
                out.write(buf, 0, n);
            }
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        } finally {
            in.close();
        }
    }

    private static String abbreviate(String s) {
        return s.length() <= 200 ? s : s.substring(0, 200) + "...";
    }
}
