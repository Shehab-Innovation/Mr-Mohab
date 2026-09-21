-- ============================================================
-- NEXORA Phase X.9 — Student-side read of teacher evaluations
--   get_student_evaluations_by_phone(p_phone, p_parent_phone)
-- ============================================================
-- WHY (verified live):
--   * teacher_evaluations is RLS-protected with NO policy
--     (deny-all) and has NO anon SELECT grant -> the student
--     browser cannot read it directly.
--   * The only existing read RPC
--     (get_teacher_student_evaluations_by_session) requires a
--     TEACHER session token, which must never live in the
--     student browser.
--   * The Student Site's established login identity is the
--     phone + parent_phone pair (same trust model as the
--     existing find_existing_student RPC).
--
-- SCOPE: ONE additive read-only function. NO table changes,
--   NO RLS changes, NO changes to any existing RPC, NO schema
--   changes, NO data changes. Re-runnable (DROP IF EXISTS).
--
-- HOW TO RUN: Supabase Dashboard -> SQL Editor -> paste -> Run.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- Guard: expected columns must exist, else fail closed and
--        change nothing.
-- ------------------------------------------------------------
do $guard$
declare
    v_missing text := '';
begin
    if not exists (
        select 1 from information_schema.columns
         where table_schema = 'public'
           and table_name   = 'teacher_evaluations'
           and column_name  = 'evaluation_id'
           and data_type    = 'text'
    ) then
        v_missing := 'teacher_evaluations.evaluation_id (text)';
    end if;

    if v_missing = '' and not exists (
        select 1 from information_schema.columns
         where table_schema = 'public'
           and table_name   = 'teacher_evaluations'
           and column_name  = 'student_id'
           and data_type    = 'text'
    ) then
        v_missing := 'teacher_evaluations.student_id (text)';
    end if;

    if v_missing = '' and not exists (
        select 1 from information_schema.columns
         where table_schema = 'public'
           and table_name   = 'students'
           and column_name  = 'phone'
           and data_type    = 'text'
    ) then
        v_missing := 'students.phone (text)';
    end if;

    if v_missing = '' and not exists (
        select 1 from information_schema.columns
         where table_schema = 'public'
           and table_name   = 'students'
           and column_name  = 'parent_phone'
           and data_type    = 'text'
    ) then
        v_missing := 'students.parent_phone (text)';
    end if;

    if v_missing <> '' then
        raise exception 'BLOCKED: expected column % was not found. No changes committed.', v_missing;
    end if;
end
$guard$;

drop function if exists public.get_student_evaluations_by_phone(text, text);

create function public.get_student_evaluations_by_phone(
    p_phone        text,
    p_parent_phone text
)
returns table (
    evaluation_id text,
    title         text,
    evaluation    text,
    score         integer,
    max_score     integer,
    created_at    timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $fn$
begin
    -- Resolve the student by the SAME identity pair the Student
    -- Site already uses as its login credential. Unknown pair ->
    -- return nothing (fail closed, no existence leak).
    --
    -- NOTE: all students matching the pair are the SAME human
    -- (re-registrations), so returning evaluations across those
    -- rows stays within one person's own data.
    return query
    select te.evaluation_id::text,
           te.title::text,
           te.evaluation::text,
           te.score,
           te.max_score,
           te.created_at
      from public.teacher_evaluations te
     where te.student_id::text in (
            select s.student_id::text
              from public.students s
             where s.phone::text        = p_phone
               and s.parent_phone::text = p_parent_phone
           )
     order by te.created_at desc;
end;
$fn$;

revoke all on function public.get_student_evaluations_by_phone(text, text) from public;
grant execute on function public.get_student_evaluations_by_phone(text, text) to anon, authenticated;

commit;

-- ============================================================
-- End of Phase X.9 migration.
-- ============================================================
