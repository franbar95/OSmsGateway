# Integración de OSmsGateway con un sistema Java 8

Guía para quien vaya a conectar un sistema Java 8 con el gateway. La referencia
exacta de la API está en [API.md](API.md); aquí está **cómo usarla bien**:
qué patrón seguir, qué decisiones de negocio hay que tomar y qué errores evitar.

El cliente de ejemplo (`docs/ejemplos/java8/`) está compilado con un JDK 8
real (`-source 1.8 -target 1.8`) y probado contra un gateway simulado y contra
el teléfono real, **sin enviar SMS** en esas pruebas.

## 1. Qué es el gateway y qué NO garantiza

Un teléfono Android con una SIM expone una API HTTP: su sistema le pide enviar
un SMS y el teléfono lo manda por la red celular.

| Garantiza | No garantiza |
|---|---|
| Un mismo `Idempotency-Key` **nunca produce dos SMS** | Que el destinatario lo reciba (no hay SLA de operadora) |
| El pedido se guarda en disco antes de responder | Disponibilidad 24/7: es un teléfono con la app abierta |
| Distingue "salió del teléfono" de "entrega confirmada" | Informes de entrega: la operadora puede no enviarlos |
| Lo que se perdió a mitad queda `UNKNOWN`, no se reenvía a ciegas | Que `UNKNOWN` signifique "no salió": puede haber salido |

**Regla de oro para su sistema:** `SENT_BY_MODEM` es el éxito práctico. No exija
`DELIVERED_CONFIRMED`: en las pruebas con la SIM Personal de Paraguay el SMS
llegó y el estado se quedó en `SENT_BY_MODEM`, porque no hubo informe de
entrega.

## 2. Arquitectura recomendada: tabla *outbox*

No llame al gateway dentro de la transacción de negocio ni espere el resultado
en la misma petición del usuario: el teléfono puede estar lento u ocupado y el
envío sale a un ritmo de uno cada 3 s.

```
  Transacción de negocio                Job "enviador"              Job "seguimiento"
  ┌────────────────────────┐       ┌────────────────────┐      ┌─────────────────────┐
  │ INSERT sms_outbox      │ ───►  │ PENDIENTE → POST   │ ───► │ ENCOLADO → GET /id  │
  │ estado = PENDIENTE     │       │ estado = ENCOLADO  │      │ estado = ENVIADO /  │
  │ clave  = "pedido-123-…"│       │ guarda gateway_id  │      │ FALLIDO / REVISION  │
  └────────────────────────┘       └────────────────────┘      └─────────────────────┘
```

Tabla sugerida (adaptar al motor de base de datos):

```sql
CREATE TABLE sms_outbox (
  id              BIGINT PRIMARY KEY,
  clave           VARCHAR(128) NOT NULL UNIQUE,  -- = Idempotency-Key; se genera UNA vez
  telefono        VARCHAR(20)  NOT NULL,         -- E.164: +595982123456
  texto           VARCHAR(1000) NOT NULL,
  estado          VARCHAR(20)  NOT NULL,         -- PENDIENTE, ENCOLADO, ENVIADO, FALLIDO, REVISION
  estado_gateway  VARCHAR(30),                   -- último state informado por el gateway
  gateway_id      VARCHAR(64),                   -- id devuelto por el POST
  creado          TIMESTAMP NOT NULL,
  enviado         TIMESTAMP,                     -- sentAt informado por el gateway
  entregado       TIMESTAMP,                     -- deliveredAt (solo con informe de la operadora)
  error           VARCHAR(100)
);
```

**La clave de idempotencia se genera una sola vez y se guarda antes del primer
intento.** Nunca la regenere en cada reintento ni use un UUID aleatorio por
llamada: ese error es el que produce SMS duplicados. Un buen formato es
`<entidad>-<id>-<motivo>-<n>`, por ejemplo `pedido-1234-aviso-1`.

## 3. Cliente Java 8 incluido

Archivos en `docs/ejemplos/java8/src/py/osmsgateway/client/`:

