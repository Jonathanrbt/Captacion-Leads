# GUÍA DE DESARROLLO TÉCNICO: FLUJO 2.A (CLOSER AGENT - WHATSAPP CHATBOT & RAG)

Este documento contiene las instrucciones precisas para que la IA diseñe, configure y construya el **Flujo 2.A** en n8n. Este flujo actúa como el "cerebro" conversacional: recibe mensajes de WhatsApp, recupera memoria a largo plazo, consulta la base de conocimiento (RAG), decide si responde o transfiere a un humano, y guarda el historial.

---

## 1. OBJETIVO DEL FLUJO
Responder en tiempo real a los leads vía WhatsApp Cloud API, guiándolos hacia el agendamiento en Calendly, utilizando RAG para precisión técnica y un manejador de estados para saber que el lead está `conversando`.

---

## 2. ESPECIFICACIONES TÉCNICAS
*   **Canal de Entrada/Salida**: WhatsApp Cloud API (Oficial).
*   **Modelo de Lenguaje**: `gpt-4o-mini` (para razonamiento y respuesta).
*   **Modelo de Embeddings**: `text-embedding-3-small` (para RAG).
*   **Base de Datos**: Supabase (Tablas: `leads`, `agent_memory`, `knowledge_base`, `system_logs`).
*   **Patrón Arquitectónico**: Early 200 OK (Respuesta inmediata al Webhook) + Procesamiento Asíncrono + FSM (State Machine) + Human-in-the-loop.

---

## 3. CONTRATO DE ENTRADA (PAYLOAD DE WHATSAPP)
El flujo se activa mediante un Webhook que recibe eventos de Meta. Es vital ignorar los eventos de "estado" (entregado, leído) y procesar solo los "mensajes".

```json
{
  "entry": [
    {
      "changes": [
        {
          "value": {
            "contacts": [{ "wa_id": "573001234567", "profile": { "name": "Juan Perez" } }],
            "messages": [{ "from": "573001234567", "text": { "body": "Hola, me interesa la IA" } }]
          }
        }
      ]
    }
  ]
}
```

---

## 4. PIPELINE DE NODOS (17 Nodos Totales)

### FASE 1: RECEPCIÓN Y NORMALIZACIÓN

#### NODO 1: Webhook Receptor (Trigger)
*   **Tipo**: `n8n-nodes-base.webhook`
*   **Método**: `POST`
*   **Ruta**: `/whatsapp/closer-agent`
*   **Respond**: `Using 'Respond to Webhook' Node` (CRÍTICO: No usar "Immediately" ni "When Last Node Finishes").

#### NODO 2: Respond to Webhook (Early 200 OK)
*   **Tipo**: `n8n-nodes-base.respondToWebhook`
*   **Respond With**: `Text` -> `OK` (HTTP 200).
*   *Propósito*: Meta exige una respuesta en menos de 3 segundos o reintentará enviar el mensaje, causando respuestas duplicadas de la IA.

#### NODO 3: Extraer y Filtrar Mensaje (Code Node)
*   **Propósito**: Extraer el número y el texto, y detener el flujo si es un recibo de lectura.
*   **Código**:
    ```javascript
    const body = $input.item.json.body || $input.item.json;
    const changes = body.entry?.[0]?.changes?.[0]?.value;
    
    if (!changes?.messages || changes.messages.length === 0) {
      // Es un status update (leído/entregado), detenemos el flujo
      return []; 
    }
    
    const phone = changes.messages[0].from;
    const text = changes.messages[0].text.body;
    const name = changes.contacts?.[0]?.profile?.name || "Usuario";
    
    return { json: { phone, text, name } };
    ```

### FASE 2: GESTIÓN DE ESTADO Y MEMORIA (SUPABASE)

#### NODO 4: Buscar Lead (Supabase GET)
*   **Operación**: `Get Many` (Limit 1) en tabla `leads`.
*   **Filtro**: `phone = {{ $json.phone }}`.
*   **alwaysOutputData**: `true` (Para que el flujo continúe si no existe).

