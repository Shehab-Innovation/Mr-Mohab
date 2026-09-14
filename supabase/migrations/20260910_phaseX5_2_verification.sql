-- ============================================================
-- NEXORA — Phase X.5.2: POST-EXECUTION VERIFICATION (READ-ONLY)
-- Run AFTER "20260910_phaseX5_2_profile_rpc_isolation.sql",
-- as a separate batch, in Supabase SQL Editor.
--
-- Contains ONLY SELECT statements and metadata DO-blocks that
-- only READ catalogs. Nothing is modified. No INSERT / UPDATE /
-- DELETE / CREATE / ALTER / DROP / GRANT / REVOKE.
--
-- Contracts checked here are the VERIFIED LIVE CONTRACTS:
--   1) get_teacher_student_by_session:
--      id uuid, student_id text, name text, phone text,
--      parent_phone text, created_at timestamptz,
--      last_activity timestamptz
--   2) get_teacher_student_results_by_session:
--      id uuid, result_id text, student_id text, type text,
--      grade integer, unit integer, title text, correct integer,
--      total integer, percentage integer, completed_at timestamptz
--   3) get_teacher_student_activities_by_session:
--      id uuid, student_id text, activity_type text, page text,
--      details jsonb, created_at timestamptz
--   4) get_teacher_student_certificates_by_session:
--      id uuid, certificate_id text, result_id text, student_id text,
--      student_name text, teacher_name text, teacher_image text,
--      assessment_name text, score integer, message text, date text,
--      created_at timestamptz
--
-- Behavioral checks (SECTION K) use a REAL session token obtained
-- by logging into the teacher dashboard — no session, student or
-- any other row is created by this file.
-- ============================================================

-- ############################################################
-- STEP 0 — ROW-COUNT SNAPSHOT (identical before/after migration;
-- diff must be ZERO — the migration changes function bodies only)
-- Baseline before X.5.2 (recorded): students=5 (3 legacy NULL +
-- 2 labeled test students), student_results=1,
-- student_activities=36+ (grows only via real student activity),
-- student_certificates=1, groups=0, group_students=0.
-- ############################################################
select 'students' t, count(*) from public.students
union all select 'student_results', count(*) from public.student_results
union all select 'student_activities', count(*) from public.student_activities
union all select 'student_certificates', count(*) from public.student_certificates
union all select 'teacher_sessions', count(*) from public.teacher_sessions
union all select 'teachers', count(*) from public.teachers
union all select 'teacher_evaluations', count(*) from public.teacher_evaluations
order by t;

-- ############################################################
-- SECTION A — EXACT SIGNATURES (identity args, no overloads)
-- EXPECTED: 4 rows, each with
--   args = 'p_session_token text, p_student_id text'
--   overload_count = 1
-- ############################################################
select p.proname,
       pg_catalog.pg_get_function_identity_arguments(p.oid) as args,
       pg_catalog.pg_get_function_result(p.oid)             as returns,
       p.prosecdef                                          as security_definer,
       p.provolatile                                        as volatility,
       p.proconfig::text                                    as config,
       (select count(*) from pg_catalog.pg_proc p2
         join pg_catalog.pg_namespace n2 on n2.oid = p2.pronamespace
        where n2.nspname='public' and p2.proname = p.proname) as overload_count
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('get_teacher_student_by_session',
                     'get_teacher_student_results_by_session',
                     'get_teacher_student_activities_by_session',
                     'get_teacher_student_certificates_by_session')
 order by p.proname;