| Archivo | Contenido |
|---|---|
| `OsmsGatewayClient.java` | Cliente HTTP (`HttpURLConnection` + Jackson) |
| `SmsStatus.java` | Respuesta tipada (estado, fechas como `Instant`, error) |
| `SmsState.java` | Enum de estados, con `hasLeftPhone()` e `isSettled()` |
| `GatewayApiException.java` | El gateway rechazó la petición (no se encoló) |
| `EjemploUso.java` | Programa de ejemplo |

Dependencia (Maven). El cliente se compiló y probó con `jackson-databind`
2.12.7; las versiones 2.x de Jackson soportan Java 8, así que si su sistema ya
usa otra, sirve esa:

```xml
<dependency>
  <groupId>com.fasterxml.jackson.core</groupId>
  <artifactId>jackson-databind</artifactId>
  <version>2.12.7</version>
</dependency>
```

Compilar a mano sin Maven (con los tres jars de Jackson en `lib/`):

```bash
javac -source 1.8 -target 1.8 -encoding UTF-8 -cp "lib/*" -d out \
      docs/ejemplos/java8/src/py/osmsgateway/client/*.java
```

Sin dependencias externas, el cliente usa solo `java.net`, `java.time` y Jackson.
Cópielo a su proyecto y adapte el paquete; no hace falta publicarlo como librería.

### Uso mínimo

```java
OsmsGatewayClient gw = new OsmsGatewayClient("http://192.168.1.50:8080", System.getenv("OSMS_TOKEN"));

// 1) Encolar (devuelve enseguida). Los errores de red se reintentan con la MISMA clave.
SmsStatus s = gw.enqueueWithRetry("+595982123456", "Su pedido salió a reparto",
                                  "pedido-1234-aviso-1", 3, 1000);

// 2) Seguir el estado hasta que se resuelva (o venza su propio plazo)
s = gw.awaitSettled(s.getId(), 60_000, 1_000);

if (s.getState().hasLeftPhone()) {
    // OK: SENT_BY_MODEM, DELIVERED_CONFIRMED (o DELIVERY_FAILED: salió pero no se entregó)
}
```

### Patrón *outbox* con el cliente

```java
// Job enviador: PENDIENTE -> ENCOLADO
for (SmsOutbox row : repo.findByEstado("PENDIENTE", 50)) {
    try {
        SmsStatus s = gw.enqueueWithRetry(row.telefono, row.texto, row.clave, 3, 1000);
        repo.marcarEncolado(row.id, s.getId(), s.getState().name());
    } catch (GatewayApiException e) {
        if (e.isTransient()) continue;                 // 429 / 503: se reintenta en el próximo ciclo
        repo.marcarFallido(row.id, e.getCode());       // 400 / 401 / 409...: no se arregla reintentando
    } catch (IOException e) {
        // error de red: queda PENDIENTE; el próximo ciclo repite con la MISMA clave
    }
}

// Job seguimiento: ENCOLADO -> ENVIADO | FALLIDO | REVISION
for (SmsOutbox row : repo.findByEstado("ENCOLADO", 200)) {
    try {
        SmsStatus s = gw.getStatus(row.gatewayId);
        switch (s.getState()) {
            case SENT_BY_MODEM: case DELIVERED_CONFIRMED:
                repo.marcarEnviado(row.id, s.getSentAt(), s.getDeliveredAt()); break;
            case DELIVERY_FAILED:
                repo.marcarEnviadoSinEntrega(row.id); break;              // decisión de negocio
            case FAILED:
                repo.marcarFallido(row.id, s.getError()); break;
            case UNKNOWN:
                repo.marcarRevision(row.id, s.getDetail()); break;        // NO reenviar sin decidir
            default: /* QUEUED, SENDING, ACCEPTED_BY_ANDROID: sigue en curso */ break;
        }
    } catch (GatewayApiException e) {
        if (e.getHttpStatus() == 404) repo.marcarRevision(row.id, "GATEWAY_PERDIO_EL_MENSAJE");
    } catch (IOException e) { /* gateway caído: se vuelve a consultar luego */ }
}
```

Para probar su lógica de negocio sin teléfono, defina una interfaz propia
(`SmsGateway`) que su código use, con la implementación real basada en este
cliente y una falsa para los tests.

## 4. Qué hacer según cada estado

