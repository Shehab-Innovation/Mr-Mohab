-- ============================================================
-- NEXORA — Phase X.5.2: Student-Profile RPC Isolation (DB-ONLY)
-- Owner: Shehab Innovation
-- Date:  2026-09-14
-- Baseline: main @ b3973dc (Phase X.5.1: teacher roster ownership RPCs)
-- Depends on: X.2 + X.4-A + X.5.1 executed
--
-- SCOPE (STRICT)
--   * Replaces the BODIES of exactly FOUR existing RPCs:
--       1) public.get_teacher_student_by_session(text, text)
--       2) public.get_teacher_student_results_by_session(text, text)
--       3) public.get_teacher_student_activities_by_session(text, text)
--       4) public.get_teacher_student_certificates_by_session(text, text)
--   * VERIFIED LIVE CONTRACTS (authoritative — captured from the
--     live PostgreSQL definitions; preserved EXACTLY below):
--       1) TABLE(id uuid, student_id text, name text, phone text,
--                parent_phone text, created_at timestamptz,
--                last_activity timestamptz)
--       2) TABLE(id uuid, result_id text, student_id text, type text,
--                grade integer, unit integer, title text,
--                correct integer, total integer, percentage integer,
--                completed_at timestamptz)
--       3) TABLE(id uuid, student_id text, activity_type text,
--                page text, details jsonb, created_at timestamptz)
--       4) TABLE(id uuid, certificate_id text, result_id text,
--                student_id text, student_name text, teacher_name text,
--                teacher_image text, assessment_name text,
--                score integer, message text, date text,
--                created_at timestamptz)
--   * SECTION 1.6 guards verify the LIVE catalog against these
--     contracts LITERALLY (count + names + order + types) and
--     BLOCK before any CREATE OR REPLACE on any mismatch.
--   * get_teacher_student_evaluations_by_session is NOT touched
--     (already ownership-scoped per the X.1.5 audit).
--   * NO table/column/data changes. NO backfill. NO RLS. NO
--     session-creation or token-format changes.
--   * Legacy RPCs find_student_by_phone / update_student_by_phone
--     are NOT touched.
--   * Grants: only the four functions' EXECUTE is re-asserted
--     (same public API: anon + authenticated, no PUBLIC).
--
-- SECURITY MODEL (each of the 4 functions)
--   * SECURITY DEFINER, SET search_path = '' (schema-qualified refs)
--   * Teacher resolved ONLY from the RAW session token hashed with
--     the existing NEXORA mechanism:
--       encode(extensions.digest(p_session_token, 'sha256'), 'hex')
--     compared against teacher_sessions.token_hash
--   * Fail-closed gates: session exists, expires_at > now(),
--     teacher exists, teacher.active = true => else no data
--   * OWNERSHIP AUTHORITY IS students.teacher_id:
--       - main RPC:  students.student_id = p_student_id
--                    AND students.teacher_id = v_teacher_id
--       - child RPCs: child.student_id = students.student_id
--                    AND students.teacher_id = v_teacher_id
--     Students owned by another teacher, nonexistent students, and
--     legacy teacher_id IS NULL students (NULL never matches =)
--     return EMPTY (no existence leak).
--
-- FRONTEND COMPATIBILITY
--   * student-profile.html calls all 4 with
--       (p_session_token, p_student_id) and consumes
--       array-or-empty results. Signatures and exact live return
--       shapes are preserved (guarded), so the frontend stays
--       byte-for-byte untouched.
--
-- ROLLBACK (see file-end comments): function bodies only.
-- IDEMPOTENT: guarded create-or-replace; safe to re-run.
-- TRANSACTIONAL: any BLOCKED/error aborts with ZERO changes.
-- Run as ONE batch: Supabase Dashboard -> SQL Editor -> Run.
-- ============================================================

begin;

-- ============================================================
-- SECTION 1 — PRE-FLIGHT BLOCKED GUARDS (nothing changed yet)
-- ============================================================
do $preflight$
declare
    v_missing   text;
    v_digest    text;
    v_args      text;
    v_sig       text;
    v_live      text;
    v_want      text;
    v_n         int;
    r           record;
