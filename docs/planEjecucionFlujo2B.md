# GUÍA DE DESARROLLO TÉCNICO: FLUJO 2.B (CALENDLY LISTENER & STATUS UPDATER)

Este documento contiene las instrucciones precisas para que la IA diseñe y construya el **Flujo 2.B** en n8n. Este flujo es un microservicio asíncrono e independiente cuya única responsabilidad es escuchar a Calendly y actualizar el estado del lead en la base de datos.

---

## 1. OBJETIVO DEL FLUJO
Recibir el evento `invitee.created` desde el Webhook de Calendly, buscar al lead en Supabase (por email o teléfono) y actualizar su estado a `cita_agendada`, cerrando así el ciclo de venta del Closer Agent.

---

## 2. ESPECIFICACIONES TÉCNICAS
*   **Trigger**: Webhook POST (Calendly).
*   **Base de Datos**: Supabase (Tablas: `leads`, `system_logs`).
*   **Patrón Arquitectónico**: Desacoplamiento (Decoupled Listener). No interactúa con OpenAI ni envía mensajes, solo muta el estado en la base de datos.

---

## 3. CONTRATO DE ENTRADA (PAYLOAD DE CALENDLY)
Calendly envía un payload anidado. Nos interesa el objeto `payload` cuando el evento es `invitee.created`.

```json
{
  "event": "invitee.created",
  "payload": {
    "email": "lead@empresa.com",
    "name": "Carlos Lead",
    "text_reminder_number": "+573001234567",
    "questions_and_answers": []
  }
}
```

---

## 4. PIPELINE DE NODOS (8 Nodos Totales)

### FASE 1: RECEPCIÓN Y EXTRACCIÓN

#### NODO 1: Webhook Receptor (Trigger)
*   **Tipo**: `n8n-nodes-base.webhook`
*   **Método**: `POST`
*   **Ruta**: `/calendly/invitee-created`
*   **Respond**: `Immediately` (Devuelve 200 OK a Calendly al instante).

#### NODO 2: Extraer Datos del Invitee (Code Node)
*   **Propósito**: Extraer el email y el teléfono de forma segura.
*   **Código**:
    ```javascript
    const event = $input.item.json.event;
    if (event !== 'invitee.created') {
      return []; // Ignorar cancelaciones u otros eventos por ahora
    }
    
    const data = $input.item.json.payload;
    const email = data.email;
    const name = data.name;
    // Calendly a veces guarda el teléfono en text_reminder_number o en questions_and_answers
    const phone = data.text_reminder_number || null; 
    
    return { json: { email, name, phone } };
    ```

### FASE 2: BÚSQUEDA Y ACTUALIZACIÓN EN SUPABASE

#### NODO 3: Buscar Lead (Supabase GET)
*   **Operación**: `Get Many` (Limit 1) en tabla `leads`.
*   **Filtro**: Buscar por email. (Configurar: `email = {{ $json.email }}`).
*   **alwaysOutputData**: `true` (Para que el flujo no se rompa si el lead agendó con un correo distinto al que teníamos).

#### NODO 4: ¿Existe el Lead? (IF Node)
*   **Condición**: `$json.id` is not empty.

#### NODO 5A: Actualizar Lead (Supabase UPDATE) - *Rama True*
*   **Tabla**: `leads`
*   **Filtro**: `id = {{ $json.id }}`
*   **Campos a actualizar**: 
    *   `status: 'cita_agendada'`

#### NODO 5B: Crear Lead de Emergencia (Supabase INSERT) - *Rama False*
*   *Contexto*: Si el lead llegó a Calendly por otro lado o usó un correo que no teníamos mapeado.
*   **Tabla**: `leads`
*   **Campos a insertar**: 
    *   `email: {{ $node["Extraer Datos del Invitee"].json.email }}`
    *   `name: {{ $node["Extraer Datos del Invitee"].json.name }}`
    *   `phone: {{ $node["Extraer Datos del Invitee"].json.phone }}`
    *   `status: 'cita_agendada'`

### FASE 3: CONEXIÓN CON PRE-SALES INTELLIGENCE (NUEVO)

#### NODO 6: Llamar a Flujo 4 (Execute Workflow)
*   **Tipo**: `n8n-nodes-base.executeWorkflow`
*   **Propósito**: Enviar el ID del lead al Flujo 4 para que inicie la investigación y genere el Briefing Ejecutivo.
*   **Conexión**: Este nodo debe conectarse a la salida de los nodos 5A y 5B (ambas ramas convergen aquí).
*   **Workflow a llamar**: Seleccionar el Flujo 4 (Pre-Sales Intelligence).
*   **Modo**: `Wait for workflow to finish` (o asíncrono, según preferencia de rendimiento).
*   **Argumentos (JSON)**:
    ```json
    {
      "lead_id": "{{ $json.id }}"
    }
    ```

### FASE 4: RESILIENCIA

#### NODO 7: Error Trigger
*   **Tipo**: `n8n-nodes-base.errorTrigger`
*   **Propósito**: Capturar fallos de conexión con Supabase o errores al llamar al sub-flujo.

#### NODO 8: Log Error (Supabase INSERT)
*   **Tabla**: `system_logs`
*   **Campos**: `workflow_name: 'Flujo 2B - Calendly Listener'`, `error_message: {{ $json.error.message }}`, `payload: {{ $json }}`.

---

## 5. REGLAS DE ORO PARA EL VIBECODING
1.  **Simplicidad:** Este flujo debe ser extremadamente rápido y ligero.
2.  **Filtro de Eventos:** Asegúrate de que el Code Node (Nodo 2) detenga la ejecución si el evento de Calendly es `invitee.canceled`, ya que solo queremos procesar creaciones en esta iteración.
3.  **Convergencia:** Asegúrate de que tanto si el lead se actualiza (5A) como si se crea (5B), el flujo continúe hacia el Nodo 6 para disparar el reporte de ventas.



Prompt para la IA (Flujo 2B):
"Actúa nuevamente como Arquitecto de Automatización experto en n8n. Ahora vamos a construir el Flujo 2B (Calendly Listener), que es el complemento asíncrono del Flujo 2A que acabamos de crear.

Reglas para esta ejecución:
Desacoplamiento: Este es un workflow completamente nuevo e independiente. No lo mezcles ni lo agregues al canvas del Flujo 2A.

Precisión: Sigue estrictamente el archivo planEjecucionFlujo2B.md. Su única función es recibir el webhook, buscar al lead y mutar su estado a cita_agendada.

Te adjunto tres archivos para que tengas el contexto completo de cómo encaja esta pieza en el rompecabezas:
PLAN_DE_DESARROLLO_TECNICO_ECOSISTEMA_DE_AGENTES_IA.md (Contexto general).
planEjecucionFlujo2A.md (Para que entiendas de dónde viene el lead).
planEjecucionFlujo2B.md (El plano exacto que vas a construir ahora).

Por favor, lee los documentos y procede a crear el workflow en n8n vía MCP. Avísame cuando esté listo."