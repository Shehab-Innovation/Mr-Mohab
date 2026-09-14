-- ============================================================
-- NEXORA — Phase X.5.1: POST-EXECUTION VERIFICATION (READ-ONLY)
-- Run AFTER "20260910_phaseX5_1_teacher_roster_rpcs.sql",
-- as a separate batch, in Supabase SQL Editor.
--
-- Contains ONLY SELECT statements. Nothing is modified.
-- Behavioral checks (SECTION F) use a REAL session token obtained
-- by logging into the teacher dashboard — no test data is created
-- by this file. If any check would require a WRITE, it is marked
-- MANUAL and its instructions are given as comments instead.
-- ============================================================

-- ############################################################
-- STEP 0 — ROW-COUNT SNAPSHOT (run BEFORE the migration, save
-- the numbers, run again AFTER, diff must be ZERO).
-- Baseline before X.5.1 (recorded): students=5 (3 legacy NULL +
-- 2 labeled test students), student_results=1,
-- student_activities=36+ (grows only via real student activity),
-- student_certificates=1, groups=0, group_students=0.
-- ############################################################
select 'students' t, count(*) from public.students
union all select 'student_results', count(*) from public.student_results
union all select 'student_activities', count(*) from public.student_activities
union all select 'student_certificates', count(*) from public.student_certificates
union all select 'groups', count(*) from public.groups
union all select 'group_students', count(*) from public.group_students
union all select 'teacher_sessions', count(*) from public.teacher_sessions
union all select 'teachers', count(*) from public.teachers
order by t;

-- ############################################################
-- SECTION A — RPC existence, signature, definer, volatility,
--             search_path pinning
-- EXPECTED (2 rows):
--   get_teacher_students_by_session        | p_session_token text
--   get_teacher_group_students_by_session  | p_session_token text, p_group_id text
--   prosecdef=true | provolatile=v | proconfig contains search_path
-- ############################################################
select p.proname,
       pg_catalog.pg_get_function_identity_arguments(p.oid) as args,
       pg_catalog.pg_get_function_result(p.oid)             as returns,
       p.prosecdef                                          as security_definer,
       p.provolatile                                        as volatility,
       p.proconfig::text                                    as config
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('get_teacher_students_by_session',
                     'get_teacher_group_students_by_session')
 order by p.proname;

-- ############################################################
-- SECTION B — EXECUTE grants on the two new RPCs
-- EXPECTED: anon + authenticated rows for BOTH, and NO 'PUBLIC'
-- ############################################################
select g.routine_name, g.grantee, g.privilege_type
  from information_schema.role_routine_grants g
 where g.routine_schema = 'public'
   and g.routine_name in ('get_teacher_students_by_session',
                          'get_teacher_group_students_by_session')
   and g.grantee in ('anon', 'authenticated', 'PUBLIC')
 order by g.routine_name, g.grantee;

-- ############################################################
-- SECTION C — Untouched RPCs still present (existence only;
-- this migration contains no statement targeting them)
-- EXPECTED: 6 rows (4 student-profile RPCs + 2 legacy globals)
-- ############################################################
select p.proname,
       pg_catalog.pg_get_function_identity_arguments(p.oid) as args,
       p.prosecdef as security_definer
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('get_teacher_student_by_session',
                     'get_teacher_student_results_by_session',
                     'get_teacher_student_activities_by_session',
                     'get_teacher_student_certificates_by_session',
                     'find_student_by_phone',
                     'update_student_by_phone')
 order by p.proname;

-- ############################################################
-- SECTION D — RLS unchanged (must be FALSE everywhere here;
-- RLS belongs to a later phase)
-- EXPECTED: relrowsecurity=false, relforcerowsecurity=false
-- ############################################################
select c.relname,
       c.relrowsecurity        as rls_enabled,
       c.relforcerowsecurity   as rls_forced
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and c.relname in ('students', 'student_results', 'student_activities',
                     'student_certificates', 'groups', 'group_students',
                     'teachers', 'teacher_sessions')
 order by c.relname;

-- ############################################################
-- SECTION E — Legacy NULL-owner students untouched
-- EXPECTED: exactly 3 rows, all with teacher_id NULL
-- (ST-MTUZQBUW-7FQ9YZ, ST-MTV0D654-OKWJP0, ST-MTVUS5X4-FMKI22)
-- ############################################################
select student_id, teacher_id
  from public.students
 where teacher_id is null
 order by student_id;

