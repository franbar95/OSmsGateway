package py.osmsgateway.client;

/**
 * Estados de un SMS en el gateway. Cada estado es un hecho distinto:
 *
 * <ul>
 *   <li>QUEUED: guardado en la cola del gateway, todavia no se pidio el envio.</li>
 *   <li>SENDING: se esta entregando a Android.</li>
 *   <li>ACCEPTED_BY_ANDROID: Android acepto la solicitud; no implica que haya salido.</li>
 *   <li>SENT_BY_MODEM: el modem informo que el SMS salio. NO implica entrega.</li>
 *   <li>DELIVERED_CONFIRMED: la operadora confirmo la entrega (informe de entrega).</li>
 *   <li>FAILED: no salio (rechazado, fallo de envio o vencio en la cola).</li>
 *   <li>DELIVERY_FAILED: salio, pero la operadora informo que NO se entrego.</li>
 *   <li>UNKNOWN: no se sabe si salio. El gateway NO lo reenvia solo.</li>
 * </ul>
 */
public enum SmsState {
    QUEUED, SENDING, ACCEPTED_BY_ANDROID, SENT_BY_MODEM, DELIVERED_CONFIRMED,
    FAILED, DELIVERY_FAILED, UNKNOWN;

    /** El SMS salio del telefono (aunque no haya confirmacion de entrega). */
    public boolean hasLeftPhone() {
        return this == SENT_BY_MODEM || this == DELIVERED_CONFIRMED || this == DELIVERY_FAILED;
    }

    /**
     * El gateway ya no hara mas por este mensaje salvo informes de entrega
     * tardios. Es la condicion para dejar de consultar el estado.
     */
    public boolean isSettled() {
        return hasLeftPhone() || this == FAILED || this == UNKNOWN;
    }

    /** Valor desconocido (version futura del gateway) se trata como UNKNOWN. */
    public static SmsState parse(String wire) {
        if (wire == null) {
            return UNKNOWN;
        }
        try {
            return valueOf(wire);
        } catch (IllegalArgumentException e) {
            return UNKNOWN;
        }
    }
}