-- ############################################################
-- SECTION B — EXACT RETURN CONTRACTS (column count, names, order,
--             types) compared to the VERIFIED LIVE CONTRACTS.
-- EXPECTED: 4 rows, each with match=true. Any false = FAILED.
-- The contract string format is name|col:type|col:type|...
-- (attname:format_type, in attnum order).
-- ############################################################
select p.proname,
       coalesce('|' || string_agg(
            quote_ident(a.attname) || ':' || format_type(a.atttypid, a.atttypmod),
            '|' order by a.attnum), '') as live_contract,
       case p.proname
         when 'get_teacher_student_by_session' then
              '|id:uuid|student_id:text|name:text|phone:text'
           || '|parent_phone:text|created_at:timestamptz'
           || '|last_activity:timestamptz'
         when 'get_teacher_student_results_by_session' then
              '|id:uuid|result_id:text|student_id:text|type:text'
           || '|grade:integer|unit:integer|title:text|correct:integer'
           || '|total:integer|percentage:integer|completed_at:timestamptz'
         when 'get_teacher_student_activities_by_session' then
              '|id:uuid|student_id:text|activity_type:text|page:text'
           || '|details:jsonb|created_at:timestamptz'
         when 'get_teacher_student_certificates_by_session' then
              '|id:uuid|certificate_id:text|result_id:text|student_id:text'
           || '|student_name:text|teacher_name:text|teacher_image:text'
           || '|assessment_name:text|score:integer|message:text'
           || '|date:text|created_at:timestamptz'
       end as verified_contract,
       (coalesce('|' || string_agg(
            quote_ident(a.attname) || ':' || format_type(a.atttypid, a.atttypmod),
            '|' order by a.attnum), '')
        = case p.proname
         when 'get_teacher_student_by_session' then
              '|id:uuid|student_id:text|name:text|phone:text'
           || '|parent_phone:text|created_at:timestamptz'
           || '|last_activity:timestamptz'
         when 'get_teacher_student_results_by_session' then
              '|id:uuid|result_id:text|student_id:text|type:text'
           || '|grade:integer|unit:integer|title:text|correct:integer'
           || '|total:integer|percentage:integer|completed_at:timestamptz'
         when 'get_teacher_student_activities_by_session' then
              '|id:uuid|student_id:text|activity_type:text|page:text'
           || '|details:jsonb|created_at:timestamptz'
         when 'get_teacher_student_certificates_by_session' then
              '|id:uuid|certificate_id:text|result_id:text|student_id:text'
           || '|student_name:text|teacher_name:text|teacher_image:text'
           || '|assessment_name:text|score:integer|message:text'
           || '|date:text|created_at:timestamptz'
       end) as contract_match
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  join pg_catalog.pg_type t on t.oid = p.prorettype
  join pg_catalog.pg_class c on c.oid = t.typrelid
  join pg_catalog.pg_attribute a
    on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
 where n.nspname = 'public'
   and p.proname in ('get_teacher_student_by_session',
                     'get_teacher_student_results_by_session',
                     'get_teacher_student_activities_by_session',
                     'get_teacher_student_certificates_by_session')
 group by p.proname
 order by p.proname;
-- EXPECTED: contract_match = true for ALL FOUR rows.

-- ############################################################
-- SECTION C — SECURITY DEFINER + PINNED search_path
-- EXPECTED: security_definer = true for all 4;
--           config contains 'search_path=-' (empty pinned path).
-- ############################################################
select p.proname,
       p.prosecdef as security_definer,
       p.proconfig::text as config
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('get_teacher_student_by_session',
                     'get_teacher_student_results_by_session',
                     'get_teacher_student_activities_by_session',
                     'get_teacher_student_certificates_by_session')
 order by p.proname;

-- ############################################################
-- SECTION D — EXECUTE GRANTS (same public API as before)
-- EXPECTED: anon + authenticated rows for ALL FOUR,
--           and NO 'PUBLIC' rows.
-- ############################################################
select g.routine_name, g.grantee, g.privilege_type
  from information_schema.role_routine_grants g
 where g.routine_schema = 'public'
   and g.routine_name in ('get_teacher_student_by_session',
                          'get_teacher_student_results_by_session',
                          'get_teacher_student_activities_by_session',
                          'get_teacher_student_certificates_by_session')
   and g.grantee in ('anon', 'authenticated', 'PUBLIC')
 order by g.routine_name, g.grantee;

