# OSmsGateway — Referencia de la API HTTP

Versión de la app: 0.0.2 (rama con cola persistente). Esta referencia describe
**lo que el código implementa hoy**.

El gateway es un servidor HTTP **sin TLS** que corre dentro de la app Android.
Está pensado para una red local de confianza (ver *Seguridad* en
[INTEGRACION_JAVA8.md](INTEGRACION_JAVA8.md)).

- URL base: `http://<ip-del-telefono>:<puerto>` (puerto por defecto **8080**,
  configurable en la app).
- Formato: JSON UTF-8. Las fechas son ISO-8601 en UTC, por ejemplo
  `2026-10-16T16:29:16.754170Z`.

## Resumen de endpoints

| Método | Ruta | Para qué |
|---|---|---|
| `POST` | `/v1/sms/` | Encolar un SMS (el recomendado) |
| `GET` | `/v1/sms/send/` | Encolar un SMS con parámetros en la URL (ruta heredada, compatible con REST SMS Gateway) |
| `GET` | `/v1/sms/{id}` | Consultar el estado de un SMS |
| `GET` | `/v1/queue/` | Resumen de la cola; sirve de *health-check* |
| `GET` | `/` | Página web para enviar a mano |
| `OPTIONS` | cualquiera | Preflight CORS (responde 204) |

Las rutas aceptan con o sin barra final (`/v1/sms` equivale a `/v1/sms/`).

## Autenticación

Opcional: se activa en la app (*Configuración → Exigir token de acceso*). Si está
activa, **todo `/v1/*`** exige el token en una de estas cabeceras:

```
Authorization: Bearer <token>
X-API-Key: <token>
```

El token **no se acepta por query string** (quedaría en logs). Sin token o con
uno incorrecto: `401 UNAUTHORIZED` y la cabecera `WWW-Authenticate: Bearer`.
`OPTIONS` y `GET /` no exigen token.

> Por defecto el token está **desactivado**: cualquier equipo de la red puede
> enviar SMS. Actívelo antes de integrar.

## POST /v1/sms/ — encolar un SMS

### Petición

Cabeceras:

| Cabecera | Obligatoria | Notas |
|---|---|---|
| `Content-Type` | sí | `application/json` (también `application/x-www-form-urlencoded`) |
| `Idempotency-Key` | **recomendada** | 1–128 caracteres ASCII imprimibles, **sin espacios** |
| `Authorization` | si hay token | `Bearer <token>` |

Cuerpo JSON:

| Campo | Tipo | Obligatorio | Notas |
|---|---|---|---|
| `phone` | string | sí | Ver *Formato de teléfono* |
| `message` | string | sí | No vacío (no solo espacios), máximo **1000 caracteres** |
| `wait` | boolean | no | `true`: el gateway espera a que el SMS salga antes de responder (ver *Modo con espera*). Por defecto `false` |
| `idempotency_key` | string | no | Alternativa a la cabecera `Idempotency-Key` |

El cuerpo no puede superar **16 KB**. Los parámetros `phone`, `message`, `wait`
también se aceptan en la query string (el cuerpo tiene prioridad); con la query
hay que codificar el `+` como `%2B`, por eso se recomienda JSON.

Ejemplo:

```bash
curl -X POST http://192.168.1.50:8080/v1/sms/ \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: pedido-1234-aviso" \
  -d '{"phone":"+595982123456","message":"Su pedido salió a reparto"}'
```

### Respuesta

```json
{
  "status": 202,
  "id": "k3x9a1b2c4-0f7e",
  "state": "QUEUED",
  "phone": "+5959****3456",
  "parts": null,
  "attempts": 0,
  "duplicate": false,
  "createdAt": "2026-10-16T16:29:16.754170Z",
  "acceptedAt": null,
  "sentAt": null,
  "deliveredAt": null,
  "error": null,
  "detail": null
}
```

| Campo | Significado |
|---|---|
| `status` | Igual al código HTTP |
| `id` | Identificador del mensaje en el gateway (`[A-Za-z0-9_-]`, hasta 64). Sirve para consultar el estado |
| `state` | Estado actual. **Decida por este campo**, no por el código HTTP |
| `phone` | Teléfono **enmascarado**; el texto del mensaje nunca se devuelve |
| `parts` | Partes del SMS; `null` hasta que Android acepta la solicitud |
| `attempts` | Veces que se pidió el envío a Android |
| `duplicate` | `true` si no se creó un mensaje nuevo: el gateway devolvió uno existente (ver *Idempotencia*). Solo aparece en la respuesta del POST |
| `createdAt`, `acceptedAt`, `sentAt`, `deliveredAt` | Marcas de tiempo; `null` mientras no ocurra el hecho. **`deliveredAt` solo existe si la operadora confirmó la entrega** |
| `error`, `detail` | Código y detalle cuando falló o quedó en estado incierto |