begin

    -- 1.1 Required table columns (exact presence, no assumptions).
    --     NOTE: ownership authority is students.teacher_id ONLY.
    --     Child tables are NOT required to carry teacher_id (the
    --     X.5.2 isolation never relies on child.teacher_id).
    v_missing := '';
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name='teacher_sessions'
                      and column_name='token_hash') then
        v_missing := v_missing || 'teacher_sessions.token_hash; ';
    end if;
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name='teacher_sessions'
                      and column_name='teacher_id') then
        v_missing := v_missing || 'teacher_sessions.teacher_id; ';
    end if;
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name='teacher_sessions'
                      and column_name='expires_at') then
        v_missing := v_missing || 'teacher_sessions.expires_at; ';
    end if;
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name='teachers'
                      and column_name='active') then
        v_missing := v_missing || 'teachers.active; ';
    end if;
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name='students'
                      and column_name='student_id') then
        v_missing := v_missing || 'students.student_id; ';
    end if;
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name='students'
                      and column_name='teacher_id') then
        v_missing := v_missing || 'students.teacher_id; ';
    end if;
    -- child tables must expose student_id (ownership join key)
    for r in
        select unnest(array['student_results','student_activities',
                            'student_certificates']) as t
    loop
        if not exists (select 1 from information_schema.columns
                        where table_schema='public' and table_name=r.t
                          and column_name='student_id') then
            v_missing := v_missing || r.t || '.student_id; ';
        end if;
    end loop;
    if v_missing <> '' then
        raise exception 'BLOCKED: missing required columns: %', v_missing;
    end if;

    -- 1.2 pgcrypto digest must live in the extensions schema
    --     (same pinning convention as X.4-A/X.5.1)
    select n.nspname into v_digest
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where p.proname = 'digest'
       and n.nspname in ('extensions', 'public')
     limit 1;

    if v_digest is null then
        raise exception 'BLOCKED: extensions.digest not found in schemas (extensions|public). Cannot hash session tokens.';
    end if;
    if v_digest <> 'extensions' then
        raise exception 'BLOCKED: digest found in schema "%" instead of "extensions". Session hashing convention differs — investigate before X.5.2.', v_digest;
    end if;

    -- 1.3 token_hash must be a text-type column (hex digest storage)
    if not exists (
        select 1 from information_schema.columns
         where table_schema='public' and table_name='teacher_sessions'
           and column_name='token_hash'
           and data_type in ('text','character varying','character')
    ) then
        raise exception 'BLOCKED: teacher_sessions.token_hash is not a text-type column — hashing storage convention differs.';
    end if;

    -- 1.4 EXACT signature guard: identity args EXACTLY
    --     (p_session_token text, p_student_id text), NO overloads.
    v_n := 0;
    select count(*) into v_n from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public' and p.proname='get_teacher_student_by_session';
    if v_n <> 1 then
        raise exception 'BLOCKED: get_teacher_student_by_session has % overloads — expected exactly 1.', v_n;
    end if;

    v_n := 0;
    select count(*) into v_n from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public' and p.proname='get_teacher_student_results_by_session';
    if v_n <> 1 then
        raise exception 'BLOCKED: get_teacher_student_results_by_session has % overloads — expected exactly 1.', v_n;
    end if;

    v_n := 0;
    select count(*) into v_n from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public' and p.proname='get_teacher_student_activities_by_session';
    if v_n <> 1 then
        raise exception 'BLOCKED: get_teacher_student_activities_by_session has % overloads — expected exactly 1.', v_n;
    end if;

    v_n := 0;
    select count(*) into v_n from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public' and p.proname='get_teacher_student_certificates_by_session';
    if v_n <> 1 then
        raise exception 'BLOCKED: get_teacher_student_certificates_by_session has % overloads — expected exactly 1.', v_n;
    end if;

    v_args := null;
    select pg_catalog.pg_get_function_identity_arguments(p.oid) into v_args
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public' and p.proname='get_teacher_student_by_session';
    if v_args <> 'p_session_token text, p_student_id text' then
        raise exception 'BLOCKED: get_teacher_student_by_session live args (%) differ from required (p_session_token text, p_student_id text).', v_args;
    end if;

    v_args := null;
    select pg_catalog.pg_get_function_identity_arguments(p.oid) into v_args
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public' and p.proname='get_teacher_student_results_by_session';
    if v_args <> 'p_session_token text, p_student_id text' then
        raise exception 'BLOCKED: get_teacher_student_results_by_session live args (%) differ from required.', v_args;
    end if;

    v_args := null;
    select pg_catalog.pg_get_function_identity_arguments(p.oid) into v_args
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public' and p.proname='get_teacher_student_activities_by_session';
    if v_args <> 'p_session_token text, p_student_id text' then
        raise exception 'BLOCKED: get_teacher_student_activities_by_session live args (%) differ from required.', v_args;
    end if;

    v_args := null;
    select pg_catalog.pg_get_function_identity_arguments(p.oid) into v_args
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public' and p.proname='get_teacher_student_certificates_by_session';
    if v_args <> 'p_session_token text, p_student_id text' then
        raise exception 'BLOCKED: get_teacher_student_certificates_by_session live args (%) differ from required.', v_args;
    end if;

    -- 1.5 LITERAL RETURN-CONTRACT GUARDS (verified live contracts).
    --     Builds each function's live signature as
    --     'name|col:type|col:type|...' and compares it to the exact
    --     verified contract. Any difference in column count, names,
    --     order or types => BLOCK before any CREATE OR REPLACE.
    --
    -- Contract 1 — get_teacher_student_by_session
    v_want := 'get_teacher_student_by_session'
           || '|id:uuid|student_id:text|name:text|phone:text'
           || '|parent_phone:text|created_at:timestamptz'
           || '|last_activity:timestamptz';
    select 'get_teacher_student_by_session'
           || coalesce('|' || string_agg(
                quote_ident(a.attname) || ':' || format_type(a.atttypid, a.atttypmod),
                '|' order by a.attnum), '')
      into v_live
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      join pg_catalog.pg_type t on t.oid = p.prorettype
      join pg_catalog.pg_class c on c.oid = t.typrelid
      join pg_catalog.pg_attribute a
        on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
     where n.nspname='public' and p.proname='get_teacher_student_by_session';
    if v_live is null or v_live <> v_want then
        raise exception 'BLOCKED: live return contract of get_teacher_student_by_session is [%] but the verified contract requires [%].', v_live, v_want;
    end if;

    -- Contract 2 — get_teacher_student_results_by_session
    v_want := 'get_teacher_student_results_by_session'
           || '|id:uuid|result_id:text|student_id:text|type:text'
           || '|grade:integer|unit:integer|title:text|correct:integer'
           || '|total:integer|percentage:integer|completed_at:timestamptz';
    select 'get_teacher_student_results_by_session'
           || coalesce('|' || string_agg(
                quote_ident(a.attname) || ':' || format_type(a.atttypid, a.atttypmod),
                '|' order by a.attnum), '')
      into v_live
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      join pg_catalog.pg_type t on t.oid = p.prorettype
      join pg_catalog.pg_class c on c.oid = t.typrelid
      join pg_catalog.pg_attribute a
        on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
     where n.nspname='public' and p.proname='get_teacher_student_results_by_session';
    if v_live is null or v_live <> v_want then
        raise exception 'BLOCKED: live return contract of get_teacher_student_results_by_session is [%] but the verified contract requires [%].', v_live, v_want;
    end if;

    -- Contract 3 — get_teacher_student_activities_by_session
    v_want := 'get_teacher_student_activities_by_session'
           || '|id:uuid|student_id:text|activity_type:text|page:text'
           || '|details:jsonb|created_at:timestamptz';
    select 'get_teacher_student_activities_by_session'
           || coalesce('|' || string_agg(
                quote_ident(a.attname) || ':' || format_type(a.atttypid, a.atttypmod),
                '|' order by a.attnum), '')
      into v_live
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      join pg_catalog.pg_type t on t.oid = p.prorettype
      join pg_catalog.pg_class c on c.oid = t.typrelid
      join pg_catalog.pg_attribute a
        on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
     where n.nspname='public' and p.proname='get_teacher_student_activities_by_session';
    if v_live is null or v_live <> v_want then
        raise exception 'BLOCKED: live return contract of get_teacher_student_activities_by_session is [%] but the verified contract requires [%].', v_live, v_want;
    end if;

    -- Contract 4 — get_teacher_student_certificates_by_session
    v_want := 'get_teacher_student_certificates_by_session'
           || '|id:uuid|certificate_id:text|result_id:text|student_id:text'
           || '|student_name:text|teacher_name:text|teacher_image:text'
           || '|assessment_name:text|score:integer|message:text'
           || '|date:text|created_at:timestamptz';
    select 'get_teacher_student_certificates_by_session'
           || coalesce('|' || string_agg(
                quote_ident(a.attname) || ':' || format_type(a.atttypid, a.atttypmod),
                '|' order by a.attnum), '')
      into v_live
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      join pg_catalog.pg_type t on t.oid = p.prorettype
      join pg_catalog.pg_class c on c.oid = t.typrelid
      join pg_catalog.pg_attribute a
        on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
     where n.nspname='public' and p.proname='get_teacher_student_certificates_by_session';
    if v_live is null or v_live <> v_want then
        raise exception 'BLOCKED: live return contract of get_teacher_student_certificates_by_session is [%] but the verified contract requires [%].', v_live, v_want;
    end if;

    raise notice 'X.5.2 pre-flight OK: schema, digest, signatures and all 4 verified return contracts match literally.';