-- ############################################################
-- SECTION E — OWNERSHIP SOURCE-LOGIC CHECK (deep, not keyword-only)
-- Verifies each function body actually enforces the ownership
-- chain. The checks look for the CONCRETE CLAUSES, not just the
-- words:
--   G1 session resolution  : token_hash compared to the sha256
--                            digest of the raw token
--   G2 expiry gate         : expires_at <= now() fails closed
--   G3 teacher-active gate : v_active is not true fails closed
--   G4 ownership join      : child student_id joined to
--                            students.student_id (child RPCs)
--   G5 ownership filter    : s.teacher_id::text = v_teacher_id
--                            (the decisive ownership authority)
-- EXPECTED: every flag = true on all 4 rows.
-- ############################################################
select p.proname,
       (p.prosrc like '%token_hash = encode(extensions.digest(p_session_token, ''sha256''), ''hex'')%')
            as g1_session_resolution,
       (p.prosrc like '%expires_at <= now()%')
            as g2_expiry_check,
       (p.prosrc like '%v_active is not true%')
            as g3_active_teacher_check,
       (p.prosrc like '%on s.student_id::text = sr.student_id::text%'
     or p.prosrc like '%on s.student_id::text = sa.student_id::text%'
     or p.prosrc like '%on s.student_id::text = sc.student_id::text%')
            as g4_parent_student_join,
       (p.prosrc like '%s.teacher_id::text = v_teacher_id%')
            as g5_ownership_filter
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('get_teacher_student_by_session',
                     'get_teacher_student_results_by_session',
                     'get_teacher_student_activities_by_session',
                     'get_teacher_student_certificates_by_session')
 order by p.proname;
-- EXPECTED: g1..g5 all true. For the main student RPC, g4 is
-- false BY DESIGN (no parent join needed — the row itself is the
-- student); all others must be true.

-- ############################################################
-- SECTION F — NO TEACHER_ID LEAK CHECK (structural)
-- None of the four may expose a teacher_id OUTPUT column.
-- Raises if a leak exists.
-- EXPECTED: 4 NOTICE rows, no exception.
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
           and p.proname in ('get_teacher_student_by_session',
                             'get_teacher_student_results_by_session',
                             'get_teacher_student_activities_by_session',
                             'get_teacher_student_certificates_by_session')
    loop
        if 'teacher_id' = any (r.proargnames) then
            raise exception 'LEAK: %.output exposes teacher_id', r.proname;
        end if;
        raise notice '% out-columns: %', r.proname, r.proargnames;
    end loop;
end
$g$;

-- ############################################################
-- SECTION G — RLS STATE UNCHANGED (read-only)
-- EXPECTED: relrowsecurity=false, relforcerowsecurity=false for
-- every listed table (RLS belongs to a later phase; X.5.2 did
-- not touch it).
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
-- SECTION H — ROW COUNTS (compare with STEP 0; diff = ZERO)
-- ############################################################
select 'students' t, count(*) from public.students
union all select 'student_results', count(*) from public.student_results
union all select 'student_activities', count(*) from public.student_activities
union all select 'student_certificates', count(*) from public.student_certificates
order by t;

-- ############################################################
-- SECTION I — LEGACY NULL-OWNER ROWS UNTOUCHED
-- EXPECTED: exactly 3 rows, all with teacher_id NULL
-- (ST-MTUZQBUW-7FQ9YZ, ST-MTV0D654-OKWJP0, ST-MTVUS5X4-FMKI22)
-- ############################################################
select student_id, teacher_id
  from public.students
 where teacher_id is null
 order by student_id;

-- ############################################################
-- SECTION J — UNTARGETED RPCs STILL PRESENT (existence only)
-- EXPECTED: 5 rows (evaluations + 2 legacy globals + 2 X.5.1
-- roster RPCs)
-- ############################################################
select p.proname,
       pg_catalog.pg_get_function_identity_arguments(p.oid) as args,
       p.prosecdef as security_definer
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('get_teacher_student_evaluations_by_session',
                     'find_student_by_phone',
                     'update_student_by_phone',
                     'get_teacher_students_by_session',
                     'get_teacher_group_students_by_session')
 order by p.proname;

