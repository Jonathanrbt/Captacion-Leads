
# GUÍA DE DESARROLLO TÉCNICO: FLUJO 1.B (PROCESADOR, ENRIQUECIMIENTO Y CALIFICACIÓN DE LEADS)

Este documento es una guía estructurada para que la IA diseñe, configure y desarrolle el **Flujo 1.B** en n8n. Este flujo procesa de forma asíncrona los datos de leads de Google Maps, los enriquece, analiza sus puntos de dolor mediante inteligencia artificial y los registra en Supabase.

---

## 1. ESQUEMA DE BASE DE DATOS DE DESTINO (CONTEXTO)
Toda inserción o actualización debe ajustarse estrictamente a este esquema de Supabase:

```sql
create table leads (
    id uuid primary key default gen_random_uuid(),
    name text,
    email text unique, -- Identificador único para evitar duplicados
    phone text,
    company_name text,
    website text,
    rating numeric,              -- Extraído de Google Maps
    cms text,                    -- Detectado en el análisis de dolor
    status text default 'nuevo', -- 'nuevo', 'prospectado', 'cita_agendada'
    personalized_message text,
    tiene_chatbot boolean,
    reserva_manual boolean,
    errores_carga text,
    created_at timestamp with time zone default now()
);
```

---

## 2. CONTRATO DE ENTRADA (PAYLOAD DEL WEBHOOK DE APIFY)
El flujo se activa mediante un nodo Webhook (POST) que recibe de Apify el payload por defecto cuando el Actor `compass/crawler-google-places` cambia a estado `SUCCEEDED`:

```json
{
  "userId": "bIgMThfdcSRaBhyeF",
  "createdAt": "2026-05-26T00:00:00.000Z",
  "eventType": "ACTOR.RUN.SUCCEEDED",
  "eventData": { "actorId": "nwua9Gu5YrADL7ZDj", "actorRunId": "abcd1234" },
  "resource": {
    "id": "abcd1234",
    "actId": "nwua9Gu5YrADL7ZDj",
    "status": "SUCCEEDED",
    "defaultDatasetId": "XYZ123",
    "defaultKeyValueStoreId": "abc_kvs"
  }
}
```

> **Nota**: Se usa el payload por defecto de Apify (sin `payloadTemplate` custom) para evitar problemas de interpolación de variables. El `defaultDatasetId` se extrae de `body.resource.defaultDatasetId`.

---

## 3. PIPELINE DE NODOS (21 nodos totales)

#### NODO 1: Webhook Receptor (Trigger)
*   **Tipo**: `n8n-nodes-base.webhook` v2.1
*   **Método**: `POST`
*   **Ruta**: `/apify/leads-gmaps`
*   **Respuesta**: `onReceived` (200 OK inmediato a Apify).

#### NODO 2: Configuración de Paginación (Set Node)
Define variables iniciales para paginar el dataset de Apify.
*   **Valores**: `limit = 20`, `offset = 0`.

#### NODO 3: Obtener Lote de Dataset (HTTP Request - Apify API)
Descarga leads de Apify en lotes usando el `defaultDatasetId` del webhook.
*   **Método**: `GET`
*   **URL**: `https://api.apify.com/v2/datasets/{{ body.resource.defaultDatasetId }}/items`
*   **Query**: `limit`, `offset`, `clean=true`, `format=json`
*   **Credencial**: `apifyApi`

#### NODO 4: Normalizar Datos Lead (Set Node)
Mapea los campos de Apify a un formato estándar, incluyendo **datos ricos** para el análisis dual:
*   Campos básicos: `name`, `email`, `phone`, `company_name`, `website`, `rating`, `category`, `address`
*   Campos ricos (nuevos): `reviews_count`, `all_categories`, `opening_hours`, `has_social_media`, `has_reserve_url`, `additional_info`

#### NODO 5: Filtrar Lead con Email y Website (Filter Node)
Descarta leads sin email o sin website (ambos son requeridos para el pipeline).

#### NODO 6: Bucle Procesar Lead Individual (Split in Batches)
*   **Batch Size**: `1`
*   **onDone**: Incrementar offset → volver a Nodo 3
*   **onEachBatch**: Continuar al procesamiento individual

