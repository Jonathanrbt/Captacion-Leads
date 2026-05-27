# GUÍA DE DESARROLLO TÉCNICO: FLUJO 4 (PRE-SALES INTELLIGENCE - BRIEFING EJECUTIVO)

Este documento contiene las instrucciones precisas para que la IA diseñe y construya el **Flujo 4** en n8n. Este flujo actúa como un analista de inteligencia de ventas: recopila todo el contexto técnico y conversacional del lead, lo enriquece con Apollo.io y genera un reporte estratégico en formato Markdown que se envía inmediatamente al vendedor por WhatsApp.

---

## 1. OBJETIVO DEL FLUJO
Maximizar la tasa de cierre del vendedor humano entregándole un "Briefing Ejecutivo" estructurado en su WhatsApp en el instante exacto en que un lead agenda una cita.

---

## 2. ESPECIFICACIONES TÉCNICAS
*   **Trigger**: `Execute Workflow Trigger` (Llamado internamente por el Flujo 2B).
*   **Enriquecimiento B2B**: API de Apollo.io (Organization Enrichment).
*   **Modelo de Lenguaje**: `gpt-4o` (Se requiere alto razonamiento para simular objeciones).
*   **Base de Datos**: Supabase (Tablas: `leads`, `agent_memory`, `system_logs`).
*   **Canal de Salida**: WhatsApp Cloud API (Mensaje directo al vendedor).
*   **Formato de Salida**: Texto plano estructurado en Markdown.

---

## 3. CONTRATO DE ENTRADA (PAYLOAD DEL FLUJO 2B)
El flujo espera recibir el ID del lead desde el flujo padre (Flujo 2B) para iniciar la investigación.

```json
{
  "lead_id": "uuid-del-lead-en-supabase",
  "email": "lead@empresa.com"
}
```

---

## 4. PIPELINE DE NODOS (9 Nodos Totales)

### FASE 1: RECOPILACIÓN DE CONTEXTO INTERNO

#### NODO 1: Execute Workflow Trigger
*   **Tipo**: `n8n-nodes-base.executeWorkflowTrigger`
*   **Propósito**: Recibir el `lead_id` desde el Flujo 2B.

#### NODO 2: Obtener Datos del Lead (Supabase GET)
*   **Operación**: `Get Many` (Limit 1) en tabla `leads`.
*   **Filtro**: `id = {{ $json.lead_id }}`.
*   *Propósito*: Extraer `website`, `company_name`, `tiene_chatbot`, `reserva_manual`, `errores_carga`, `cms`.

#### NODO 3: Obtener Historial de Chat (Supabase GET)
*   **Operación**: `Get Many` en tabla `agent_memory`.
*   **Filtro**: `lead_id = {{ $node["Obtener Datos del Lead"].json.id }}`.
*   **Sort**: `created_at ASC`.
*   *Propósito*: Traer toda la conversación que tuvo el Closer Agent con el lead.

### FASE 2: ENRIQUECIMIENTO EXTERNO (APOLLO.IO)

#### NODO 4: Limpiar Dominio Web (Code Node)
*   **Propósito**: Apollo.io requiere un dominio limpio (ej. `empresa.com`) sin `https://` ni rutas.
*   **Código**:
    ```javascript
    let website = $node["Obtener Datos del Lead"].json.website || "";
    let domain = website.replace(/^(?:https?:\/\/)?(?:www\.)?/i, "").split('/')[0];
    return { json: { domain: domain } };
    ```

#### NODO 5: Enriquecer Empresa (HTTP Request - Apollo API)
*   **Tipo**: `n8n-nodes-base.httpRequest`
*   **Método**: `GET`
*   **URL**: `https://api.apollo.io/v1/organizations/enrich`
*   **Query Parameters**:
    *   `domain`: `{{ $json.domain }}`
*   **Headers**:
    *   `Cache-Control`: `no-cache`
    *   `Content-Type`: `application/json`
    *   `x-api-key`: `{{ $env.APOLLO_API_KEY }}` (Usar credencial o variable de entorno).
*   **onError**: `continueRegularOutput` (Si Apollo no encuentra la empresa, el flujo debe continuar solo con los datos internos).

### FASE 3: ANÁLISIS Y GENERACIÓN DEL BRIEFING