| `state` | Significado práctico | Acción en su sistema |
|---|---|---|
| `QUEUED`, `SENDING`, `ACCEPTED_BY_ANDROID` | En curso | Seguir consultando |
| `SENT_BY_MODEM` | **Salió del teléfono** | Marcar enviado (éxito) |
| `DELIVERED_CONFIRMED` | La operadora confirmó entrega | Marcar enviado y guardar `deliveredAt` |
| `DELIVERY_FAILED` | Salió, la operadora dice que no llegó | Decisión de negocio (p. ej. avisar por otro canal) |
| `FAILED` | No salió | Marcar fallido. Si decide reintentar, hágalo con una **clave nueva** (`…-aviso-2`) y un tope de intentos |
| `UNKNOWN` | **No se sabe** si salió | Revisión manual o regla de negocio explícita. Reenviar automáticamente puede duplicar |

Si un mensaje lleva más de 5 minutos en `ACCEPTED_BY_ANDROID`, el propio gateway
lo pasa a `UNKNOWN`; si lleva más de 24 h en cola, lo pasa a `FAILED (EXPIRED)`.
Su sistema no necesita implementar esos plazos, pero debe esperar esos estados.

## 5. Errores y reintentos

Hay **dos clases de fallo** y se tratan distinto:

| Fallo | Cómo se ve en el cliente | Qué hacer |
|---|---|---|
| **De red** (sin respuesta: timeout, conexión rechazada, corte) | `IOException` | No sabe si el gateway recibió el pedido. **Repita con la misma clave**: es seguro, no duplica |
| **De la API** (el gateway respondió con error) | `GatewayApiException` | El pedido **no se encoló**. Mire `getCode()` |

Los únicos errores de API que valen un reintento posterior son `429`
(`MONTHLY_LIMIT`: solo cuando cambie el mes o suba el tope) y `503`
(`QUEUE_FULL`). El resto (`400`, `401`, `405`, `409`, `413`) son errores de
programación o de datos: reintentar no los arregla.

Un `500` con `state: FAILED` **no** es un error de API: el cliente lo devuelve
como `SmsStatus`. Un `500 SMS_NOT_SUPPORTED` sin `state` sí lo es.

## 6. Tiempos de espera

| Dónde | Valor sugerido | Razón |
|---|---|---|
| Conexión | 3 s | El teléfono está en la red local; si no conecta en 3 s, hay un problema |
| Lectura de `enqueue`/`getStatus` | 10 s | Responden al instante |
| Lectura con `wait=true` | 40 s | Debe ser mayor que el *Timeout* de la app (por defecto 25 s) |
| `awaitSettled` | 60 s | Con la pausa de 3 s entre envíos, 20 mensajes en cola tardan ~1 minuto |

Prefiera `enqueue` + consulta periódica antes que `wait=true`: el plazo queda en
su código y no depende de un ajuste del teléfono.

## 7. Seguridad y red

- **Active el token** en la app y guárdelo en una variable de entorno o un
  almacén de secretos, nunca en el código ni en el repositorio.
- El tráfico es **HTTP sin cifrar**: el token y los números viajan en claro. Úselo
  solo dentro de una red de confianza (LAN aislada, VLAN o VPN). No exponga el
  puerto a internet ni lo publique con un *port-forward*.
- Un solo equipo debería poder llegar al teléfono: restrinja por firewall la
  IP de su servidor.
- El teléfono recibe una IP por DHCP: **reserve una IP fija** para él en el
  router, o la integración dejará de funcionar cuando cambie.
- El gateway guarda el texto del mensaje 24 h tras terminar y luego lo borra;
  las respuestas muestran el teléfono enmascarado. Aun así, no envíe por SMS
  datos que no enviaría por un canal inseguro (el SMS en sí no es privado).

## 8. Operación

- Teléfono **dedicado**, conectado al cargador, en la misma red que su
  servidor y con la **app abierta y el servidor iniciado** (botón ▶). Con la
  opción *Mantener la pantalla encendida* (activa por defecto) la pantalla no se
  apaga mientras la app esté abierta.
- Si el teléfono pierde el WiFi, el servidor se detiene y hay que reiniciarlo a
  mano. La app no arranca sola tras reiniciar el teléfono.