-- ############################################################
-- SECTION F — BEHAVIORAL CHECKS (read-only, need a REAL token)
--
-- How to obtain the raw token WITHOUT writing anything new:
--   Log into teacher-dashboard.html normally (this creates a
--   session row — an operation you already perform in daily use,
--   not synthetic test data). Then in DevTools:
--     sessionStorage.getItem('nexora_teacher_token')
--   Paste that value below in place of PASTE_RAW_TOKEN_HERE.
-- ############################################################

-- F.0 — raw token CTE (single place to paste)
-- with raw_token as (
--     select 'PASTE_RAW_TOKEN_HERE'::text as tok
-- )

-- F.1 — Ownership self-consistency: EVERY roster row belongs to
--       the session teacher. Empty diff = PASS.
-- with raw_token as (select 'PASTE_RAW_TOKEN_HERE'::text as tok)
-- select s.student_id
--   from public.get_teacher_students_by_session((select tok from raw_token)) r
--   join public.students s on s.student_id::text = r.student_id
--  where s.teacher_id::text <>
--        (select ts.teacher_id::text
--           from public.teacher_sessions ts
--          where ts.token = encode(extensions.digest((select tok from raw_token), 'sha256'), 'hex'));
-- EXPECTED: 0 rows

-- F.2 — Legacy NULL-owner exclusion: none of the 3 legacy IDs
--       may appear in the roster.
-- with raw_token as (select 'PASTE_RAW_TOKEN_HERE'::text as tok)
-- select r.student_id
--   from public.get_teacher_students_by_session((select tok from raw_token)) r
--  where r.student_id in ('ST-MTUZQBUW-7FQ9YZ','ST-MTV0D654-OKWJP0','ST-MTVUS5X4-FMKI22');
-- EXPECTED: 0 rows

-- F.3 — Foreign group fails closed: any group id NOT owned by
--       the session teacher (e.g. a random/nonexistent id) must
--       return an EMPTY set, not an error.
-- with raw_token as (select 'PASTE_RAW_TOKEN_HERE'::text as tok)
-- select * from public.get_teacher_group_students_by_session(
--     (select tok from raw_token), 'FOREIGN-GROUP-ID-SAMPLE');
-- EXPECTED: 0 rows

-- F.4 — Owned group consistency (only if at least one group
--       exists for this teacher): roster of the group must equal
--       the group_students join.
-- with raw_token as (select 'PASTE_RAW_TOKEN_HERE'::text as tok)
-- select r.student_id
--   from public.get_teacher_group_students_by_session(
--            (select tok from raw_token), 'PASTE_OWNED_GROUP_ID') r
--  where r.student_id not in (
--      select gs.student_id::text
--        from public.group_students gs
--       where gs.group_id::text = 'PASTE_OWNED_GROUP_ID');
-- EXPECTED: 0 rows

-- F.5 — INVALID TOKEN FAILS CLOSED (MANUAL, no data write):
--       Run this as a standalone statement; it MUST error with
--       INVALID_SESSION (HTTP 400 / SQLSTATE P0001).
--
-- select * from public.get_teacher_students_by_session('x51-invalid-token-probe');
--
-- Also verify the group RPC rejects the same way:
--
-- select * from public.get_teacher_group_students_by_session('x51-invalid-token-probe', 'whatever');

-- F.6 — EXPIRED SESSION FAILS CLOSED (MANUAL, optional):
--       Wait until your session's expires_at passes (or use an
--       old saved token), then re-run F.1's RPC statement.
--       EXPECTED: INVALID_SESSION error.

-- F.7 — CROSS-TEACHER ISOLATION (MANUAL, needs a second teacher
--       session if available, e.g. T-SECURITY-002):
--       From teacher B's session run F.1; the diff query already
--       proves B sees only B's students. Additionally:
--       select * from public.get_teacher_students_by_session(<teacher_B_token>);
--       EXPECTED: no student rows belonging to T-MOHAB-001.

-- ############################################################
-- SECTION G — NO TEACHER_ID LEAK CHECK (structural)
-- For RETURNS TABLE functions, proargnames holds the OUT column
-- names after the IN-argument names. The roster must expose NO
-- teacher_id column. This query FAILS (raises) if teacher_id
-- appears among the output columns of either RPC.
-- EXPECTED: 2 rows with the column lists shown; no exception.
-- ############################################################
do $g$
declare
    r record;
begin
    for r in
        select p.proname, p.proargnames
          from pg_catalog.pg_proc p
          join pg_catalog.pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname in ('get_teacher_students_by_session',
                             'get_teacher_group_students_by_session')
    loop
        if 'teacher_id' = any (r.proargnames) then
            raise exception 'LEAK: %.output exposes teacher_id', r.proname;
        end if;
        raise notice '% output columns: %', r.proname, r.proargnames;
    end loop;
end
$g$;
