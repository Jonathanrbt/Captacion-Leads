-- =============================================================================
-- SCRIPT STANDALONE: INICIALIZACIÓN DE BASE DE DATOS - CaptacionLeads
-- =============================================================================
-- Este script es un duplicado idempotente de la migración:
--   supabase/migrations/20260525194615_initial_schema.sql
--
-- Úsalo cuando NO puedas (o no quieras) usar `supabase db push`, por ejemplo:
--   - Ejecutarlo manualmente desde el SQL Editor de Supabase Studio.
--   - Aplicarlo a un entorno externo (otro Postgres con pgvector).
--   - Aplicarlo vía psql:
--       psql "postgresql://postgres:[PASSWORD]@db.[PROJECT_REF].supabase.co:5432/postgres" \
--            -f scripts/init_database.sql
--
-- Es seguro re-ejecutarlo: usa IF NOT EXISTS y CREATE OR REPLACE en todo.
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
alter table public.leads            enable row level security;
alter table public.knowledge_base   enable row level security;
alter table public.agent_memory     enable row level security;
alter table public.system_logs      enable row level security;
alter table public.pending_content  enable row level security;

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


-- =============================================================================
-- VERIFICACIÓN POST-INSTALACIÓN (opcional, descomentar para chequear)
-- =============================================================================
-- select table_name from information_schema.tables
--   where table_schema = 'public' order by table_name;
--
-- select extname, extversion from pg_extension where extname = 'vector';
--
-- select routine_name from information_schema.routines
--   where routine_schema = 'public' and routine_name = 'match_knowledge';
