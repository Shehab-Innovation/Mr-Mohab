-- ============================================================
-- NEXORA — Phase X.5.1: Teacher Roster Ownership RPCs (DB-ONLY)
-- Owner: Shehab Innovation
-- Date:  2026-09-10
-- Baseline: main @ d4c2eea (Phase X.4-A artifacts)
-- Depends on: X.2 + X.4-A executed (teacher_id columns, session
--             hashing mechanism, definer/grant conventions)
--
-- SCOPE (STRICT)
--   * Creates exactly TWO new SECURITY DEFINER RPCs:
--       1) public.get_teacher_students_by_session(text)
--       2) public.get_teacher_group_students_by_session(text, text)
--   * NO table/column/data changes. NO backfill. NO RLS.
--   * The 4 existing get_teacher_student_*_by_session RPCs are
--     NOT touched. Legacy find/update_student_by_phone are NOT
--     touched. No triggers are touched.
--   * Grants: EXECUTE on the two new functions only.
--
-- BEHAVIOR
--   * Teacher resolved server-side from the RAW session token,
--     hashed exactly as create_teacher_session does:
--       encode(extensions.digest(token, 'sha256'), 'hex')
--   * Fail-closed: unknown/expired session, or inactive teacher
--     => exception INVALID_SESSION.
--   * Roster returns ONLY students with teacher_id = resolved
--     teacher. Legacy NULL-teacher students stay excluded.
--   * Group-students RPC verifies group OWNERSHIP (groups.teacher_id
--     = resolved teacher). Foreign/nonexistent group => empty set
--     (no existence leak).
--
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
    v_missing        text;
    v_digest_schema  text;
    v_gref_col       text;
    v_fk_count       int;
    v_fn_args        text;
begin

    -- 1.1 Required columns (exact presence, no assumptions)
    v_missing := '';
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name='teacher_sessions'
                      and column_name='token') then
        v_missing := v_missing || 'teacher_sessions.token; ';
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
                      and column_name='teacher_id') then
        v_missing := v_missing || 'students.teacher_id; ';
    end if;
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name='students'
                      and column_name='student_id') then
        v_missing := v_missing || 'students.student_id; ';
    end if;
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name='groups'
                      and column_name='teacher_id') then
        v_missing := v_missing || 'groups.teacher_id; ';
    end if;
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name='group_students'
                      and column_name='group_id') then
        v_missing := v_missing || 'group_students.group_id; ';
    end if;
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name='group_students'
                      and column_name='student_id') then
        v_missing := v_missing || 'group_students.student_id; ';
    end if;
    if v_missing <> '' then
        raise exception 'BLOCKED: missing required columns: %', v_missing;
    end if;

    -- 1.2 pgcrypto digest must live in the extensions schema
    --     (same pinning convention as X.4-A gen_random_bytes)
    select n.nspname into v_digest_schema
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where p.proname = 'digest'
       and n.nspname in ('extensions', 'public')
     limit 1;

    if v_digest_schema is null then
        raise exception 'BLOCKED: extensions.digest not found in schemas (extensions|public). Cannot hash session tokens.';
    end if;
    if v_digest_schema <> 'extensions' then
        raise exception 'BLOCKED: digest found in schema "%" instead of "extensions". Session hashing convention differs — investigate before X.5.1.', v_digest_schema;
    end if;

    -- 1.3 Resolve the authoritative join key: the FK from
    --     group_students.group_id to groups.<column>.
    --     The dashboard passes group.id into p_group_id, and the
    --     live groups PK column name has never been catalog-verified
    --     in repo evidence — so we discover it from the FK, not guess.
    select count(*) into v_fk_count
      from information_schema.table_constraints tc
      join information_schema.constraint_column_usage ccu
        on ccu.constraint_name = tc.constraint_name
       and ccu.constraint_schema = tc.constraint_schema
      join information_schema.key_column_usage kcu
        on kcu.constraint_name = tc.constraint_name
       and kcu.constraint_schema = tc.constraint_schema
     where tc.constraint_type = 'FOREIGN KEY'
       and tc.table_schema = 'public'
       and tc.table_name = 'group_students'
       and kcu.column_name = 'group_id'
       and ccu.table_schema = 'public'
       and ccu.table_name = 'groups';

    if v_fk_count = 0 then
        raise exception 'BLOCKED: no FOREIGN KEY found from public.group_students(group_id) to public.groups. Cannot determine the authoritative group join key. Provide the FK evidence and re-run.';
    end if;
    if v_fk_count > 1 then
        raise exception 'BLOCKED: % foreign keys from group_students(group_id) to groups found — ambiguous join key. Resolve manually before X.5.1.', v_fk_count;
    end if;

    select ccu.column_name into v_gref_col
      from information_schema.table_constraints tc
      join information_schema.constraint_column_usage ccu
        on ccu.constraint_name = tc.constraint_name
       and ccu.constraint_schema = tc.constraint_schema
      join information_schema.key_column_usage kcu
        on kcu.constraint_name = tc.constraint_name
       and kcu.constraint_schema = tc.constraint_schema
     where tc.constraint_type = 'FOREIGN KEY'
       and tc.table_schema = 'public'
       and tc.table_name = 'group_students'
       and kcu.column_name = 'group_id'
       and ccu.table_schema = 'public'
       and ccu.table_name = 'groups'
     limit 1;

    raise notice 'group join key resolved from live FK: groups.% (= group_students.group_id)', v_gref_col;

    -- Persist the resolved key for the function bodies below by
    -- validating both candidate column names exist; the FK target
    -- column is used verbatim in the function SQL.
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name='groups'
                      and column_name = v_gref_col) then
        raise exception 'BLOCKED: FK target column groups.% not found in catalog.', v_gref_col;
    end if;

    -- The RPC body in SECTION 3 references the group PK literally as
    -- g.id (matching the value the dashboard sends: group.id).
    -- If the live FK targets a differently-named column, STOP here
    -- rather than ship a function that fails at first call.
    if v_gref_col <> 'id' then
        raise exception 'BLOCKED: groups join key resolved to "%", but the X.5.1 function body references groups.id. Reconcile the function body with the live schema before proceeding.';
    end if;

    -- 1.4 Signature-conflict guards: replace only if the existing
    --     function (if any) has the exact intended identity args.
    select pg_catalog.pg_get_function_identity_arguments(p.oid) into v_fn_args
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'get_teacher_students_by_session'
     limit 1;
    if v_fn_args is not null and v_fn_args <> 'p_session_token text' then
        raise exception 'BLOCKED: get_teacher_students_by_session already exists with args (%) — differs from intended signature.', v_fn_args;
    end if;

    v_fn_args := null;
    select pg_catalog.pg_get_function_identity_arguments(p.oid) into v_fn_args
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'get_teacher_group_students_by_session'
     limit 1;
    if v_fn_args is not null and v_fn_args <> 'p_session_token text, p_group_id text' then
        raise exception 'BLOCKED: get_teacher_group_students_by_session already exists with args (%) — differs from intended signature.', v_fn_args;
    end if;

