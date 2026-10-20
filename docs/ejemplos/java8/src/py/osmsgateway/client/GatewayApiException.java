package py.osmsgateway.client;

/**
 * El gateway respondio con un error de la API (400, 401, 404, 405, 409, 413,
 * 429, 503...). La peticion NO se encolo, asi que el SMS no saldra. Reintentar
 * sin corregir la causa no sirve, salvo 429/503 que son transitorios.
 *
 * Los errores de red (sin respuesta) NO son esta excepcion: son IOException.
 */
public class GatewayApiException extends RuntimeException {
    private static final long serialVersionUID = 1L;

    private final int httpStatus;
    private final String code;

    public GatewayApiException(int httpStatus, String code, String message) {
        super(httpStatus + " " + code + ": " + message);
        this.httpStatus = httpStatus;
        this.code = code;
    }

    public int getHttpStatus() { return httpStatus; }

    /** Codigo estable de la API, por ejemplo INVALID_PHONE o MONTHLY_LIMIT. */
    public String getCode() { return code; }

    /** Errores transitorios: tiene sentido reintentar mas tarde con la misma clave. */
    public boolean isTransient() {
        return httpStatus == 429 || httpStatus == 503;
    }
}