### Códigos HTTP del POST

| HTTP | Cuándo | Qué hacer |
|---|---|---|
| `202` | Encolado, o todavía sin resolver (`QUEUED`, `SENDING`, `ACCEPTED_BY_ANDROID`, `UNKNOWN`) | Consultar `GET /v1/sms/{id}` |
| `200` | Ya salió del teléfono (`SENT_BY_MODEM`, `DELIVERED_CONFIRMED`, `DELIVERY_FAILED`). Ocurre con `wait=true` o al repetir una petición ya resuelta | Éxito de envío |
| `500` | El mensaje falló (`state: FAILED`) | Ver `error` |
| `4xx/5xx` sin `state` | La petición **no se encoló** (ver *Errores*) | Corregir o reintentar según el código |

## Estados de un mensaje

```
QUEUED → SENDING → ACCEPTED_BY_ANDROID → SENT_BY_MODEM → DELIVERED_CONFIRMED
                          │                    └──────→ DELIVERY_FAILED
                          └────→ FAILED          (también desde QUEUED / SENDING)
                  UNKNOWN  (cuando se pierde la certeza)
```

| Estado | Qué es un hecho y qué no |
|---|---|
| `QUEUED` | Guardado en disco en la cola del gateway. Todavía no se pidió el envío |
| `SENDING` | Se está entregando a Android |
| `ACCEPTED_BY_ANDROID` | Android aceptó la solicitud. **No** implica que haya salido |
| `SENT_BY_MODEM` | El módem informó que el SMS **salió**. **No** implica entrega |
| `DELIVERED_CONFIRMED` | La operadora confirmó la entrega con un informe de entrega |
| `FAILED` | No salió: Android lo rechazó, falló el envío o venció en la cola (`EXPIRED`) |
| `DELIVERY_FAILED` | Salió, pero la operadora informó que no se entregó |
| `UNKNOWN` | No se puede saber si salió (la app se cerró a mitad, o Android aceptó pero nunca confirmó la salida). **No se reenvía solo** |

> **Importante.** Muchas operadoras no envían informes de entrega o los
> demoran. En las pruebas en Paraguay con la SIM Personal, un SMS quedó en
> `SENT_BY_MODEM` sin informe de entrega aunque **sí llegó**. Trate
> `SENT_BY_MODEM` como el éxito práctico y `DELIVERED_CONFIRMED` como un extra
> opcional. El gateway **nunca** marca `DELIVERED_CONFIRMED` sin un informe
> verificable de la operadora.

Los estados nunca retroceden. Un estado final no cambia, salvo `UNKNOWN`, que
puede resolverse a `SENT_BY_MODEM`/`DELIVERED_CONFIRMED`/`FAILED` si llega un
evento tardío.

## GET /v1/sms/{id} — consultar el estado

Devuelve el mismo objeto de mensaje (sin el campo `duplicate`) y **siempre
HTTP 200** si el id existe, cualquiera sea el estado. Si no existe:
`404 MESSAGE_NOT_FOUND`.

```bash
curl -H "Authorization: Bearer $TOKEN" http://192.168.1.50:8080/v1/sms/k3x9a1b2c4-0f7e
```

Un mensaje deja de existir en el gateway: **90 días** después de terminar (o
después de salir, si quedó en `SENT_BY_MODEM` sin informe de entrega), o si se
borran los datos / se desinstala la app. Para entonces, su sistema ya debe
haber guardado el resultado.

## GET /v1/queue/ — resumen y health-check

```json
{ "status": 200, "pending": 0, "states": { "SENT_BY_MODEM": 1 },
  "monthUsed": 1, "monthlyLimit": 2000 }
```

`pending` cuenta los mensajes en `QUEUED` o `SENDING`. Si responde 200, el
servidor está vivo.

## Idempotencia y duplicados

- Con `Idempotency-Key`: la primera petición crea el mensaje; **cualquier
  repetición con la misma clave devuelve ese mismo mensaje** con
  `duplicate: true` y **no envía otro SMS**. La clave se recuerda mientras el
  mensaje exista (hasta 90 días tras terminar).
- Misma clave con **otro** teléfono o texto: `409 IDEMPOTENCY_CONFLICT`.
- Sin clave: la misma pareja teléfono + texto repetida dentro de **2 minutos**
  se toma por duplicado. Un mensaje `FAILED` no bloquea un reenvío igual.
- Dos peticiones simultáneas con la misma clave crean un solo mensaje.

## Modo con espera (`wait=true`)

Con `"wait": true`, el gateway no responde hasta que el SMS salga, falle, o venza
su espera interna (ajuste *Timeout* de la app: el valor × 50 ms; por defecto
500 → **25 s**). Si vence, responde `202` con el último estado conocido (no es
un error, y **no** conviene reintentar a ciegas). Como los envíos salen a un
ritmo de uno cada 3 s por defecto, con cola larga la espera puede agotarse. El
cliente HTTP debe tener un *read timeout* mayor que esa espera. Es más
robusto encolar sin esperar y consultar `GET /v1/sms/{id}`.

