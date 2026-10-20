package py.osmsgateway.client;

import java.io.IOException;

/**
 * Ejemplo de uso. Ejecutar con:
 *   java -cp ... py.osmsgateway.client.EjemploUso http://192.168.1.50:8080 TOKEN +595982123456 "Hola"
 *
 * ATENCION: envia un SMS REAL. Para probar sin enviar, use un telefono
 * invalido: el gateway responde 400 INVALID_PHONE y no encola nada.
 */
public class EjemploUso {

    public static void main(String[] args) throws Exception {
        if (args.length < 4) {
            System.err.println("Uso: EjemploUso <baseUrl> <token|-> <telefono> <texto>");
            System.exit(2);
        }
        OsmsGatewayClient client = new OsmsGatewayClient(args[0], "-".equals(args[1]) ? null : args[1]);

        if (!client.isAlive()) {
            System.err.println("El gateway no responde. Revise: telefono con la app abierta y servidor en marcha.");
            System.exit(1);
        }

        // La clave identifica el mensaje DE NEGOCIO. Si este programa se
        // reejecuta con la misma clave, el SMS no se vuelve a enviar.
        String key = "ejemplo-" + args[2].replaceAll("[^0-9]", "") + "-aviso-1";

        try {
            SmsStatus s = client.enqueueWithRetry(args[2], args[3], key, 3, 1_000);
            System.out.println("Encolado: " + s + " duplicado=" + s.getDuplicate());

            s = client.awaitSettled(s.getId(), 60_000, 1_000);
            System.out.println("Resultado: " + s);

            switch (s.getState()) {
                case SENT_BY_MODEM:
                case DELIVERED_CONFIRMED:
                    System.out.println("OK: el SMS salio del telefono"
                            + (s.getDeliveredAt() != null ? " y la operadora confirmo la entrega." : "."));
                    break;
                case FAILED:
                    System.out.println("FALLO: no salio (" + s.getError() + "). Se puede reenviar con otra clave.");
                    break;
                case DELIVERY_FAILED:
                    System.out.println("Salio, pero la operadora informo que no se entrego.");
                    break;
                case UNKNOWN:
                    System.out.println("DESCONOCIDO: puede haber salido o no. NO reenviar sin decision de negocio.");
                    break;
                default:
                    System.out.println("Sin resolver aun (" + s.getState() + "). Consulte mas tarde: " + s.getId());
            }
        } catch (GatewayApiException e) {
            System.err.println("El gateway rechazo la peticion: " + e.getMessage());
            System.exit(1);
        } catch (IOException e) {
            System.err.println("Error de red; el estado es incierto. Repita con la MISMA clave: " + e);
            System.exit(1);
        }
    }
}