- **Health-check:** `GET /v1/queue/` responde 200 si todo funciona. Conviene
  consultarlo cada minuto desde su sistema y alertar tras varias fallas.
  `isAlive()` del cliente hace exactamente eso.
- Vigile `monthUsed` / `monthlyLimit` y `pending` de ese mismo endpoint.
- Si se **desinstala la app o se borran sus datos**, se pierde la cola, los
  ids y las claves de idempotencia. Los `GET /v1/sms/{id}` darán 404 y una clave
  reutilizada ya no detectará el duplicado. Por eso su sistema debe guardar su
  propio resultado y no depender del historial del gateway.
- Los SMS salen con la SIM predeterminada de SMS del teléfono (la app todavía
  no permite elegir otra en equipos de doble SIM).

## 9. Probar la integración sin enviar SMS

1. **Salud:** `GET /v1/queue/` → 200.
2. **Rechazo controlado:** enviar con `phone: "abc"` → `400 INVALID_PHONE`; no se
   encola nada y no sale ningún SMS. Sirve para probar el manejo de errores.
3. **Autenticación:** con el token activo, una petición sin token → `401`.
4. **Estados:** consultar el id de un mensaje ya enviado → `200` con su estado.
5. **Ids inexistentes:** `GET /v1/sms/no-existe` → `404`.
6. **Lógica de reintento/idempotencia:** contra un servidor simulado (por
   ejemplo `com.sun.net.httpserver.HttpServer` de Java 8, o WireMock). Cubra:
   corte de red en el primer intento, misma clave en los dos intentos,
   `duplicate: true`, `500` con `state: FAILED`, `401` con `WWW-Authenticate`.
7. **Un único envío real** a un número propio, para ver `QUEUED → … → SENT_BY_MODEM`.

> No haga pruebas de carga contra el teléfono real: cada petición válida es un
> SMS real y consume el plan.

## 10. Trampas conocidas en Java 8

- **No use `setFixedLengthStreamingMode` ni `setChunkedStreamingMode`** de
  `HttpURLConnection`: en ese modo, un `401` (que el gateway envía con
  `WWW-Authenticate: Bearer`) lanza `HttpRetryException` y se pierde el cuerpo
  del error. El cliente incluido ya lo evita.
- Si su sistema ya usa Apache HttpClient u OkHttp, puede reescribir
  `OsmsGatewayClient.call()` con ellos; la lógica (clave de idempotencia,
  estados, reintentos) es la misma.
- Codifique siempre en **UTF-8** y mande el teléfono en el **cuerpo JSON**, no en
  la URL: un `+` sin codificar en una query llega como espacio.
- `Instant.parse` acepta las fechas del gateway (hasta microsegundos, en UTC).
  No use `SimpleDateFormat`.
- Un estado nuevo en una versión futura del gateway no debe romper su `switch`:
  `SmsState.parse` lo convierte en `UNKNOWN`.

## 11. Lista de verificación antes de producción

- [ ] Token activado en el gateway y guardado como secreto en su sistema.
- [ ] IP fija reservada para el teléfono; acceso restringido por firewall.
- [ ] Tabla *outbox* con `clave` única y generada una sola vez por mensaje.
- [ ] Reintentos de red con la **misma** clave; sin reintentos de errores 4xx.
- [ ] `SENT_BY_MODEM` tratado como éxito; `UNKNOWN` enviado a revisión.
- [ ] Health-check cada minuto con alerta.
- [ ] Teléfono dedicado, cargando, con la app abierta y el servidor iniciado.
- [ ] Prueba de extremo a extremo con un número propio (un solo SMS).
- [ ] Alerta cuando `monthUsed` se acerque a `monthlyLimit`.
- [ ] Decisión de negocio documentada para `FAILED`, `DELIVERY_FAILED` y `UNKNOWN`.

## 12. Limitaciones conocidas del gateway

- HTTP sin TLS; el token viaja en claro.
- Un solo teléfono y una sola SIM de envío; sin alta disponibilidad.
- Sin arranque automático tras reiniciar el teléfono ni tras perder el WiFi.
- Los informes de entrega dependen de la operadora; pueden no llegar nunca.
- Sin elección de SIM en equipos de doble SIM.
- Sin envío de SMS entrantes ni lectura de respuestas.
