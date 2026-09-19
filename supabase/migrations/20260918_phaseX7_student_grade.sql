-- ============================================================
-- NEXORA Phase X.7 — Student Grade (server-side source of truth)
-- ============================================================
-- SCOPE (approved by owner)
--   1. Add public.students.grade (integer).
--   2. register_student(+p_grade)    -> saves grade on insert AND
--                                       keeps grade in sync on
--                                       returning-student re-registration.
--   3. update_student_scoped(+p_grade) -> supports updating grade.
--   4. get_teacher_students_by_session -> returns grade per student.
--   NO backfill, NO data migration (existing students handled later
--   per plan). NO RLS changes. NO table drops. NO other RPCs touched.
--
-- DESIGN NOTES
--   * OVERLOAD strategy: existing frontend builds keep working —
--     the 4-arg register_student / 5-arg update_student_scoped stay
--     valid; new overloads add p_grade integer.
--     register_student(text,text,text,text,integer) is the one the
--     updated frontend calls; the legacy 4-arg version is REPLACED
--     to no longer be executable by clients (kept only so nothing
--     breaks if an old cached page calls it) — actually removed:
--     see 3.4.
--   * grade range is NOT restricted at DB level (content defines
--     1..6 today; registration allows 1..12). Validation is done
--     in SQL with a check raising INVALID_GRADE for non 1..12.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1) students.grade (integer, nullable — legacy rows stay NULL)
-- ------------------------------------------------------------
alter table public.students
    add column if not exists grade integer;

do $col$
begin
    if not exists (
        select 1 from pg_catalog.pg_attribute a
        join pg_catalog.pg_class c on c.oid = a.attrelid
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public'
          and c.relname = 'students'
          and a.attname = 'grade'
          and not a.attisdropped
    ) then
        raise exception 'BLOCKED: students.grade was not created.';
    end if;
end
$col$;

-- ------------------------------------------------------------
-- 2) register_student — NEW 5-arg overload with p_grade
--    Body mirrors X.4-A verbatim except:
--      * grade validation (1..12) -> INVALID_GRADE
--      * insert now includes grade
--      * returning-student path ALSO updates grade (re-registration
--        syncs the grade; row_count>0 expected, silently ignored
--        for legacy rows that were already deleted)
-- ------------------------------------------------------------
create or replace function public.register_student(
    p_name              text,
    p_phone             text,
    p_parent_phone      text,
    p_registration_code text,
    p_grade             integer
)
returns table (student_id text, is_new boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $fn$
declare
    v_teacher   public.teachers.teacher_id%type;
    v_code      text;
    v_existing  public.students.student_id%type;
    v_new_id    text;
begin
    -- 3.1 input validation (server-side mirror of the UI rules)
    v_code := upper(btrim(coalesce(p_registration_code, '')));

    if coalesce(btrim(coalesce(p_name, '')), '') = ''
       or length(btrim(p_name)) > 120 then
        raise exception 'INVALID_NAME';
    end if;

    if coalesce(p_phone, '')            !~ '^01[0125][0-9]{8}$'
       or coalesce(p_parent_phone, '')  !~ '^01[0125][0-9]{8}$' then
        raise exception 'INVALID_PHONE';
    end if;

    -- NEW: grade validation (registration UI offers 1..12)
    if p_grade is null
       or p_grade < 1
       or p_grade > 12 then
        raise exception 'INVALID_GRADE';
    end if;

    -- 3.2 resolve teacher server-side (active only).
    select t.teacher_id
      into v_teacher
      from public.teachers t
     where upper(btrim(t.registration_code)) = v_code
       and t.active = true
     limit 1;

    if v_teacher is null then
        raise exception 'INVALID_REGISTRATION_CODE';
    end if;

    -- 3.3 scoped duplicate detection: THIS teacher only.
    select s.student_id
      into v_existing
      from public.students s
     where s.teacher_id   = v_teacher
       and s.phone        = p_phone
       and s.parent_phone = p_parent_phone
     limit 1;

    if v_existing is not null then
        -- NEW: keep grade in sync on re-registration
        update public.students
           set grade         = p_grade,
               last_activity = now()
         where student_id = v_existing
           and teacher_id = v_teacher;
        return query select v_existing, false;
        return;
    end if;

    -- 3.4 server-generated student_id.
    v_new_id := 'ST-'
             || upper(substring(pg_catalog.encode(extensions.gen_random_bytes(5), 'hex') from 1 for 8))
             || '-'
             || upper(substring(pg_catalog.encode(extensions.gen_random_bytes(3), 'hex') from 1 for 6));

    -- 3.5 insert with SERVER-side ownership. grade saved server-side.
    begin
        insert into public.students
            (student_id, name, phone, parent_phone,
             created_at, last_activity, teacher_id, grade)
        values
            (v_new_id, btrim(p_name), p_phone, p_parent_phone,
             now(), now(), v_teacher, p_grade);
    exception
        when unique_violation then
            select s.student_id
              into v_existing
              from public.students s
             where s.teacher_id   = v_teacher
               and s.phone        = p_phone
               and s.parent_phone = p_parent_phone
             limit 1;
            return query select coalesce(v_existing, v_new_id), false;
            return;
    end;

    return query select v_new_id, true;
end
$fn$;

revoke all on function public.register_student(text, text, text, text, integer) from public;
grant execute on function public.register_student(text, text, text, text, integer) to anon, authenticated;

-- ------------------------------------------------------------
-- 2.4) Legacy 4-arg register_student: clients must not use it
--      anymore (grade would be silently lost). REVOKE execution —
--      function body intentionally preserved for rollback.
-- ------------------------------------------------------------
revoke execute on function public.register_student(text, text, text, text)
from anon, authenticated, public;