-- ############################################################
-- SECTION K — BEHAVIORAL CHECKS (read-only; need a REAL token)
--
-- Obtain the raw token WITHOUT creating any new session:
--   Log into teacher-dashboard.html normally (daily-use login,
--   not synthetic data). Then in DevTools:
--     sessionStorage.getItem('nexora_teacher_token')
--   Paste the value in place of PASTE_RAW_TOKEN_HERE.
--
-- All calls below are READ-ONLY RPC invocations. They create and
-- modify NOTHING.
-- ############################################################

-- K.1 — TEST A: Teacher A → Student A succeeds (returns 1 row of
--       the owned student; pick a student owned by the session
--       teacher, e.g. an X.4-B test student under T-MOHAB-001:
--       ST-2A6DB036-413D2D or ST-F3D64332-15FFE3)
-- with raw_token as (select 'PASTE_RAW_TOKEN_HERE'::text as tok)
-- select * from public.get_teacher_student_by_session(
--     (select tok from raw_token), 'PASTE_OWNED_STUDENT_ID');
-- EXPECTED: 1 row. Then the child RPCs for the same student:
-- select * from public.get_teacher_student_results_by_session(tok, 'PASTE_OWNED_STUDENT_ID');
-- select * from public.get_teacher_student_activities_by_session(tok, 'PASTE_OWNED_STUDENT_ID');
-- select * from public.get_teacher_student_certificates_by_session(tok, 'PASTE_OWNED_STUDENT_ID');
-- EXPECTED: only rows belonging to that owned student.

-- K.2 — TEST B: Teacher A → Student B (owned by Teacher B) => EMPTY
--       Requires T-SECURITY-002 login (second dashboard tab) when
--       available. From B's session, query one of Mohab's owned
--       students:
-- with raw_token as (select 'PASTE_TEACHER_B_TOKEN'::text as tok)
-- select * from public.get_teacher_student_by_session(
--     (select tok from raw_token), 'ST-2A6DB036-413D2D');
-- EXPECTED: 0 rows (no existence leak). Repeat for the 3 child
-- RPCs with the same inputs => 0 rows each.

-- K.3 — TEST C: Teacher A → legacy NULL-owner student => EMPTY
-- with raw_token as (select 'PASTE_RAW_TOKEN_HERE'::text as tok)
-- select * from public.get_teacher_student_by_session(
--     (select tok from raw_token), 'ST-MTUZQBUW-7FQ9YZ');
-- EXPECTED: 0 rows. Repeat for the 3 child RPCs => 0 rows each.

-- K.4 — TEST D: invalid token => EMPTY (fail-closed)
-- select * from public.get_teacher_student_by_session('x52-invalid-probe', 'ST-2A6DB036-413D2D');
-- select * from public.get_teacher_student_results_by_session('x52-invalid-probe', 'ST-2A6DB036-413D2D');
-- select * from public.get_teacher_student_activities_by_session('x52-invalid-probe', 'ST-2A6DB036-413D2D');
-- select * from public.get_teacher_student_certificates_by_session('x52-invalid-probe', 'ST-2A6DB036-413D2D');
-- EXPECTED: 0 rows each.

-- K.5 — TEST E: expired session fails
--       Wait until the session's expires_at passes (or reuse an
--       old saved token), then re-run K.1. EXPECTED: 0 rows.

-- K.6 — TEST F: no cross-tenant data anywhere
--       From teacher B's session run the K.2 query set for EVERY
--       student owned by teacher A; all must be empty. Combined
--       with K.1, this proves the ownership boundary.

-- ############################################################
-- END OF X.5.2 VERIFICATION (READ-ONLY)
-- ############################################################