## Formato de teléfono

Se normaliza a E.164. Para Paraguay (`+595`) solo se aceptan **móviles**
(`+595 9XX XXXXXX`). Ejemplos que se aceptan y se convierten en
`+595981123456`:

`+595981123456`, `+595 981 123 456`, `00595981123456`, `595981123456`,
`0981123456`, `0981 123 456`, `981123456`.

Se rechazan (`400 INVALID_PHONE`): letras, longitud incorrecta, fijos
paraguayos (`+59521...`). Otros países se aceptan en formato internacional
(`+5491155556666`). **Envíe siempre E.164 desde su sistema.**

## Errores

Si la petición **no se encoló**, el cuerpo es:

```json
{ "status": 400, "error": "INVALID_PHONE", "message": "Teléfono inválido; ..." }
```

(no tiene campo `state`). Códigos:

| HTTP | `error` | Causa | ¿Reintentar? |
|---|---|---|---|
| 400 | `INVALID_PHONE` | Teléfono inválido o ausente | No: corregir |
| 400 | `EMPTY_MESSAGE` | Mensaje vacío | No |
| 400 | `MESSAGE_TOO_LONG` | Más de 1000 caracteres | No |
| 400 | `INVALID_BODY` | JSON inválido o con tipos incorrectos | No |
| 400 | `INVALID_IDEMPOTENCY_KEY` | Clave con espacios o más de 128 caracteres | No |
| 401 | `UNAUTHORIZED` | Token ausente o incorrecto | No: revisar token |
| 404 | `NOT_FOUND` | Ruta `/v1/...` inexistente | No |
| 404 | `MESSAGE_NOT_FOUND` | El id no existe | No |
| 405 | `METHOD_NOT_ALLOWED` | Método incorrecto (cabecera `Allow` indica el correcto) | No |
| 409 | `IDEMPOTENCY_CONFLICT` | Misma clave con otro teléfono/texto | No: usar otra clave |
| 413 | `BODY_TOO_LARGE` | Cuerpo de más de 16 KB | No |
| 429 | `MONTHLY_LIMIT` | Se alcanzó el tope mensual de SMS | No hasta el mes siguiente o subir el tope |
| 500 | `SMS_NOT_SUPPORTED` | El dispositivo no puede enviar SMS | No |
| 503 | `QUEUE_FULL` | Hay 200 mensajes esperando | Sí, más tarde |

Códigos que aparecen en el campo `error` **de un mensaje** (estado `FAILED` o
`UNKNOWN`): `INVALID_ARGUMENT`, `SEND_FAILED`, `NO_PERMISSION`,
`SMS_NOT_SUPPORTED`, `EXPIRED` (venció 24 h en cola), `INTERRUPTED` (la app se
cerró con el mensaje en vuelo), `NO_SENT_CONFIRMATION`, `DUPLICATE_ID`,
`DELIVERY_FAILED`.

## Ruta heredada: GET /v1/sms/send/

`GET /v1/sms/send/?phone=%2B595981123456&message=Hola` hace lo mismo que el POST
(acepta también `wait` y la cabecera `Idempotency-Key`). Se conserva por
compatibilidad. **No la use en sistemas nuevos**: un GET que envía SMS se puede
disparar por error (precarga, rastreadores, `<img>`) y los parámetros quedan en
los logs.

## Límites y ritmo

| Parámetro | Valor por defecto | Dónde se cambia |
|---|---|---|
| Pausa entre envíos | 3 s (mínimo 1 s) | App → *Pausa entre SMS* |
| Tope mensual | 2000 (0 = sin límite) | App → *Límite mensual de SMS* |
| Mensajes esperando | 200 | Fijo |
| Longitud del mensaje | 1000 caracteres | Fijo |
| Vencimiento en cola | 24 h | Fijo |
| Aceptado sin confirmación → `UNKNOWN` | 5 min | Fijo |
| Reintentos del gateway | 3, solo si Android rechazó la solicitud al instante | Fijo |
| Borrado del texto del mensaje | 24 h tras terminar | Fijo |
| Retención del registro | 90 días | Fijo |

Un SMS cuenta como varios si es largo: 160 caracteres por parte en GSM-7, pero
**70** (67 en mensajes concatenados) si contiene caracteres como `á`, `í`, `ó`,
`ú`, que fuerzan UCS-2. `parts` informa cuántas partes se enviaron.

## CORS

Todas las respuestas incluyen `Access-Control-Allow-Origin: *`. Si el token está
activo, un navegador necesita conocerlo para llamar a la API, así que el
riesgo es bajo, pero no use el gateway directamente desde páginas públicas.
