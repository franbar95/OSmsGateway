package py.osmsgateway.client;

import com.fasterxml.jackson.databind.JsonNode;

import java.time.Instant;

/** Estado de un SMS tal como lo informa el gateway. Inmutable. */
public final class SmsStatus {
    private final int httpStatus;
    private final String id;
    private final SmsState state;
    private final String maskedPhone;
    private final Integer parts;
    private final int attempts;
    private final Boolean duplicate;
    private final Instant createdAt;
    private final Instant acceptedAt;
    private final Instant sentAt;
    private final Instant deliveredAt;
    private final String error;
    private final String detail;

    private SmsStatus(int httpStatus, JsonNode j) {
        this.httpStatus = httpStatus;
        this.id = text(j, "id");
        this.state = SmsState.parse(text(j, "state"));
        this.maskedPhone = text(j, "phone");
        this.parts = j.hasNonNull("parts") ? Integer.valueOf(j.get("parts").asInt()) : null;
        this.attempts = j.path("attempts").asInt(0);
        // "duplicate" solo viene en la respuesta del POST.
        this.duplicate = j.hasNonNull("duplicate") ? Boolean.valueOf(j.get("duplicate").asBoolean()) : null;
        this.createdAt = instant(j, "createdAt");
        this.acceptedAt = instant(j, "acceptedAt");
        this.sentAt = instant(j, "sentAt");
        this.deliveredAt = instant(j, "deliveredAt");
        this.error = text(j, "error");
        this.detail = text(j, "detail");
    }

    static SmsStatus from(int httpStatus, JsonNode json) {
        return new SmsStatus(httpStatus, json);
    }

    private static String text(JsonNode j, String field) {
        return j.hasNonNull(field) ? j.get(field).asText() : null;
    }

    private static Instant instant(JsonNode j, String field) {
        String v = text(j, field);
        return v == null ? null : Instant.parse(v); // ISO-8601 en UTC
    }

    /** Codigo HTTP con el que respondio el gateway (200, 202 o 500). */
    public int getHttpStatus() { return httpStatus; }
    public String getId() { return id; }
    public SmsState getState() { return state; }
    /** Telefono enmascarado, por ejemplo +5959****9760. */
    public String getMaskedPhone() { return maskedPhone; }
    /** Partes del SMS; null hasta que Android acepta la solicitud. */
    public Integer getParts() { return parts; }
    public int getAttempts() { return attempts; }
    /** true si el gateway devolvio un mensaje ya existente (idempotencia); null en GET. */
    public Boolean getDuplicate() { return duplicate; }
    public Instant getCreatedAt() { return createdAt; }
    public Instant getAcceptedAt() { return acceptedAt; }
    public Instant getSentAt() { return sentAt; }
    /** Solo no es null con informe de entrega de la operadora. */
    public Instant getDeliveredAt() { return deliveredAt; }
    public String getError() { return error; }
    public String getDetail() { return detail; }

    @Override
    public String toString() {
        return "SmsStatus{id=" + id + ", state=" + state + ", http=" + httpStatus
                + ", attempts=" + attempts + ", error=" + error + "}";
    }
}