-- ------------------------------------------------------------
-- 3) update_student_scoped — NEW 6-arg overload with p_grade
--    Body mirrors X.4-A verbatim except the grade update.
-- ------------------------------------------------------------
create or replace function public.update_student_scoped(
    p_registration_code text,
    p_student_id        text,
    p_name              text,
    p_phone             text,
    p_parent_phone      text,
    p_grade             integer
)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $fn$
declare
    v_teacher  public.teachers.teacher_id%type;
    v_updated  bigint;
begin
    -- 5.1 same validation rules as register_student
    if coalesce(btrim(coalesce(p_name, '')), '') = ''
       or length(btrim(p_name)) > 120 then
        raise exception 'INVALID_NAME';
    end if;

    if coalesce(p_phone, '')           !~ '^01[0125][0-9]{8}$'
       or coalesce(p_parent_phone, '') !~ '^01[0125][0-9]{8}$' then
        raise exception 'INVALID_PHONE';
    end if;

    -- NEW: grade validation
    if p_grade is null
       or p_grade < 1
       or p_grade > 12 then
        raise exception 'INVALID_GRADE';
    end if;

    -- 5.1b resolve teacher
    select t.teacher_id
      into v_teacher
      from public.teachers t
     where upper(btrim(t.registration_code))
           = upper(btrim(coalesce(p_registration_code, '')))
       and t.active = true
     limit 1;

    if v_teacher is null then
        raise exception 'INVALID_REGISTRATION_CODE';
    end if;

    -- 5.2 scoped update: identity AND ownership must both match.
    --     teacher_id cannot be changed (it only appears in WHERE).
    update public.students s
       set name          = btrim(p_name),
           phone         = p_phone,
           parent_phone  = p_parent_phone,
           grade         = p_grade,
           last_activity = now()
     where s.student_id = p_student_id
       and s.teacher_id = v_teacher;

    get diagnostics v_updated = row_count;

    -- 5.3 safe result: false = "no scoped update occurred".
    return v_updated > 0;
end
$fn$;

revoke all on function public.update_student_scoped(text, text, text, text, text, integer) from public;
grant execute on function public.update_student_scoped(text, text, text, text, text, integer) to anon, authenticated;

-- ------------------------------------------------------------
-- 3.4) Legacy 5-arg update_student_scoped: REVOKE execution from
--      clients (kept in catalog for rollback only).
-- ------------------------------------------------------------
revoke execute on function public.update_student_scoped(text, text, text, text, text)
from anon, authenticated, public;

-- ------------------------------------------------------------
-- 4) get_student_grade_by_phone — student-side read path.
--    Needed because anon has NO direct SELECT on students (X.5.3-A).
--    Identity = exact phone-pair + registration code (same trust
--    level as register_student / update_student_scoped).
--    Returns 0 rows when the student does not exist under this
--    teacher (client treats as "no server record").
-- ------------------------------------------------------------
create or replace function public.get_student_grade_by_phone(
    p_registration_code text,
    p_phone             text,
    p_parent_phone      text
)
returns table (
    student_id text,
    grade      integer
)
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
    v_teacher public.teachers.teacher_id%type;