#### NODO 5: ¿Existe el Lead? (IF Node)
*   **Condición**: `$json.id` is not empty.

#### NODO 6A: Crear Lead (Supabase INSERT) - *Rama False*
*   **Tabla**: `leads`
*   **Campos**: `phone: {{ $node["Extraer y Filtrar Mensaje"].json.phone }}`, `name: {{ $node["Extraer y Filtrar Mensaje"].json.name }}`, `status: 'conversando'`.

#### NODO 6B: Actualizar Lead (Supabase UPDATE) - *Rama True*
*   **Tabla**: `leads`
*   **Filtro**: `id = {{ $json.id }}`
*   **Campos**: `status: 'conversando'`. (Actualiza de 'prospectado' a 'conversando').

#### NODO 7: Obtener Memoria (Supabase GET)
*   **Operación**: `Get Many` en tabla `agent_memory`.
*   **Filtro**: `lead_id = {{ $json.id || $node["Crear Lead"].json.id }}`.
*   **Sort**: `created_at DESC` (Limit 5).
*   *Nota*: Usar un Code Node posterior o Aggregate para invertir el orden (ASC) y formatearlo como un string de historial para el prompt.

### FASE 3: RAG (RETRIEVAL-AUGMENTED GENERATION)

#### NODO 8: Generar Embedding del Mensaje (OpenAI)
*   **Tipo**: `n8n-nodes-base.openAi`
*   **Recurso**: `Embeddings`
*   **Modelo**: `text-embedding-3-small`
*   **Input**: `{{ $node["Extraer y Filtrar Mensaje"].json.text }}`

#### NODO 9: Buscar en Base de Conocimiento (Supabase RPC)
*   **Tipo**: `n8n-nodes-base.supabase` (Postgres Query / RPC)
*   **Operación**: Ejecutar función `match_knowledge`.
*   **Parámetros**:
    *   `query_embedding`: `{{ $json.embedding }}`
    *   `match_threshold`: `0.7`
    *   `match_count`: `3`
*   *Propósito*: Trae los 3 fragmentos de la tabla `knowledge_base` más relevantes a la pregunta del usuario.

### FASE 4: EL CEREBRO (LLM) Y ENRUTAMIENTO

#### NODO 10: Closer Agent (OpenAI Chat)
*   **Modelo**: `gpt-4o-mini` (Temperature: 0.4 - Balance entre conversacional y preciso).
*   **System Prompt**: Debe incluir:
    1.  Rol: "Eres un Closer Agent experto de [Nombre Agencia]..."
    2.  Contexto del Lead: Extraído del Nodo 4 (Dolores, CMS, Mensaje personalizado original).
    3.  Historial: Extraído del Nodo 7.
    4.  Conocimiento RAG: Extraído del Nodo 9.
    5.  Objetivo: Resolver dudas y entregar el link de Calendly (`https://calendly.com/tu-link`).
*   **Formato de Salida (JSON Schema Estricto)**:
    ```json
    {
      "type": "object",
      "properties": {
        "response_text": { "type": "string", "description": "El mensaje a enviar al usuario" },
        "confidence_score": { "type": "number", "description": "Nivel de confianza de 0.0 a 1.0" },
        "requires_human": { "type": "boolean", "description": "True si el usuario está enojado, pide hablar con un humano, o la pregunta técnica no está en el RAG" },
        "reason": { "type": "string", "description": "Razón interna de la decisión" }
      },
      "required": ["response_text", "confidence_score", "requires_human", "reason"]
    }
    ```

#### NODO 11: Switch / IF (Human Hand-off)
*   **Condición**: Si `requires_human == true` OR `confidence_score < 0.6`.

#### NODO 12A: Alerta a Humano (WhatsApp API) - *Rama True*
*   **Destinatario**: Número del administrador/vendedor (Hardcodeado o variable de entorno).
*   **Mensaje**: `🚨 *ALERTA DE HAND-OFF* 🚨\nLead: {{ $node["Extraer y Filtrar Mensaje"].json.phone }}\nMotivo: {{ $node["Closer Agent"].json.reason }}\nÚltimo mensaje: {{ $node["Extraer y Filtrar Mensaje"].json.text }}`