end
$preflight$;

-- ============================================================
-- SECTION 2 — RPC 1: get_teacher_student_by_session
--   VERIFIED LIVE CONTRACT preserved exactly (7 columns).
--   Hardening: session/expiry/active gates + ownership filter
--   (students.teacher_id = v_teacher_id). Unknown, foreign-owned
--   and legacy NULL-owner students are indistinguishable: EMPTY.
-- ============================================================
create or replace function public.get_teacher_student_by_session(
    p_session_token text,
    p_student_id    text
)
returns table (
    id            uuid,
    student_id    text,
    name          text,
    phone         text,
    parent_phone  text,
    created_at    timestamptz,
    last_activity timestamptz
)
language plpgsql
security definer
volatile
set search_path = ''
as $fn$
declare
    v_teacher_id text;
    v_expires_at timestamptz;
    v_active     boolean;
begin
    -- Resolve teacher ONLY from the validated session
    -- (raw token hashed exactly as create_teacher_session stores it).
    select ts.teacher_id::text, ts.expires_at, t.active
      into v_teacher_id, v_expires_at, v_active
      from public.teacher_sessions ts
      join public.teachers t
        on t.teacher_id::text = ts.teacher_id::text
     where ts.token_hash = encode(extensions.digest(p_session_token, 'sha256'), 'hex')
     limit 1;

    -- Fail-closed gates (no data on any failure)
    if v_teacher_id is null then
        return;                       -- unknown/orphaned session
    end if;
    if v_expires_at is not null and v_expires_at <= now() then
        return;                       -- expired session
    end if;
    if v_active is not true then
        return;                       -- inactive teacher
    end if;

    -- OWNERSHIP GATE: students.student_id = p_student_id
    --                  AND students.teacher_id = v_teacher_id
    -- Nonexistent, foreign-owned and legacy NULL-owner students
    -- all produce an empty result (no existence leak).
    return query
        select s.id,
               s.student_id::text,
               s.name::text,
               s.phone::text,
               s.parent_phone::text,
               s.created_at,
               s.last_activity
          from public.students s
         where s.student_id::text = p_student_id
           and s.teacher_id::text = v_teacher_id
         limit 1;