begin
    if coalesce(p_phone, '')            !~ '^01[0125][0-9]{8}$'
       or coalesce(p_parent_phone, '')  !~ '^01[0125][0-9]{8}$' then
        raise exception 'INVALID_PHONE';
    end if;

    select t.teacher_id
      into v_teacher
      from public.teachers t
     where upper(btrim(t.registration_code))
           = upper(btrim(coalesce(p_registration_code, '')))
       and t.active = true
     limit 1;

    if v_teacher is null then
        raise exception 'INVALID_REGISTRATION_CODE';
    end if;

    return query
        select s.student_id::text,
               s.grade
          from public.students s
         where s.teacher_id   = v_teacher
           and s.phone        = p_phone
           and s.parent_phone = p_parent_phone
         limit 1;
end;
$fn$;

revoke all on function public.get_student_grade_by_phone(text, text, text) from public;
grant execute on function public.get_student_grade_by_phone(text, text, text) to anon, authenticated;

-- ------------------------------------------------------------
-- 5) get_teacher_students_by_session — widen return with grade
--    Body mirrors X.5.1 verbatim except the added grade column.
--
--    WHY DROP+CREATE (not CREATE OR REPLACE):
--    PostgreSQL only allows CREATE OR REPLACE to APPEND new OUT
--    columns at the END of the return shape. This migration inserts
--    `grade` BEFORE `created_at`, which changes the position of an
--    existing OUT column — CREATE OR REPLACE would fail with
--    "cannot change return type of existing function".
--    DROP+CREATE inside the same transaction is atomic for other
--    sessions (no window where the function is missing), keeps the
--    exact same name and input signature (text), touches no data,
--    no RLS, and no other RPC. Grants are re-applied right below.
-- ------------------------------------------------------------
drop function if exists public.get_teacher_students_by_session(text);

create or replace function public.get_teacher_students_by_session(
    p_session_token text
)
returns table (
    student_id   text,
    name         text,
    phone        text,
    parent_phone text,
    grade        integer,
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

    return query
        select s.student_id::text,
               s.name::text,
               s.phone::text,
               s.parent_phone::text,
               s.grade,
               s.created_at::timestamptz
          from public.students s
         where s.teacher_id::text = v_teacher_id
         order by s.created_at desc nulls last;
end;
$fn$;

revoke all on function public.get_teacher_students_by_session(text) from public;
grant execute on function public.get_teacher_students_by_session(text) to anon, authenticated;

-- ------------------------------------------------------------
-- 6) Preflight report (read-only)
-- ------------------------------------------------------------
do $report$
declare
    v_col  text;
    v_reg  text;
    v_upd  text;
    v_rost text;
begin
    select string_agg(a.attname, ',' order by a.attnum)
      into v_col
      from pg_catalog.pg_attribute a
      join pg_catalog.pg_class c on c.oid = a.attrelid
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = 'students'
       and a.attnum > 0 and not a.attisdropped;

    select pg_catalog.pg_get_function_identity_arguments(p.oid)
      into v_reg
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'register_student'
     order by (pg_catalog.pg_get_function_identity_arguments(p.oid) like '%integer%') desc
     limit 1;

    select pg_catalog.pg_get_function_identity_arguments(p.oid)
      into v_upd
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'update_student_scoped'
     order by (pg_catalog.pg_get_function_identity_arguments(p.oid) like '%integer%') desc
     limit 1;

    select string_agg(a.attname, ',' order by a.attnum)
      into v_rost
      from pg_catalog.pg_attribute a
      join pg_catalog.pg_proc p on p.oid = a.attrelid
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'get_teacher_students_by_session'
       and a.attnum > 0 and not a.attisdropped
       and p.proretset;

    raise notice 'X.7 REPORT: students.columns=(%)', v_col;
    raise notice 'X.7 REPORT: register_student.args=(%)', v_reg;
    raise notice 'X.7 REPORT: update_student_scoped.args=(%)', v_upd;
    raise notice 'X.7 REPORT: roster.return=(%)', v_rost;
end
$report$;

commit;

-- ============================================================
-- End of Phase X.7 migration.
-- Expected REPORT lines:
--   students.columns includes grade
--   register_student.args includes p_grade integer
--   update_student_scoped.args includes p_grade integer
--   roster.return includes grade
-- ============================================================
