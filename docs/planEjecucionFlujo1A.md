# GUÍA DE DESARROLLO TÉCNICO: FLUJO 1.A (LANZADOR DE SCRAPING DE MAPS ASÍNCRONO)

Este documento contiene las instrucciones precisas para que la IA diseñe, configure y guíe en la construcción del **Flujo 1.A** en n8n. Este flujo tiene como único objetivo iniciar el scraping en Apify de manera asíncrona.

---

> ### ⚠️ REGISTRO DE CAMBIOS — Implementación real vs. plan original
>
> **Fecha de implementación**: 2026-05-25
> **Workflow ID en n8n**: `cwq1c8VMAsebxCyQ`
> **URL en n8n**: `https://tilinsito.app.n8n.cloud/workflow/cwq1c8VMAsebxCyQ`
>
> Durante la construcción real del flujo se detectaron y corrigieron las siguientes discrepancias respecto al plan original:
>
> | Aspecto | Plan Original (incorrecto) | Implementación Real |
> |---|---|---|
> | **Actor de Apify** | `poidata/google-maps-scraper` | `compass/crawler-google-places` |
> | **Campo: términos de búsqueda** | `searchQueries` (array) | `searchStringsArray` (array) |
> | **Campo: ubicación** | `locations` (array) | `locationQuery` (string — una sola ciudad por ejecución) |
> | **Campo: máximo de resultados** | `maxCrawledPlaces` | `maxCrawledPlacesPerSearch` (por término) |
> | **Campo: concurrencia** | `maxConcurrency` (inexistente en el actor real) | Eliminado — no existe en el schema del actor |
> | **Enrichment de contactos** | Requería segundo actor "Contact Details Scraper" | `scrapeContacts: true` en el mismo actor (nativo) |
> | **Webhook de Apify** | Configurar en el segundo actor (Contact Details) | Configurar en el mismo actor `compass/crawler-google-places` |
> | **Autenticación HTTP** | Token en query string `?token={{$env.APIFY_TOKEN}}` | Credencial nativa `apifyApi` de n8n (más seguro, sin hardcode) |
> | **Arquitectura de nodos** | 3 nodos simples (Trigger → Set → HTTP) | 7 nodos: los 3 originales + Error Trigger + 2 nodos Supabase para resiliencia |
>
> **Razón del cambio de actor**: Al verificar el input schema real de `poidata/google-maps-scraper` vía Apify MCP, se confirmó que los campos del plan original no coinciden con el schema real del actor. `compass/crawler-google-places` es el actor que SÍ coincide con la arquitectura planteada, además tiene 425K usuarios, 4.75★ de rating, success rate del 93.8% y enrichment de contactos integrado (emails, redes sociales), eliminando la necesidad de encadenar un segundo actor.

---

## 1. OBJETIVO DEL FLUJO
Iniciar una tarea del actor `compass/crawler-google-places` en la nube de Apify sin esperar a que finalice la extracción de datos, liberando de forma inmediata los recursos de n8n para evitar timeouts.

---

## 2. ESPECIFICACIONES TÉCNICAS

*   **Plataforma de Scraping**: Apify
*   **Actor Implementado**: `compass/crawler-google-places` *(antes: `poidata/google-maps-scraper` — ver cambios arriba)*
*   **URL del actor en Apify Store**: https://apify.com/compass/crawler-google-places
*   **Tipo de Ejecución**: Asíncrona (POST a `/runs` — devuelve `status: RUNNING` inmediatamente)
*   **Origen**: Trigger Manual + Cron semanal (lunes 08:00 AM)
*   **Destino**: `https://api.apify.com/v2/acts/compass~crawler-google-places/runs`
*   **Autenticación**: Credencial nativa `apifyApi` de n8n (id: `RGzWjtqclgqG5lvR`) — token nunca viaja en la URL

---

## 3. ARQUITECTURA DE NODOS EN n8n (IMPLEMENTADA)

El workflow final tiene 7 nodos (3 funcionales + 2 de resiliencia + 2 sticky notes de documentación):

### NODO 1A: Trigger Manual
*   **Tipo de Nodo**: `n8n-nodes-base.manualTrigger` v1
*   **Nombre en canvas**: `Trigger Manual`
*   **Uso**: Ejecuciones bajo demanda (desarrollo, QA, lanzamientos manuales).

