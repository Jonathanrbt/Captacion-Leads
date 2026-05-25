# PLAN DE DESARROLLO TÉCNICO:
## ECOSISTEMA DE AGENTES IA

1. Preparación del Entorno

Primero, habilitamos la extensión necesaria en el editor SQL de Supabase.

```sql
-- Habilitar la extensión para vectores
create extension if not exists vector;
```

2. Tabla de Leads

```sql
create table leads (
    id uuid primary key default gen_random_uuid(),
    name text,
    email text unique, -- Permite asociar la cita de Calendly con el lead
    phone text,
    company_name text,
    website text,
    rating numeric,              -- NUEVO: Extraído de Google Maps
    cms text,                    -- NUEVO: Detectado en el enriquecimiento
    status text default 'nuevo', --'nuevo','prospectado','cita_agendada'
    personalized_message text,   -- Guardado por Outreach Agent
    tiene_chatbot boolean,       -- Extraído en el análisis de dolor
    reserva_manual boolean,      -- Extraído en el análisis de dolor
    errores_carga text,          -- Extraído en el análisis de dolor
    created_at timestamp with time zone default now()
);
```

3. Tabla de Base de Conocimiento (RAG)

Esta tabla servirá para que tus agentes consulten información técnica, precios de la agencia
o casos de éxito antes de responder.

```sql
create table knowledge_base (
  id uuid primary key default gen_random_uuid(),
  content text not null, -- El fragmento de texto (chunk)
  metadata jsonb,        -- Categoría, fuente (URL o PDF), etiquetas
  embedding vector(1536), -- 1536 es la dimensión estándar para
text-embedding-3-small de OpenAI
  created_at timestamp with time zone default now()
);

-- Índice para búsqueda rápida (HNSW es superior para escalabilidad)
create index on knowledge_base using hnsw (embedding vector_cosine_ops);
```

4. Tabla de Memoria de Conversación (Memoria de Largo Plazo)

A diferencia de una tabla de logs simple, esta permite que el Closer Agent "recuerde" lo
que el lead dijo hace tres días o en un canal distinto.

```sql
create table agent_memory (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid references leads(id) on delete cascade,
  role text check (role in ('user', 'assistant', 'system')),
  content text not null,
  embedding vector(1536), -- Embedding del mensaje individual o del resumen de la charla
  tokens_used int,
  created_at timestamp with time zone default now()
);

create index on agent_memory using hnsw (embedding vector_cosine_ops);
```

5. Tabla para el manejo de excepciones y resiliencia ( manejo de errores)

```sql
create table system_logs (
    id uuid primary key default gen_random_uuid(),
    workflow_name text not null,
    error_message text not null,
    payload jsonb,
    created_at timestamp with time zone default now()
);
```

6. Tabla de Contenido Pendiente (content agent)

```sql
create table pending_content (
    id uuid primary key default gen_random_uuid(),
    content_linkedin text,
    content_instagram text,
    content_facebook text,
    status text default 'pending', -- 'pending', 'approved'
    created_at timestamp with time zone default now()
);
```

7. Función de Búsqueda Semántica

Para que n8n o tu backend puedan consultar estos datos fácilmente, creamos una función
RPC.

```sql
create or replace function match_knowledge(
  query_embedding vector(1536),
  match_threshold float,
  match_count int,
  filter_metadata jsonb default '{}'
)
returns table (
  id uuid,
  content text,
  metadata jsonb,
  similarity float
)
language plpgsql
as $$
begin
  return query
  select
    knowledge_base.id,
    knowledge_base.content,
    knowledge_base.metadata,
    1 - (knowledge_base.embedding <=> query_embedding) as similarity
  from knowledge_base
  where 1 - (knowledge_base.embedding <=> query_embedding) >
match_threshold
    and (filter_metadata = '{}' or knowledge_base.metadata @>
filter_metadata)
  order by knowledge_base.embedding <=> query_embedding
  limit match_count;
end;
$$;
```

1. FLUJO: OUTREACH AGENT (Generación y Calificación Asíncrona con Apify)

Objetivo: Dejar de ser un "bot de spam" para convertirse en un "analista de oportunidades" mediante la automatización de la prospección masiva ultra-personalizada, delegando el scraping a infraestructura externa para asegurar alta disponibilidad.