#### NODO 7: Hunter Email Verifier
*   **Tipo**: `n8n-nodes-base.hunter` (nodo nativo, no HTTP manual)
*   **Operación**: `emailVerifier`
*   **onError**: `continueRegularOutput` (no mata el pipeline si Hunter falla)

#### NODO 8: Email es Deliverable (IF Node)
*   **Condición**: `result !== 'undeliverable'` (permite `deliverable`, `accept_all`, `unknown` y vacío)
*   **onTrue**: Continuar análisis
*   **onFalse**: `nextBatch` (saltar lead)

#### NODO 9: GET HTML Website Lead (HTTP Request)
*   **Método**: `GET` al website del lead
*   **Timeout**: 20 segundos
*   **Headers**: User-Agent + Accept HTML
*   **neverError**: `true` (no falla si la web no responde)
*   **alwaysOutputData**: `true` (siempre pasa data, aunque sea error)
*   **onError**: `continueRegularOutput`

#### NODO 10: Limpiar HTML a Texto Estructurado (Code Node) — **NUEVO**
Transforma el HTML crudo en texto limpio + señales técnicas pre-computadas:
*   **Elimina**: `<script>`, `<style>`, `<noscript>`, `<svg>`, `<iframe>` y su contenido
*   **Extrae señales técnicas**:
    - `cms_hint`: detecta WordPress, Shopify, Wix, Webflow, Squarespace por paths/scripts
    - `chatbot_detected`: detecta Tidio, Tawk.to, Intercom, Drift, Crisp, etc.
    - `booking_detected`: detecta Calendly, Acuity, Booksy, SetMore, etc.
    - `has_viewport`, `title`, `meta_description`, `uses_https`
*   **Output**: `cleaned_text` (max 3000 chars), `signals` (objeto), `extraction_status` (`ok`/`minimal`/`no_html`)
*   **Fallback**: si el HTML es vacío/error/timeout → `extraction_status: 'no_html'`, texto vacío

#### NODO 11: OpenAI Análisis de Dolor (OpenAI Responses API)
*   **Modelo**: `gpt-4o-mini`, temperatura `0.1`
*   **Formato**: JSON Schema (`strict: false`)
*   **Prompt dual**: recibe **dos contextos**:
    1. Datos Google Maps (del Nodo 4): categorías, rating, reviews, horarios, info adicional, redes sociales
    2. Señales técnicas + texto limpio (del Nodo 10)
*   **Reglas de prioridad**:
    - CMS: prioriza señal técnica `cms_hint` > inferencia del texto > "Desconocido"
    - Chatbot: prioriza `chatbot_detected` del Code Node
    - Reserva manual: si no hay `booking_detected` NI `has_reserve_url` → `true`
    - Errores: solo reporta problemas confirmados; si no hay web → "Web no accesible"
*   **retryOnFail**: `false` (1 solo intento — no agota rate limit)
*   **onError**: `continueRegularOutput`

#### NODO 12: Supabase UPSERT Lead (HTTP Request → PostgREST)
*   **Método**: `POST` a `/rest/v1/leads`
*   **on_conflict**: `email`
*   **Prefer**: `resolution=merge-duplicates,return=representation`
*   **Campos booleanos**: usan `?? false` para evitar `undefined` si OpenAI falló

#### NODO 13: Wait 30s Entre Llamadas OpenAI
*   Pausa de **30 segundos** antes de la segunda llamada a OpenAI
*   Previene rate limiting (especialmente en cuentas tier-1/free)

#### NODO 14: OpenAI Genera Mensaje Outreach (OpenAI Responses API)
*   **Modelo**: `gpt-4o-mini`, temperatura `0.7`
*   **Prompt**: consume datos del lead + resultados del análisis de dolor
*   **retryOnFail**: `true` (3 intentos, 5s entre reintentos)
*   **onError**: `continueRegularOutput` (no mata el pipeline)

#### NODO 15: Supabase UPDATE Lead status prospectado
*   **Operación**: `update` donde `email = lead.email`
*   **Campos**: `personalized_message` (usa `$json.output || $json.content || null`), `status: 'prospectado'`