#### NODO 12B: Enviar Respuesta al Lead (WhatsApp API) - *Rama False*
*   **Destinatario**: `{{ $node["Extraer y Filtrar Mensaje"].json.phone }}`
*   **Mensaje**: `{{ $node["Closer Agent"].json.response_text }}`

### FASE 5: GUARDADO DE MEMORIA Y RESILIENCIA

#### NODO 13: Guardar Memoria (Supabase INSERT)
*   **Tabla**: `agent_memory`
*   **Operación**: Insertar múltiples filas (Array JSON).
*   **Payload**:
    ```json
    [
      {
        "lead_id": "{{ lead_id_variable }}",
        "role": "user",
        "content": "{{ $node['Extraer y Filtrar Mensaje'].json.text }}"
      },
      {
        "lead_id": "{{ lead_id_variable }}",
        "role": "assistant",
        "content": "{{ $node['Closer Agent'].json.response_text }}"
      }
    ]
    ```
*   *Nota*: Esto se ejecuta después del Nodo 12B.

#### NODO 14: Error Trigger (Resiliencia)
*   **Tipo**: `n8n-nodes-base.errorTrigger`
*   **Propósito**: Capturar cualquier fallo en el flujo (ej. OpenAI caído, Supabase timeout).

#### NODO 15: Log Error (Supabase INSERT)
*   **Tabla**: `system_logs`
*   **Campos**: `workflow_name: 'Flujo 2A - Closer Agent'`, `error_message: {{ $json.error.message }}`, `payload: {{ $json }}`.

---

## 5. REGLAS DE ORO PARA EL VIBECODING DE ESTE FLUJO
1.  **No usar nodos "Wait"**: Este flujo debe ser rápido. El usuario está esperando en WhatsApp.
2.  **Credenciales**: Usar credenciales nativas de n8n para Supabase, OpenAI y WhatsApp API. No hardcodear tokens en los HTTP Requests.
3.  **Manejo de Errores OpenAI**: Configurar el nodo de OpenAI con `onError: continueRegularOutput` y manejar el fallo con un IF posterior, o dejar que el Error Trigger (Nodo 14) lo atrape y registre en `system_logs`.


Prompt para la IA (Flujo 2A):
"Actúa como un Arquitecto de Automatización Senior, experto en n8n, Supabase y diseño de Agentes de IA. Tu misión es construir el Flujo 2A (Closer Agent) conectándote a mi instancia de n8n a través del servidor MCP.
Para lograr un resultado espectacular y sin errores, debes seguir estas reglas inquebrantables:

Cero Alucinaciones: Cíñete estrictamente a la arquitectura, nombres de nodos y lógica descrita en el archivo planEjecucionFlujo2A.md. No inventes pasos extra.

Resiliencia de Webhook: Es CRÍTICO que el nodo 'Respond to Webhook' devuelva el HTTP 200 OK inmediatamente para evitar que WhatsApp Cloud API nos penalice o duplique mensajes.

Seguridad: Utiliza únicamente credenciales nativas de n8n para Supabase, OpenAI y WhatsApp. NUNCA hardcodees API Keys en nodos HTTP o Code.

JSON Schemas: Aplica exactamente el JSON Schema proporcionado para el nodo de OpenAI, garantizando que el output sea estructurado.

Te adjunto dos archivos como contexto:
PLAN_DE_DESARROLLO_TECNICO_ECOSISTEMA_DE_AGENTES_IA.md (Contexto general del ecosistema).
planEjecucionFlujo2A.md (El plano exacto que vas a construir ahora).

Por favor, lee los documentos, confirma que entiendes la arquitectura y procede a crear y configurar el workflow en n8n paso a paso. Avísame cuando termines o si encuentras algún bloqueo técnico."