### NODO 1B: Cron Semanal
*   **Tipo de Nodo**: `n8n-nodes-base.scheduleTrigger` v1.3
*   **Nombre en canvas**: `Cron Semanal Lunes 8AM`
*   **Configuración**: `weeks / weeksInterval: 1 / triggerAtDay: [1] / triggerAtHour: 8 / triggerAtMinute: 0`
*   Ambos triggers (1A y 1B) convergen en el Nodo 2 (patrón fan-in — cada ejecución es aislada).

### NODO 2: Configuración de Parámetros de Búsqueda (Set Node)
*   **Tipo de Nodo**: `n8n-nodes-base.set` v3.4 (mode: `manual`)
*   **Nombre en canvas**: `Set Parametros Busqueda`
*   **Campos a definir (JSON de salida — schema REAL del actor)**:
    ```json
    {
      "searchStringsArray": ["marketing agency", "software company"],
      "locationQuery": "Bogota, Colombia",
      "maxCrawledPlacesPerSearch": 200,
      "language": "es",
      "scrapeContacts": true,
      "skipClosedPlaces": true,
      "website": "withWebsite"
    }
    ```

*   **Guía de personalización de los parámetros clave**:

    | Campo | Tipo | Descripción | Ejemplo |
    |---|---|---|---|
    | `searchStringsArray` | array de strings | Términos a buscar en Google Maps. Equivale a escribir en la barra de búsqueda. Máx. recomendado: 5 términos por ejecución. | `["dentista", "clinica dental", "odontologia"]` |
    | `locationQuery` | string | Ciudad o zona geográfica. **Solo una por ejecución.** Formato: `"Ciudad, País"`. | `"Medellin, Colombia"` |
    | `maxCrawledPlacesPerSearch` | integer | Cuántos negocios extraer **por cada término**. Máx. real del actor: 500. Total = este valor × cantidad de términos. | `100` |
    | `language` | string (enum) | Idioma de los resultados. Usar `"es"` para español, `"en"` para inglés. | `"es"` |
    | `scrapeContacts` | boolean | Activa el enrichment de emails y redes sociales desde el sitio web de cada negocio. **Siempre `true` para outreach.** | `true` |
    | `skipClosedPlaces` | boolean | Omite negocios cerrados permanente o temporalmente. | `true` |
    | `website` | string (enum) | Filtro de webs: `"withWebsite"` (solo con web), `"withoutWebsite"`, `"allPlaces"`. **Usar `"withWebsite"` para outreach digital.** | `"withWebsite"` |

### NODO 3: Ejecutor del Actor (HTTP Request - Modo Asíncrono)
*   **Tipo de Nodo**: `n8n-nodes-base.httpRequest` v4.4
*   **Nombre en canvas**: `Lanzar Actor Apify (Async)`
*   **Método**: `POST`
*   **URL**: `https://api.apify.com/v2/acts/compass~crawler-google-places/runs`
    *(No lleva `?token=...` — la autenticación va por la credencial nativa)*
*   **Autenticación**:
    *   `authentication: "predefinedCredentialType"`
    *   `nodeCredentialType: "apifyApi"`
    *   Credencial: `Apify account` (seleccionar manualmente en la UI de n8n)
*   **Body**: `JSON` — serialización completa del output del Nodo 2 (`JSON.stringify($json)`)
*   **Comportamiento asíncrono**: El endpoint `/runs` (sin `-sync`) devuelve inmediatamente un JSON con `status: RUNNING` y el `actorRunId`. n8n termina la ejecución en ese momento.
*   **Respuesta esperada de Apify**:
    ```json
    {
      "data": {
        "id": "<actorRunId>",
        "actId": "...",
        "status": "RUNNING",
        "startedAt": "2026-05-25T18:00:00.000Z",
        "defaultDatasetId": "<datasetId>",
        "defaultKeyValueStoreId": "..."
      }
    }
    ```
*   **Resiliencia**: configurado con `onError: "continueErrorOutput"` — si Apify falla, el error se enruta al Nodo 4 (log en Supabase) en vez de detener el workflow sin registro.