end
$preflight$;

-- ============================================================
-- SECTION 2 — RPC 1: get_teacher_students_by_session
-- ============================================================
create or replace function public.get_teacher_students_by_session(
    p_session_token text
)
returns table (
    student_id   text,
    name         text,
    phone        text,
    parent_phone text,
    created_at   timestamptz
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
    -- Resolve teacher from the RAW token, hashed exactly as
    -- create_teacher_session stores it (extensions.digest).
    select ts.teacher_id::text, ts.expires_at, t.active
      into v_teacher_id, v_expires_at, v_active
      from public.teacher_sessions ts
      join public.teachers t
        on t.teacher_id::text = ts.teacher_id::text
     where ts.token = encode(extensions.digest(p_session_token, 'sha256'), 'hex')
     limit 1;

    -- Fail closed: unknown token / orphaned session / expired
    if v_teacher_id is null then
        raise exception 'INVALID_SESSION';
    end if;
    if v_expires_at is not null and v_expires_at <= now() then
        raise exception 'INVALID_SESSION';
    end if;
    if v_active is not true then
        raise exception 'INVALID_SESSION';
    end if;

    -- Ownership-isolated roster: ONLY this teacher's students.
    -- Legacy students with teacher_id IS NULL are excluded by
    -- construction (NULL <> anything).
    return query
        select s.student_id::text,
               s.name::text,
               s.phone::text,
               s.parent_phone::text,
               s.created_at::timestamptz
          from public.students s
         where s.teacher_id::text = v_teacher_id
         order by s.created_at desc nulls last;
end;
$fn$;

revoke all on function public.get_teacher_students_by_session(text) from public;
grant execute on function public.get_teacher_students_by_session(text) to anon, authenticated;

-- ============================================================
-- SECTION 3 — RPC 2: get_teacher_group_students_by_session
-- ============================================================
-- NOTE: the group join key below (g.<column>) is the FK target
-- resolved in SECTION 1.3. If the guard resolved a different
-- column than the one referenced here, the migration would have
-- BLOCKED before reaching this point. Keep both in sync if ever
-- edited manually.
create or replace function public.get_teacher_group_students_by_session(
    p_session_token text,
    p_group_id      text
)
returns table (
    student_id text,
    name       text
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
    v_group_key  text;
begin
    select ts.teacher_id::text, ts.expires_at, t.active
      into v_teacher_id, v_expires_at, v_active
      from public.teacher_sessions ts
      join public.teachers t
        on t.teacher_id::text = ts.teacher_id::text
     where ts.token = encode(extensions.digest(p_session_token, 'sha256'), 'hex')
     limit 1;

    if v_teacher_id is null then
        raise exception 'INVALID_SESSION';
    end if;
    if v_expires_at is not null and v_expires_at <= now() then
        raise exception 'INVALID_SESSION';
    end if;
    if v_active is not true then
        raise exception 'INVALID_SESSION';
    end if;

    -- Ownership gate: the requested group MUST belong to the
    -- session teacher. Nonexistent or foreign group => no row =>
    -- empty result (no existence leak).
    select g.id::text
      into v_group_key
      from public.groups g
     where g.id::text = p_group_id
       and g.teacher_id::text = v_teacher_id
     limit 1;

    if v_group_key is null then
        return;
    end if;

    return query
        select s.student_id::text,
               s.name::text
          from public.group_students gs
          join public.students s
            on s.student_id::text = gs.student_id::text
         where gs.group_id::text = v_group_key
         order by s.name asc nulls last;
end;
$fn$;

revoke all on function public.get_teacher_group_students_by_session(text, text) from public;
grant execute on function public.get_teacher_group_students_by_session(text, text) to anon, authenticated;

-- ============================================================
-- SECTION 4 — POST-MIGRATION SANITY (metadata only, no data)
-- ============================================================
do $sanity$
declare
    v_count int;
begin
    select count(*) into v_count
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('get_teacher_students_by_session',
                         'get_teacher_group_students_by_session');
    if v_count <> 2 then
        raise exception 'SANITY FAILED: expected exactly 2 new RPCs, found %', v_count;
    end if;
    raise notice 'X.5.1 sanity OK: both roster RPCs installed with definer/grants.';
end
$sanity$;

commit;

-- ============================================================
-- END OF X.5.1 MIGRATION
-- Post-execution verification: run the companion READ-ONLY file
--   supabase/migrations/20260910_phaseX5_1_verification.sql
-- ============================================================