● Precisión Técnica:
  * Extracción Externa: Uso de Apify para bypass de captchas y proxies residenciales, evitando bloqueos de IP en el servidor de n8n.
  * Fase de limpieza obligatoria: Verificación de emails mediante APIs de validación (Hunter/Lusha) antes de la inserción.
  * Detección de puntos de dolor: Análisis mediante IA del HTML/Metadata extraído para buscar errores específicos (lentitud de carga, ausencia de chatbots, SEO deficiente).

● Coherencia: El mensaje de contacto se genera dinámicamente basado en el hallazgo técnico guardado en la base de datos, no en una plantilla fija.

● Humanización: Uso de variaciones en la temperatura del LLM y Spintax para evitar filtros de spam y sonar natural.

---

### FLUJO 1.A: LANZADOR ASÍNCRONO DE SCRAPING (Outreach - Fase de Extracción)

Tarea: Disparar de manera masiva y controlada el scraping de leads en la nube sin bloquear el hilo de ejecución de n8n.

● Instrucciones de Desarrollo:
1. Trigger de Inicio: Un nodo de intervalo cron (semanal/mensual) o ejecución manual inicia el flujo.
2. Configuración del Lanzador HTTP (Apify Node): Conectar con la API de Apify para iniciar de forma asíncrona el Actor "Google Maps Scraper" (enviando los parámetros de búsqueda de los leads en formato JSON).
3. Configuración de Parámetros: Configurar la petición para que Apify responda de inmediato con el ID del trabajo iniciado (`status: RUNNING`). n8n finaliza la ejecución de este workflow inmediatamente para liberar memoria.
4. Encadenamiento en Apify: Configurar en Apify el uso de un segundo Actor ("Contact Details Scraper") que tome de forma automática los dominios extraídos de Google Maps para buscar correos, teléfonos y perfiles de redes sociales.

---

### FLUJO 1.B: RECEPTOR, CALIFICACIÓN Y MENSAJERÍA (Outreach - Fase de Procesamiento)

Tarea: Recibir los leads limpios de Apify, calificar sus puntos de dolor de forma estructurada con IA, generar mensajes personalizados y encolar el envío.

● Instrucciones de Desarrollo:
1. Webhook Receptor (Entry Point): Un nodo "Webhook" en n8n configurado como URL pública, registrado en las integraciones de Apify para activarse únicamente cuando la tarea del scraper cambie al estado 'SUCCEEDED'.
2. Módulo de Enriquecimiento y Validación: Pasar el array de leads recibidos por el nodo de enriquecimiento HTTP para conectar con Hunter.io o Abstract API. Validar la entregabilidad del correo y detectar el CMS de la web de destino.
3. Análisis Estructurado de "Pain Points": Implementar un nodo de OpenAI (Temperature: 0.1) con Structured Output (JSON Schema estricto) que procese el HTML o metadata extraído por Apify. El prompt debe extraer booleanos y descripciones técnicas para mapear exactamente:
   * `tiene_chatbot` (boolean)
   * `reserva_manual` (boolean)
   * `errores_carga` (text con la descripción del fallo de carga)
4. Guardado en Supabase (Lead Inicial): Insertar los datos procesados en la tabla `leads` con el estado inicial `nuevo`.
5. Generación de Mensaje: Utilizar un segundo nodo de OpenAI (Temperature: 0.7) que consuma las columnas `tiene_chatbot`, `reserva_manual` y `errores_carga` del lead creado para redactar un mensaje altamente personalizado.
6. Actualización y Encolado de Envío: Guardar el texto generado en la tabla `leads` (columna `personalized_message`), actualizar el estado del lead (`status = 'prospectado'`) y enviarlo al nodo de mensajería (Email/LinkedIn) aplicando un retraso aleatorio (Jitter de 2 a 8 minutos entre envíos) para proteger las cuentas emisoras.

● Definición final en DB: Update leads set status = 'prospectado' where id = {{ $json.lead_id }}.

2. FLUJO: CLOSER AGENT (Gestión de Conversación y
Cita)

Objetivo: Guiar al lead hacia la cita mediante una atención estilo "concierge".