end;
$fn$;

-- ============================================================
-- SECTION 3 — RPC 2: get_teacher_student_results_by_session
--   VERIFIED LIVE CONTRACT preserved exactly (11 columns).
--   Ownership enforced through the PARENT student:
--     students.student_id = student_results.student_id
--     AND students.teacher_id = v_teacher_id
--   never through student_results.student_id alone.
-- ============================================================
create or replace function public.get_teacher_student_results_by_session(
    p_session_token text,
    p_student_id    text
)
returns table (
    id           uuid,
    result_id    text,
    student_id   text,
    type         text,
    grade        integer,
    unit         integer,
    title        text,
    correct      integer,
    total        integer,
    percentage   integer,
    completed_at timestamptz
)
language plpgsql
security definer
volatile
set search_path = ''
as $fn$
declare
    v_teacher_id text;
    v_expires_at timestamptz;
    v_active     boolean;
begin
    select ts.teacher_id::text, ts.expires_at, t.active
      into v_teacher_id, v_expires_at, v_active
      from public.teacher_sessions ts
      join public.teachers t
        on t.teacher_id::text = ts.teacher_id::text
     where ts.token_hash = encode(extensions.digest(p_session_token, 'sha256'), 'hex')
     limit 1;

    if v_teacher_id is null then
        return;
    end if;
    if v_expires_at is not null and v_expires_at <= now() then
        return;
    end if;
    if v_active is not true then
        return;
    end if;

    return query
        select sr.id,
               sr.result_id::text,
               sr.student_id::text,
               sr.type::text,
               sr.grade,
               sr.unit,
               sr.title::text,
               sr.correct,
               sr.total,
               sr.percentage,
               sr.completed_at
          from public.student_results sr
          join public.students s
            on s.student_id::text = sr.student_id::text
         where sr.student_id::text = p_student_id
           and s.teacher_id::text = v_teacher_id
         order by sr.completed_at desc nulls last;