#### NODO 16: Hay Mensaje Generado (IF Node) — **NUEVO**
*   **Condición**: verifica que OpenAI produjo texto (`output` o `content` no vacío)
*   **onTrue**: continuar a Wait Jitter → Gmail
*   **onFalse**: `nextBatch` (saltar envío, lead queda como `prospectado` sin mensaje)

#### NODO 17: Wait Jitter 2 a 8 min
*   Retraso aleatorio: `Math.floor(Math.random() * 7) + 2` minutos
*   Simula comportamiento humano y protege la cuenta de Gmail

#### NODO 18: Gmail Send Email Outreach
*   **Asunto**: `"Pregunta rapida sobre {{ company_name }}"`
*   **Cuerpo**: mensaje generado por OpenAI
*   **onError**: `continueRegularOutput`

#### NODO 19: Incrementar Offset Paginación (Code Node)
*   Calcula `newOffset = currentOffset + limit`
*   Conecta de vuelta al Nodo 3 para el siguiente lote

#### NODO 20: Error Trigger del Workflow
*   Captura errores no manejados

#### NODO 21: Log Workflow Error a system_logs (Supabase)
*   Registra error en `public.system_logs` con workflow_name, error_message, payload JSON

---

## 4. REGISTRO DE IMPLEMENTACIÓN REAL

### 4.1 Workflow desplegado
- **Workflow ID**: `mIx5PCcg2Ebc8MqT`
- **Nombre**: `[CaptacionLeads] Flujo 1.B - Procesador y Calificador de Leads`
- **URL del Editor**: `https://tilinsito.app.n8n.cloud/workflow/mIx5PCcg2Ebc8MqT`
- **Webhook Producción**: `POST https://tilinsito.app.n8n.cloud/webhook/apify/leads-gmaps`
- **Total nodos**: 21

### 4.2 Decisiones de diseño vs plan original

| Aspecto | Plan original | Implementación final | Razón |
|---|---|---|---|
| Actor Apify | `poidata/contact-details-scraper` | `compass/crawler-google-places` | Actor más completo: extrae emails, redes sociales, categorías, horarios, additionalInfo directamente |
| Webhook payload | Custom `payloadTemplate` | Payload por defecto de Apify | El template engine de Apify no interpolaba dot notation. Se lee `body.resource.defaultDatasetId` |
| Verificación Hunter | HTTP Request manual | Nodo nativo `n8n-nodes-base.hunter` | Más seguro (key en credencial), retry built-in |
| Análisis HTML | HTML crudo directo a OpenAI (12K chars) | **Code Node limpiador** → texto limpio (3K chars) + señales técnicas pre-computadas | HTML crudo contenía 80% ruido (CSS, scripts, SVGs). Code Node detecta CMS/chatbot/booking por regex antes de enviar a OpenAI |
| Fuentes de datos para OpenAI | Solo HTML del website | **Análisis dual**: datos Google Maps (categorías, rating, reviews, horarios, additionalInfo) + HTML limpio + señales técnicas | Si la web no responde, OpenAI aún puede analizar con datos de Google Maps |
| Verificación email | `result === 'deliverable'` | `result !== 'undeliverable'` | Emails "catch-all", "unknown" o sin resultado de Hunter pasan el filtro |
| JSON Schema OpenAI | `strict: true` | `strict: false` | `strict: true` causaba "Failed to parse schema" cuando el input era pobre |
| Retries OpenAI Analisis | 3 intentos | **Sin reintentos** (`retryOnFail: false`) | Reintentos desperdiciaban rate limit cuando el HTML era vacío |
| Rate limit entre OpenAIs | Sin pausa | **Wait 30s** entre Analisis y Genera Mensaje | Previene "Too many requests" en cuentas tier-1 |
| Envío Gmail | Siempre intenta enviar | **IF "Hay Mensaje Generado"** antes de Gmail | Previene error `undefined.trim()` cuando OpenAI no generó mensaje |
| Upsert Supabase | Nodo Supabase | HTTP Request a PostgREST | El nodo nativo no soporta UPSERT; REST API con `Prefer: merge-duplicates` sí |
| Envío | Flujo separado (1.C) | Incluido en este flujo (Wait Jitter + Gmail) | MVP monolítico, decisión del usuario |