● Precisión Técnica: * Implementación de Manejador de Estados (FSM) en base de
datos para saber exactamente en qué punto de la venta está el usuario.
○ Validación de datos estructurados (Zod/JSON Schema) para asegurar que la
información recolectada sea procesable.
● Coherencia: Uso de RAG (Retrieval-Augmented Generation) para responder dudas
sobre precios o procesos basándose exclusivamente en la documentación oficial de
la agencia.
● Humanización: Protocolo de "Hand-off" humano. Si la IA detecta sentimientos de
frustración o una pregunta técnica de alta complejidad, transfiere la charla a un
humano enviando una alerta prioritaria.

Tarea: Responder en tiempo real y agendar en Calendly.

● Instrucciones de Desarrollo:
1. Webhook Listener y Respuesta Inmediata: Un único entry-point en n8n
para WhatsApp/Gmail. OBLIGATORIO: Implementar un nodo "Respond to
Webhook" inmediatamente después del trigger para devolver un HTTP 200
OK al proveedor. Esto evita reintentos y duplicación de procesos.
2. Identificación de Contexto: (Procesamiento Asíncrono): Pasar el payload a
un sub-workflow mediante el nodo "Execute Workflow". Consultar en
Supabase el lead_id filtrando por el teléfono (remitente de WhatsApp) o email
(remitente de Gmail). Si no existe en la tabla leads, crearlo. Si existe,
recuperar los últimos 5 mensajes de la tabla agent_memory y el campo
personalized_message original.

3. Inyección RAG: Antes de generar la respuesta, realizar una búsqueda
semántica en la tabla knowledge_base usando el embedding de la
pregunta del usuario.
4. Lógica de Agendamiento: Si la intención detectada es "agendar", el agente
debe presentar el link de Calendly y monitorear el webhook de Calendly para
marcar el lead como status = 'cita_agendada'.
5. Human Hand-off: Si el score de confianza del LLM es < 0.6 o detecta
irritación, disparar alerta a Slack/Discord con el historial.

3. FLUJO: CONTENT AGENT (Autoridad en Redes)

Objetivo: Nutrir la marca personal de la agencia con contenido basado en datos.

● Precisión Técnica: * Conexión a fuentes de noticias en tiempo real (RSS de
IA/Tech) para generar contenido de tendencia (Newsjacking).
○ Análisis de "Common Pain Points" basado en las conversaciones reales
guardadas en la tabla de leads.
● Coherencia: El agente genera borradores automáticos que deben pasar por una
aprobación manual (Human-in-the-loop) antes de publicarse vía API.
● Humanización: Adaptación de tono por plataforma (profesional en LinkedIn,
dinámico en Instagram, directo en Facebook).

Tarea: Mantener presencia digital basada en los datos reales del mercado.

● Instrucciones de Desarrollo:
1. Recolección de Insights: Una consulta semanal a la tabla leads y
agent_memory para identificar los temas y preguntas más recurrentes de los
usuarios (FAQ dinámico).
2. Generación Multi-formato: Un nodo de OpenAI que transforme un "insight"
en 3 versiones: LinkedIn (profesional), Instagram (visual/gancho) y Facebook
(comunitario).
3. Human-in-the-loop (Aprobación Stateless): El contenido se inserta en la
tabla pending_content con status 'pending'. Se envía una alerta a
Slack/Discord mediante un webhook que incluye bloques interactivos
(Botones Aprobar/Rechazar). Prohibido usar el nodo "Wait" de n8n para
evitar fugas de memoria.
4. Publicación vía Webhook Inverso: Los botones de Slack/Discord envían un
POST a un Webhook secundario e independiente en n8n. Este flujo recibe el
ID del contenido, actualiza el status a 'approved' en Supabase y dispara la
publicación en las APIs destino.
5.

4. FLUJO: PRE-SALES INTELLIGENCE (Briefing
Ejecutivo)

Objetivo: Maximizar el porcentaje de cierre del vendedor humano.