end;
$fn$;

-- ============================================================
-- SECTION 4 — RPC 3: get_teacher_student_activities_by_session
--   VERIFIED LIVE CONTRACT preserved exactly (6 columns).
--   Ownership: student_activities.student_id = students.student_id
--              AND students.teacher_id = v_teacher_id
-- ============================================================
create or replace function public.get_teacher_student_activities_by_session(
    p_session_token text,
    p_student_id    text
)
returns table (
    id            uuid,
    student_id    text,
    activity_type text,
    page          text,
    details       jsonb,
    created_at    timestamptz
)
language plpgsql
security definer
volatile
set search_path = ''
as $fn$
declare
    v_teacher_id text;
    v_expires_at timestamptz;
    v_active     boolean;
begin
    select ts.teacher_id::text, ts.expires_at, t.active
      into v_teacher_id, v_expires_at, v_active
      from public.teacher_sessions ts
      join public.teachers t
        on t.teacher_id::text = ts.teacher_id::text
     where ts.token_hash = encode(extensions.digest(p_session_token, 'sha256'), 'hex')
     limit 1;

    if v_teacher_id is null then
        return;
    end if;
    if v_expires_at is not null and v_expires_at <= now() then
        return;
    end if;
    if v_active is not true then
        return;
    end if;

    return query
        select sa.id,
               sa.student_id::text,
               sa.activity_type::text,
               sa.page::text,
               sa.details,
               sa.created_at
          from public.student_activities sa
          join public.students s
            on s.student_id::text = sa.student_id::text
         where sa.student_id::text = p_student_id
           and s.teacher_id::text = v_teacher_id
         order by sa.created_at desc nulls last;
end;
$fn$;

-- ============================================================
-- SECTION 5 — RPC 4: get_teacher_student_certificates_by_session
--   VERIFIED LIVE CONTRACT preserved exactly (12 columns).
--   Ownership: student_certificates.student_id = students.student_id
--              AND students.teacher_id = v_teacher_id
-- ============================================================
create or replace function public.get_teacher_student_certificates_by_session(
    p_session_token text,
    p_student_id    text
)
returns table (
    id              uuid,
    certificate_id  text,
    result_id       text,
    student_id      text,
    student_name    text,
    teacher_name    text,
    teacher_image   text,
    assessment_name text,
    score           integer,
    message         text,
    date            text,
    created_at      timestamptz
)
language plpgsql
security definer
volatile
set search_path = ''
as $fn$
declare
    v_teacher_id text;
    v_expires_at timestamptz;
    v_active     boolean;
