-- =============================================================================
-- MIGRACIÓN INICIAL: ECOSISTEMA DE AGENTES IA
-- =============================================================================
-- Crea el esquema base para los 4 flujos (Outreach, Closer, Content, Pre-Sales)
-- documentados en docs/PLAN_DE_DESARROLLO_TECNICO_ECOSISTEMA_DE_AGENTES_IA.md
--
-- Incluye:
--   1. Extensión pgvector (búsqueda semántica)
--   2. Tabla leads          (estado de prospección)
--   3. Tabla knowledge_base (RAG)
--   4. Tabla agent_memory   (memoria de largo plazo del Closer)
--   5. Tabla system_logs    (resiliencia y manejo de errores)
--   6. Tabla pending_content (Content Agent - human in the loop)
--   7. Función RPC match_knowledge (búsqueda semántica filtrada)
--   8. RLS habilitado en todas las tablas (service_role bypassa RLS por defecto;
--      anon y authenticated quedan bloqueados sin políticas explícitas)
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Extensiones
-- -----------------------------------------------------------------------------
create extension if not exists vector;


-- -----------------------------------------------------------------------------
-- 2. Tabla: leads
-- -----------------------------------------------------------------------------
create table if not exists public.leads (
    id                   uuid primary key default gen_random_uuid(),
    name                 text,
    email                text unique,
    phone                text,
    company_name         text,
    website              text,
    rating               numeric,
    cms                  text,
    status               text default 'nuevo',
    personalized_message text,
    tiene_chatbot        boolean,
    reserva_manual       boolean,
    errores_carga        text,
    created_at           timestamp with time zone default now()
);

comment on table  public.leads is 'Prospectos generados y calificados por el Outreach Agent';
comment on column public.leads.status is 'Estado del lead: nuevo | prospectado | cita_agendada';


-- -----------------------------------------------------------------------------
-- 3. Tabla: knowledge_base (RAG)
-- -----------------------------------------------------------------------------
create table if not exists public.knowledge_base (
    id         uuid primary key default gen_random_uuid(),
    content    text not null,
    metadata   jsonb,
    embedding  vector(1536),
    created_at timestamp with time zone default now()
);

comment on table  public.knowledge_base is 'Base de conocimiento para RAG (precios, casos de éxito, FAQs)';
comment on column public.knowledge_base.embedding is 'text-embedding-3-small (OpenAI) - 1536 dimensiones';

create index if not exists knowledge_base_embedding_hnsw_idx
    on public.knowledge_base
    using hnsw (embedding vector_cosine_ops);


-- -----------------------------------------------------------------------------
-- 4. Tabla: agent_memory (memoria de largo plazo)
-- -----------------------------------------------------------------------------
create table if not exists public.agent_memory (
    id          uuid primary key default gen_random_uuid(),
    lead_id     uuid references public.leads(id) on delete cascade,
    role        text check (role in ('user', 'assistant', 'system')),
    content     text not null,
    embedding   vector(1536),
    tokens_used int,
    created_at  timestamp with time zone default now()
);

comment on table public.agent_memory is 'Historial conversacional del Closer Agent con embeddings para recall semántico';

create index if not exists agent_memory_embedding_hnsw_idx
    on public.agent_memory
    using hnsw (embedding vector_cosine_ops);

create index if not exists agent_memory_lead_id_created_at_idx
    on public.agent_memory (lead_id, created_at desc);


-- -----------------------------------------------------------------------------
-- 5. Tabla: system_logs (resiliencia)
-- -----------------------------------------------------------------------------
create table if not exists public.system_logs (
    id            uuid primary key default gen_random_uuid(),
    workflow_name text not null,
    error_message text not null,
    payload       jsonb,
    created_at    timestamp with time zone default now()
);

comment on table public.system_logs is 'Registro de errores capturados por los Error Triggers de cada workflow de n8n';

create index if not exists system_logs_workflow_created_at_idx
    on public.system_logs (workflow_name, created_at desc);


-- -----------------------------------------------------------------------------
-- 6. Tabla: pending_content (Content Agent - human in the loop)
-- -----------------------------------------------------------------------------
create table if not exists public.pending_content (
    id                uuid primary key default gen_random_uuid(),
    content_linkedin  text,
    content_instagram text,
    content_facebook  text,
    status            text default 'pending',
    created_at        timestamp with time zone default now()
);

comment on table  public.pending_content is 'Borradores multi-formato generados por el Content Agent pendientes de aprobación';
comment on column public.pending_content.status is 'Estado: pending | approved';


-- -----------------------------------------------------------------------------
-- 7. Función RPC: match_knowledge (búsqueda semántica filtrable)
-- -----------------------------------------------------------------------------
create or replace function public.match_knowledge(
    query_embedding vector(1536),
    match_threshold float,
    match_count     int,
    filter_metadata jsonb default '{}'
)
returns table (
    id         uuid,
    content    text,
    metadata   jsonb,
    similarity float
)
language plpgsql
as $$
begin
    return query
    select
        kb.id,
        kb.content,
        kb.metadata,
        1 - (kb.embedding <=> query_embedding) as similarity
    from public.knowledge_base kb
    where 1 - (kb.embedding <=> query_embedding) > match_threshold
      and (filter_metadata = '{}'::jsonb or kb.metadata @> filter_metadata)
    order by kb.embedding <=> query_embedding
    limit match_count;
end;
$$;

comment on function public.match_knowledge is 'Búsqueda semántica con filtro opcional por metadata. Usada por el Closer Agent para RAG.';


-- -----------------------------------------------------------------------------
-- 8. Row Level Security
-- -----------------------------------------------------------------------------
-- En Supabase, el rol `service_role` bypassa RLS por defecto. Habilitamos RLS
-- sin políticas para roles `anon` y `authenticated`, de modo que solo n8n
-- (que se conecta con la service_role key) pueda leer/escribir.

alter table public.leads            enable row level security;
alter table public.knowledge_base   enable row level security;
alter table public.agent_memory     enable row level security;
alter table public.system_logs      enable row level security;
alter table public.pending_content  enable row level security;

-- Política redundante pero explícita: solo service_role tiene acceso total.
-- (service_role ya bypassa RLS, pero dejar la política documentada es buena práctica)
do $$
declare
    t text;
begin
    foreach t in array array['leads','knowledge_base','agent_memory','system_logs','pending_content']
    loop
        execute format(
            'drop policy if exists "service_role_full_access" on public.%I;', t
        );
        execute format(
            'create policy "service_role_full_access" on public.%I '
            'as permissive for all to service_role using (true) with check (true);',
            t
        );
    end loop;
end $$;