### 4.3 JSON Schema final (OpenAI Pain Analysis)

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["tiene_chatbot", "reserva_manual", "errores_carga", "cms_detectado"],
  "properties": {
    "tiene_chatbot": { "type": "boolean" },
    "reserva_manual": { "type": "boolean" },
    "errores_carga": { "type": "string" },
    "cms_detectado": {
      "type": "string",
      "enum": ["WordPress","Shopify","Wix","Squarespace","Webflow","Joomla","Drupal","Ghost","HubSpot CMS","Custom","Desconocido"]
    }
  }
}
```

> Usado con `strict: false` y `type: 'json_schema'` en `parameters.options.textFormat.textOptions`.

### 4.4 Política de reintentos y resiliencia

| Nodo | retryOnFail | maxTries | waitBetweenTries | onError |
|---|---|---|---|---|
| GET Apify Dataset Lote | true | 3 | 2000 ms | (default) |
| Hunter Email Verifier | true | 3 | 2000 ms | continueRegularOutput |
| GET HTML Website Lead | true | 2 | 2000 ms | continueRegularOutput + alwaysOutputData |
| Limpiar HTML a Texto | — | — | — | Code Node (no falla, siempre retorna) |
| OpenAI Analisis Dolor | **false** | **1** | — | continueRegularOutput |
| Supabase UPSERT | true | 3 | 2000 ms | (default) |
| OpenAI Genera Mensaje | true | 3 | **5000 ms** | continueRegularOutput |
| Supabase UPDATE | true | 3 | 2000 ms | (default) |
| Gmail Send | true | 3 | 3000 ms | continueRegularOutput |

### 4.5 Campos normalizados de Apify (Normalizar Datos Lead)

| Campo | Fuente Apify | Uso |
|---|---|---|
| `name`, `company_name` | `title` | Identificación |
| `email` | `emails[0]` | Contacto + upsert key |
| `phone` | `phone` | Contacto |
| `website` | `website` | Fetch HTML |
| `rating` | `totalScore` | Scoring |
| `category` | `categoryName` | Contexto para análisis |
| `address` | `address` | Referencia |
| `reviews_count` | `reviewsCount` | Contexto para análisis |
| `all_categories` | `categories.join(", ")` | Contexto enriquecido para OpenAI |
| `opening_hours` | `openingHours.map(...)` | Contexto para OpenAI |
| `has_social_media` | `instagrams/facebooks/linkedIns.length > 0` | Señal de madurez digital |
| `has_reserve_url` | `!!reserveTableUrl` | Señal de booking online |
| `additional_info` | `JSON.stringify(additionalInfo)` | Info extra de Google (citas online, etc.) |

### 4.6 Señales técnicas del Code Node (Limpiar HTML)

| Señal | Método de detección | Ejemplo |
|---|---|---|
| `cms_hint` | Regex en HTML: `/wp-content/`, `/cdn.shopify.com/`, `/wix.com/` | `"Shopify"` |
| `chatbot_detected` | Regex: tidio, tawk.to, intercom, drift, crisp, etc. | `true/false` |
| `booking_detected` | Regex: calendly, acuity, booksy, setmore, cal.com | `true/false` |
| `has_viewport` | `<meta name="viewport">` presente | `true/false` |
| `uses_https` | Presencia de `https://` en el HTML | `true/false` |
| `title` | Extracción de `<title>` | `"BOTEROMEDIA"` |
| `meta_description` | `<meta name="description" content="...">` | Texto truncado a 200 chars |
| `extraction_status` | Basado en longitud del texto limpio | `ok` / `minimal` / `no_html` |

### 4.7 Archivo fuente

El código TypeScript del workflow está versionado en `workflow/flujo_1b_procesador_leads.ts`. Para re-deployar usar el MCP de n8n con `update_workflow` apuntando al `workflowId: mIx5PCcg2Ebc8MqT`.