#### NODO 6: Analista de Ventas (OpenAI Chat)
*   **Modelo**: `gpt-4o` (Temperature: 0.5).
*   **System Prompt**: "Eres un Director de Inteligencia de Ventas B2B. Tu objetivo es armar un Briefing Ejecutivo en formato Markdown para que el cerrador de ventas se prepare para su llamada."
*   **User Prompt**: Debe inyectar los datos recopilados:
    ```text
    Analiza la siguiente información y genera el Briefing:
    
    1. DATOS TÉCNICOS (Extraídos de su web):
    - Empresa: {{ $node["Obtener Datos del Lead"].json.company_name }}
    - CMS: {{ $node["Obtener Datos del Lead"].json.cms }}
    - Tiene Chatbot: {{ $node["Obtener Datos del Lead"].json.tiene_chatbot }}
    - Reserva Manual: {{ $node["Obtener Datos del Lead"].json.reserva_manual }}
    - Errores Web: {{ $node["Obtener Datos del Lead"].json.errores_carga }}
    
    2. DATOS DE APOLLO.IO (Contexto B2B):
    {{ JSON.stringify($node["Enriquecer Empresa"].json.organization || "No encontrado") }}
    
    3. HISTORIAL DE CONVERSACIÓN CON EL BOT:
    {{ JSON.stringify($node["Obtener Historial de Chat"].json) }}
    
    ESTRUCTURA OBLIGATORIA DEL MARKDOWN:
    # 🎯 Briefing de Ventas: [Nombre Empresa]
    **1. Qué hacen:** (Resumen de su negocio según Apollo/Web)
    **2. Qué les falta (Dolores):** (Análisis de sus carencias técnicas)
    **3. Qué les vamos a vender:** (Ángulo de venta sugerido basado en sus dolores)
    **4. Cómo van a decir que no:** (Simulación de 2 objeciones probables basadas en su historial de chat o tamaño de empresa)
    **5. Cómo responderles:** (Scripts exactos para rebatir esas objeciones)
    ```

### FASE 4: ENTREGA Y RESILIENCIA

#### NODO 7: Enviar Briefing al Vendedor (WhatsApp API)
*   **Destinatario**: Número del vendedor (Hardcodeado o variable de entorno).
*   **Mensaje**: `{{ $node["Analista de Ventas"].json.message.content }}`
*   *Nota*: WhatsApp soporta formato Markdown básico (`*bold*`, `_italic_`), asegúrate de que el output de OpenAI sea compatible con la sintaxis de WhatsApp.

#### NODO 8: Error Trigger
*   **Tipo**: `n8n-nodes-base.errorTrigger`

#### NODO 9: Log Error (Supabase INSERT)
*   **Tabla**: `system_logs`
*   **Campos**: `workflow_name: 'Flujo 4 - Pre-Sales Intelligence'`, `error_message: {{ $json.error.message }}`, `payload: {{ $json }}`.

---

## 5. REGLAS DE ORO PARA EL VIBECODING
1.  **Manejo de Fallos en Apollo:** Es muy común que Apollo no tenga datos de empresas locales pequeñas. El nodo de Apollo DEBE tener `onError: continueRegularOutput`, y el prompt de OpenAI debe estar preparado para recibir `"No encontrado"` y basar su análisis únicamente en los datos técnicos y el historial de chat.
2.  **Sintaxis de WhatsApp:** WhatsApp no soporta Markdown complejo como `# H1` o `**bold**` (usa `*bold*`). Pide a OpenAI en el prompt que use la sintaxis nativa de WhatsApp para negritas (`*texto*`) y cursivas (`_texto_`).


Prompt para la IA (Flujo 4):
"Actúa como un Arquitecto de Automatización Senior experto en n8n. Tu misión es construir el Flujo 4 (Pre-Sales Intelligence) conectándote a mi instancia de n8n a través del servidor MCP.

Este flujo es un sub-workflow que será llamado por otro flujo, recibirá un lead_id, investigará a la empresa usando Apollo.io, analizará el historial con OpenAI y enviará un reporte al vendedor por WhatsApp.

Reglas inquebrantables para lograr un resultado espectacular:
Cero Alucinaciones: Sigue la arquitectura, fases y nombres de los nodos al pie de la letra según el archivo planEjecucionFlujo4.md. No inventes pasos extra.

Resiliencia de Apollo.io: Es CRÍTICO que configures el nodo HTTP de Apollo.io con onError: continueRegularOutput. Si Apollo no encuentra la empresa, el flujo NO debe detenerse; debe pasar un valor nulo a OpenAI y continuar.

Formato WhatsApp: Asegúrate de que el System Prompt de OpenAI especifique claramente que el Markdown generado debe usar la sintaxis nativa de WhatsApp (*negrita*, _cursiva_, sin # para títulos), ya que el mensaje se enviará por la API de WhatsApp.

Seguridad: Utiliza credenciales nativas de n8n para Supabase, OpenAI y WhatsApp.

Te adjunto dos archivos como contexto:
PLAN_DE_DESARROLLO_TECNICO_ECOSISTEMA_DE_AGENTES_IA.md (Contexto general del ecosistema).
planEjecucionFlujo4.md (El plano exacto que vas a construir ahora).

Por favor, lee los documentos, confirma que entiendes la arquitectura y procede a crear y configurar el workflow en n8n paso a paso. Avísame cuando termines o si encuentras algún bloqueo técnico."