### NODO 4: Log de Error de Apify (Supabase)
*   **Tipo de Nodo**: `n8n-nodes-base.supabase` v1 (resource: `row`, operation: `create`)
*   **Nombre en canvas**: `Log Apify Error a system_logs`
*   **Activación**: Solo cuando el Nodo 3 falla (error output de `onError: continueErrorOutput`)
*   **Tabla destino**: `public.system_logs`
*   **Payload registrado**: `workflow_name`, `error_message` y un JSONB `payload` con `source`, `node`, `actor`, `error`, `request_body`, `execution_id`, `mode`.

### NODO 5: Error Trigger (Resiliencia L2)
*   **Tipo de Nodo**: `n8n-nodes-base.errorTrigger` v1
*   **Nombre en canvas**: `Error Trigger del Workflow`
*   **Activación**: Cualquier error no capturado por `onError` (errores de expresión en Set, fallos del cron, etc.)

### NODO 6: Log de Error General (Supabase)
*   **Tipo de Nodo**: `n8n-nodes-base.supabase` v1 (resource: `row`, operation: `create`)
*   **Nombre en canvas**: `Log Workflow Error a system_logs`
*   **Tabla destino**: `public.system_logs`
*   **Payload registrado**: `workflow_name`, `error_message` y un JSONB `payload` con `source`, `execution_id`, `last_node`, `error_name`, `error_stack`, `mode`.

---

## 4. CONFIGURACIÓN DEL WEBHOOK DE CONEXIÓN (APIFY → FLUJO 1.B)

> **Cambio arquitectónico vs. plan original**: Ya no existe encadenamiento entre dos actores en Apify. El actor `compass/crawler-google-places` extrae tanto los datos de Google Maps **como** los emails y redes sociales de los sitios web (`scrapeContacts: true`). El webhook se configura directamente en este actor, no en un segundo actor.

1.  **En n8n**: Crear el workflow **Flujo 1.B**, colocar un nodo **Webhook (POST)** con ruta `/apify/leads-gmaps` y activar `Respond Immediately` (devuelve HTTP 200 a Apify de inmediato para evitar reintentos). Copiar la URL pública generada.

2.  **En Apify Console** (configuración única, no requiere n8n):
    *   Ir a https://console.apify.com → buscar el actor `compass/crawler-google-places` → sección **Integrations** → **Webhooks** → **+ Add webhook**
    *   Configurar:
        *   **Event types**: `ACTOR.RUN.SUCCEEDED` únicamente
        *   **Request URL**: URL pública del nodo Webhook del Flujo 1.B
        *   **Description**: `Flujo 1.B - Receptor Outreach Agent`
        *   **Payload Template**:
            ```json
            {
              "eventType": "{{eventType}}",
              "actorId": "{{actorId}}",
              "actorRunId": "{{actorRunId}}",
              "defaultDatasetId": "{{resource.defaultDatasetId}}",
              "status": "{{resource.status}}"
            }
            ```

---

## 5. RESILIENCIA — ESQUEMA DE DOBLE CAPA

```
[Trigger Manual o Cron]
        |
        v
[Set Parametros Busqueda]
        |
        v
[Lanzar Actor Apify (Async)] ──(éxito)──► fin (status: RUNNING recibido)
        |
        └──(onError)──► [Log Apify Error a system_logs]   ← L1: fallos HTTP Apify

[Error Trigger del Workflow] ──────────► [Log Workflow Error a system_logs]  ← L2: cualquier otro error
```

Ambas rutas de error escriben en `public.system_logs` con el campo `payload` (JSONB) que incluye contexto completo para auditoría (nodo fallido, actor, body de la request, execution_id, stack trace).

---

## 6. VARIABLES DE ENTORNO Y CREDENCIALES

| Recurso | Nombre en n8n | ID | Almacenamiento |
|---|---|---|---|
| Apify API Token | `Apify account` | `RGzWjtqclgqG5lvR` | Credencial nativa n8n |
| Supabase | `Supabase account` | `j1w38OgR2lJam608` | Credencial nativa n8n |

> **Regla de seguridad (no negociable)**: El token de Apify nunca debe ir en la URL como `?token=...`. Siempre usar `authentication: "predefinedCredentialType"` con `nodeCredentialType: "apifyApi"`.

---