● Precisión Técnica: * Enriquecimiento de datos mediante scraping de LinkedIn del
CEO/Dueño para entender su perfil psicológico de compra.
○ Generación de un "Simulador de Objeciones" para que el vendedor practique
antes de la llamada.
● Coherencia: Creación de una página de diagnóstico personalizada (ej. en Notion o
PDF dinámico) que muestra visualmente los ahorros potenciales que la clínica
obtendría con la IA.
● Salida: Briefing ejecutivo con 5 puntos clave: Qué hacen, qué les falta, qué les
vamos a vender, cómo van a decir que no y cómo responderles.
● Paso recomendado: Consultar la tabla leads usando el email del invitado de Calendly
para extraer los "Pain Points" identificados en el paso 1 y el historial de la conversación
del paso 2. Esto garantiza que el reporte de ventas entregado al vendedor humano
contenga tanto la investigación externa como todo el historial de interacciones previas.

Tarea: Entregar al vendedor un reporte "listo para cerrar".

● Instrucciones de Desarrollo:
1. Trigger de Cita: Escuchar el webhook de Calendly (invitee.created).
2. Deep Research (APIs Especializadas): El agente debe consumir la API de
Proxycurl o Apollo.io para extraer el perfil de LinkedIn del lead y de su
empresa en formato JSON limpio. Está estrictamente prohibido hacer
scraping directo a LinkedIn desde n8n. Complementar con una búsqueda en
Google Custom Search API (Programmable Search Engine) para extraer
noticias recientes de la empresa.
3. Consolidación de Contexto Interno y Generación de Reporte: Realizar una
consulta en Supabase a las tablas leads y agent_memory utilizando el email
obtenido de Calendly en el Paso 1. El prompt de OpenAI debe procesar los
datos de la investigación (Paso 2) junto con los dolores previamente
identificados y el historial de la conversación para estructurar el output en
JSON: empresa_analisis, dolores_clave, simulacion_objeciones,
propuesta_valor_sugerida.
4. Entrega: Convertir el JSON a un documento legible (Markdown a PDF o
Notion Page) y enviarlo por WhatsApp/Email al vendedor 1 día antes de la cita.

ARQUITECTURA ASÍNCRONA,
CONECTIVIDAD Y REGLAS

Para que estos flujos no colapsen y trabajen de forma coherente, se deben seguir estos
principios de ingeniería:

1. Comunicación mediante Estados (State Machine)

Los flujos no se llaman entre sí directamente de forma síncrona. La base de datos
(Supabase) actúa como el Bus de Eventos.

● Ejemplo: Cuando el Outreach Agent termina, solo cambia el estado en DB. El Closer
Agent se activa solo cuando llega un Webhook de respuesta, consultando ese
estado.

2. Gestión de Colas y Rate Limits

● Evitar Bloqueos: El Outreach Agent debe procesar los leads en lotes (Batches) de
10-20, usando nodos de "Wait" o colas de mensajes (BullMQ si se escala fuera de
n8n) para no saturar las APIs de correos o LinkedIn.
● Prioridad de Respuesta: El Closer Agent debe tener prioridad de cómputo sobre el
Content Agent.

3. Sincronización de Memoria (Embeddings)

● Cada vez que el Outreach Agent detecta un "dolor" nuevo en una clínica, ese texto
debe convertirse en embedding y guardarse.
● Esto permite que el Content Agent "sepa" de qué hablar esa semana y que el
Pre-Sales Agent tenga contexto histórico del primer contacto.

4. Manejo de Errores (Resiliencia)

● Cada flujo debe tener un nodo de Error Trigger en n8n que registre el fallo en una
tabla system_logs.
● Si una API externa (OpenAI o WhatsApp) falla, implementar una política de
Exponential Backoff (reintentos automáticos con tiempos crecientes).

5. Seguridad y Privacidad

● Los datos de salud (si se manejan clínicas) deben estar cifrados en tránsito.
● Uso estricto de variables de entorno para las API Keys, nunca hardcodeadas en los
nodos de n8n.

REGLAS DE DESARROLLO Y SEGURIDAD

1. Rate Limiting: Implementar colas de espera (Queues) para envíos masivos. Nunca
disparar más de 20 mensajes por hora por canal para proteger la reputación del
dominio/número.

2. Validación de Salida: Los nodos de IA en n8n deben pasar por un filtro de
"Seguridad de Marca" para asegurar que no se prometan descuentos no autorizados
o garantías imposibles.

3. Logging Total: Cada decisión tomada por un agente (desde elegir un lead hasta
enviar un mensaje) debe quedar registrada con su "razonamiento" (Chain of
Thought) en Supabase para auditoría técnica.