begin
    select ts.teacher_id::text, ts.expires_at, t.active
      into v_teacher_id, v_expires_at, v_active
      from public.teacher_sessions ts
      join public.teachers t
        on t.teacher_id::text = ts.teacher_id::text
     where ts.token_hash = encode(extensions.digest(p_session_token, 'sha256'), 'hex')
     limit 1;

    if v_teacher_id is null then
        return;
    end if;
    if v_expires_at is not null and v_expires_at <= now() then
        return;
    end if;
    if v_active is not true then
        return;
    end if;

    return query
        select sc.id,
               sc.certificate_id::text,
               sc.result_id::text,
               sc.student_id::text,
               sc.student_name::text,
               sc.teacher_name::text,
               sc.teacher_image::text,
               sc.assessment_name::text,
               sc.score,
               sc.message::text,
               sc.date::text,
               sc.created_at
          from public.student_certificates sc
          join public.students s
            on s.student_id::text = sc.student_id::text
         where sc.student_id::text = p_student_id
           and s.teacher_id::text = v_teacher_id
         order by sc.created_at desc nulls last;
end;
$fn$;

-- ============================================================
-- SECTION 6 — GRANTS (re-assert the same public API; no table
--             grants touched)
-- ============================================================
revoke all on function public.get_teacher_student_by_session(text, text) from public;
grant  execute on function public.get_teacher_student_by_session(text, text) to anon, authenticated;

revoke all on function public.get_teacher_student_results_by_session(text, text) from public;
grant  execute on function public.get_teacher_student_results_by_session(text, text) to anon, authenticated;

revoke all on function public.get_teacher_student_activities_by_session(text, text) from public;
grant  execute on function public.get_teacher_student_activities_by_session(text, text) to anon, authenticated;

revoke all on function public.get_teacher_student_certificates_by_session(text, text) from public;
grant  execute on function public.get_teacher_student_certificates_by_session(text, text) to anon, authenticated;

-- ============================================================
-- SECTION 7 — POST-MIGRATION PROPERTY VERIFICATION (metadata only)
--   Structural guarantees: definer, pinned search_path, no
--   teacher_id OUT column, no overloads. Any failure aborts.
-- ============================================================
do $postcheck$
declare
    r      record;
    v_n    int;
    v_cfg  text;
begin
    -- exactly 4 functions, 1 overload each
    select count(*) into v_n from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('get_teacher_student_by_session',
                         'get_teacher_student_results_by_session',
                         'get_teacher_student_activities_by_session',
                         'get_teacher_student_certificates_by_session');
    if v_n <> 4 then
        raise exception 'SANITY FAILED: expected exactly 4 RPCs, found %', v_n;
    end if;

    for r in
        select p.proname, p.prosecdef, p.proconfig, p.proargnames
          from pg_catalog.pg_proc p
          join pg_catalog.pg_namespace n on n.oid = p.pronamespace
         where n.nspname='public'
           and p.proname in ('get_teacher_student_by_session',
                             'get_teacher_student_results_by_session',
                             'get_teacher_student_activities_by_session',
                             'get_teacher_student_certificates_by_session')
    loop
        if r.prosecdef is not true then
            raise exception 'SANITY FAILED: % is not SECURITY DEFINER', r.proname;
        end if;
        v_cfg := coalesce(r.proconfig::text, '');
        if v_cfg not like '%search_path=%' then
            raise exception 'SANITY FAILED: % search_path not pinned (%)', r.proname, v_cfg;
        end if;
        if 'teacher_id' = any (r.proargnames) then
            raise exception 'LEAK: %.output exposes teacher_id', r.proname;
        end if;
        raise notice 'X.5.2 postcheck OK: % (definer, pinned, no leak)', r.proname;
    end loop;
end
$postcheck$;

commit;

-- ============================================================
-- ROLLBACK NOTES (comments only — nothing executes)
--   * Affected functions: the 4 student-profile RPCs above.
--   * This migration changes FUNCTION BODIES ONLY: no tables,
--     columns, rows, grants-on-tables, RLS or session mechanics.
--   * Because the previous bodies are not stored in this repo,
--     exact byte-level rollback requires the previous definitions
--     to be preserved separately BEFORE execution (e.g. capture
--     pg_get_functiondef output in SQL Editor and save it).
--   * Behavioral rollback: signatures and return shapes are
--     unchanged, so the frontend runs identically against either
--     version; re-running the saved previous bodies via CREATE OR
--     REPLACE restores pre-X.5.2 behavior with zero downtime.
-- ============================================================
-- END OF X.5.2 MIGRATION
-- Post-execution verification: run the companion READ-ONLY file
--   supabase/migrations/20260910_phaseX5_2_verification.sql
-- ============================================================
