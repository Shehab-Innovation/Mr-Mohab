-- ============================================================
-- NEXORA Phase X.8 — Teacher Dashboard deletes
--   (delete student + delete group, session-scoped)
-- ============================================================
-- SCOPE (approved by owner)
--   1. delete_teacher_student_by_session(token, student_id)
--        - deletes the student AND their child rows (results,
--          activities, certificates) + group memberships, all
--          gated by session ownership. Teacher-approved cascade.
--   2. delete_teacher_group_by_session(token, group_id)
--        - deletes the group's membership rows + the group itself.
--        - NEVER touches students rows (per owner requirement).
--
--   Both RPCs:
--     * Fail closed: unknown/expired session, inactive teacher,
--       foreign or nonexistent target -> no-op result (no leaks).
--     * SECURITY DEFINER + pinned search_path (same as X.5.x).
--     * Client-facing result: rows_deleted integer (0 = not found
--       / not mine; no existence disclosure across tenants).
--   NO RLS changes. No other RPCs touched. No data backfills.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- RPC 1 — delete_teacher_student_by_session
--   p_session_token text, p_student_id text
--   returns integer (total child+membership rows removed, so the
--   dashboard can show a precise audit line; the student row is
--   always removed when owned — result is 1 even with 0 children)
-- ------------------------------------------------------------
create or replace function public.delete_teacher_student_by_session(
    p_session_token text,
    p_student_id    text
)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $fn$
declare
    v_teacher_id   text;
    v_expires_at   timestamptz;
    v_active       boolean;
    v_owned        text;
    v_child_rows   bigint := 0;
begin
    -- Session gate (identical pattern to X.5.1 roster RPCs)
    select ts.teacher_id::text, ts.expires_at, t.active
      into v_teacher_id, v_expires_at, v_active
      from public.teacher_sessions ts
      join public.teachers t
        on t.teacher_id::text = ts.teacher_id::text
     where ts.token_hash = encode(extensions.digest(p_session_token, 'sha256'), 'hex')
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

    -- Ownership gate: the student MUST belong to this teacher.
    select s.student_id::text
      into v_owned
      from public.students s
     where s.student_id::text = p_student_id
       and s.teacher_id::text = v_teacher_id
     limit 1;

    if v_owned is null then
        return 0;   -- not found / not mine (no leak)
    end if;

    -- Child rows (owned by construction: teacher_id matches the
    -- student we just verified, but we gate explicitly anyway).
    delete from public.student_results sr
     where sr.student_id::text = v_owned
       and sr.teacher_id::text = v_teacher_id;
    get diagnostics v_child_rows = row_count;

    delete from public.student_activities sa
     where sa.student_id::text = v_owned
       and sa.teacher_id::text = v_teacher_id;
    get diagnostics v_child_rows = v_child_rows + row_count;

    delete from public.student_certificates sc
     where sc.student_id::text = v_owned
       and sc.teacher_id::text = v_teacher_id;
    get diagnostics v_child_rows = v_child_rows + row_count;

    -- Group memberships for this student (any group of this teacher)
    delete from public.group_students gs
     where gs.student_id::text = v_owned
       and gs.group_id in (
            select g.id from public.groups g
             where g.teacher_id::text = v_teacher_id
       );
    get diagnostics v_child_rows = v_child_rows + row_count;

    -- The student row itself
    delete from public.students s
     where s.student_id::text = v_owned
       and s.teacher_id::text = v_teacher_id;

    return v_child_rows + 1;
end;
$fn$;

revoke all on function public.delete_teacher_student_by_session(text, text) from public;
grant execute on function public.delete_teacher_student_by_session(text, text) to anon, authenticated;

-- ------------------------------------------------------------
-- RPC 2 — delete_teacher_group_by_session
--   p_session_token text, p_group_id text
--   returns integer (membership rows removed; 0 = not found/not
--   mine; 1 = group removed with no members)
--   NEVER deletes student rows.
-- ------------------------------------------------------------
create or replace function public.delete_teacher_group_by_session(
    p_session_token text,
    p_group_id      text
)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $fn$
declare
    v_teacher_id   text;
    v_expires_at   timestamptz;
    v_active       boolean;
    v_owned        text;
    v_member_rows  bigint := 0;
begin
    select ts.teacher_id::text, ts.expires_at, t.active
      into v_teacher_id, v_expires_at, v_active
      from public.teacher_sessions ts
      join public.teachers t
        on t.teacher_id::text = ts.teacher_id::text
     where ts.token_hash = encode(extensions.digest(p_session_token, 'sha256'), 'hex')
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

    -- Ownership gate: the group MUST belong to this teacher.
    select g.id::text
      into v_owned
      from public.groups g
     where g.id::text = p_group_id
       and g.teacher_id::text = v_teacher_id
     limit 1;

    if v_owned is null then
        return 0;   -- not found / not mine (no leak)
    end if;

    -- Membership rows for this group only (students untouched).
    delete from public.group_students gs
     where gs.group_id::text = v_owned;
    get diagnostics v_member_rows = row_count;

    -- The group row itself
    delete from public.groups g
     where g.id::text = v_owned
       and g.teacher_id::text = v_teacher_id;

    return v_member_rows + 1;
end;
$fn$;

revoke all on function public.delete_teacher_group_by_session(text, text) from public;
grant execute on function public.delete_teacher_group_by_session(text, text) to anon, authenticated;

-- ------------------------------------------------------------
-- Preflight report (read-only)
-- ------------------------------------------------------------
do $report$
declare
    v_fn1 text;
    v_fn2 text;
begin
    select pg_catalog.pg_get_function_identity_arguments(p.oid)
      into v_fn1
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'delete_teacher_student_by_session'
     limit 1;

    select pg_catalog.pg_get_function_identity_arguments(p.oid)
      into v_fn2
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'delete_teacher_group_by_session'
     limit 1;

    raise notice 'X.8 REPORT: delete_teacher_student_by_session.args=(%)', coalesce(v_fn1, 'MISSING');
    raise notice 'X.8 REPORT: delete_teacher_group_by_session.args=(%)', coalesce(v_fn2, 'MISSING');
end
$report$;

commit;

-- ============================================================
-- End of Phase X.8 migration.
-- Expected REPORT lines:
--   delete_teacher_student_by_session.args=(p_session_token text, p_student_id text)
--   delete_teacher_group_by_session.args=(p_session_token text, p_group_id text)
-- ============================================================
