-- ============================================================
-- NEXORA — Phase X.4-A: POST-EXECUTION VERIFICATION (READ-ONLY)
-- Run AFTER "20260910_phaseX4A_ownership_registration.sql",
-- as a separate batch, in Supabase SQL Editor.
--
-- Contains ONLY SELECT statements. Nothing is modified.
-- Sections A -> G. Each section states its EXPECTED result so the
-- raw output can be reviewed line by line.
-- ============================================================

-- ############################################################
-- SECTION A — registration_code assignment
-- EXPECTED (2 rows):
--   T-MOHAB-001      | NX-MOHAB-2026 | true
--   T-SECURITY-002   | <NULL>        | true   (must remain NULL)
-- ############################################################
select teacher_id,
       username,
       registration_code,
       active
  from public.teachers
 order by teacher_id;

-- ############################################################
-- SECTION B — RPC correctness (structural catalog checks)
-- ############################################################

-- B.1 the two new RPCs: exact signature, return type, definer,
--     volatility, owner.
-- EXPECTED (2 rows):
--   register_student     | args: p_name text, p_phone text, p_parent_phone text, p_registration_code text
--                        | returns: TABLE(student_id text, is_new boolean)
--                        | security_definer: true | volatility: v
--   update_student_scoped| args: p_registration_code text, p_student_id text, p_name text, p_phone text, p_parent_phone text
--                        | returns: boolean
--                        | security_definer: true | volatility: v
select p.proname,
       pg_catalog.pg_get_function_identity_arguments(p.oid) as args,
       pg_catalog.pg_get_function_result(p.oid)             as returns,
       p.prosecdef                                          as security_definer,
       p.provolatile                                        as volatility,
       p.proowner::regrole::text                            as owner
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('register_student', 'update_student_scoped')
 order by p.proname;

-- B.2 execute grants on the new RPCs (per grantee — decisive).
-- EXPECTED: anon + authenticated rows with EXECUTE for BOTH functions,
--           and NO 'PUBLIC' row (PUBLIC must stay revoked).
select g.routine_name,
       g.grantee,
       g.privilege_type
  from information_schema.role_routine_grants g
 where g.routine_schema = 'public'
   and g.routine_name in ('register_student', 'update_student_scoped')
   and g.grantee in ('anon', 'authenticated', 'PUBLIC')
 order by g.routine_name, g.grantee;

-- B.3 LEGACY RPCs intact: not removed, not revoked.
-- EXPECTED (2 rows): find_student_by_phone and update_student_by_phone
--                    both present, anon_can_execute = true.
-- (args column is evidence output for review — X.4-A must not have
--  altered either function.)
select p.proname,
       pg_catalog.pg_get_function_identity_arguments(p.oid) as args,
       exists (
           select 1
             from information_schema.role_routine_grants g
            where g.routine_schema = 'public'
              and g.routine_name   = p.proname
              and g.grantee        = 'anon'
              and g.privilege_type = 'EXECUTE'
       ) as anon_can_execute
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('find_student_by_phone', 'update_student_by_phone')
 order by p.proname;

-- ############################################################
-- SECTION C — scoped partial unique index (structural check:
-- unique + partial + exact key columns + exact predicate;
-- formatting-independent, not a text match on indexdef)
-- EXPECTED: EXACTLY 1 row ->
--   uq_students_teacher_phone_pair | teacher_id,phone,parent_phone
--   | (teacher_id IS NOT NULL)
-- ############################################################
select i.indexrelid::regclass::text                       as index_name,
       (
           select string_agg(a.attname, ',' order by x.ord)
             from unnest(i.indkey::smallint[])
                      with ordinality as x(attnum, ord)
             join pg_catalog.pg_attribute a
               on a.attrelid = i.indrelid
              and a.attnum   = x.attnum
       )                                                  as key_columns,
       pg_catalog.pg_get_expr(i.indpred, i.indrelid)      as predicate
  from pg_catalog.pg_index i
  join pg_catalog.pg_class     c on c.oid = i.indrelid
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and c.relname  = 'students'
   and i.indisunique
   and i.indpred is not null
   and pg_catalog.pg_get_expr(i.indpred, i.indrelid)
       = '(teacher_id IS NOT NULL)';

-- hard count (must be exactly 1 — no duplicates allowed)
select count(*) as matching_index_count_expected_1
  from pg_catalog.pg_index i
  join pg_catalog.pg_class     c on c.oid = i.indrelid
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and c.relname  = 'students'
   and i.indisunique
   and i.indpred is not null
   and pg_catalog.pg_get_expr(i.indpred, i.indrelid)
       = '(teacher_id IS NOT NULL)';

-- ############################################################
-- SECTION D — child-ownership stamping
-- ############################################################

-- D.1 the trigger function itself.
-- EXPECTED: 1 row | nx_stamp_child_teacher | returns: trigger
--           | security_definer: true
select p.proname,
       p.prorettype::regtype::text as returns,
       p.prosecdef                 as security_definer
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname = 'nx_stamp_child_teacher';

-- D.2 the three triggers on the correct tables.
-- EXPECTED: EXACTLY 3 rows (one per table):
--   student_activities   | trg_stamp_child_teacher | enabled 'O' | function nx_stamp_child_teacher | returns trigger
--   student_certificates | trg_stamp_child_teacher | enabled 'O' | ...
--   student_results      | trg_stamp_child_teacher | enabled 'O' | ...
select c.relname                     as table_name,
       t.tgname,
       t.tgenabled                   as state_O_enabled,
       p.proname                     as function_name,
       p.prorettype::regtype::text   as function_returns,
       p.prosecdef                   as security_definer
  from pg_catalog.pg_trigger t
  join pg_catalog.pg_class     c on c.oid = t.tgrelid
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  join pg_catalog.pg_proc      p on p.oid = t.tgfoid
 where n.nspname = 'public'
   and t.tgname  = 'trg_stamp_child_teacher'
   and not t.tgisinternal
 order by c.relname;

-- D.3 hard count of DISTINCT tables protected (must be exactly 3)
select count(distinct t.tgrelid::regclass::text) as protected_tables_expected_3
  from pg_catalog.pg_trigger t
  join pg_catalog.pg_class     c on c.oid = t.tgrelid
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and t.tgname  = 'trg_stamp_child_teacher'
   and not t.tgisinternal;

-- ############################################################
-- SECTION E — INSERT privilege lockdown proof
-- ############################################################

-- E.1 EXPECTED: ZERO ROWS — no anon/authenticated column INSERT
--     on teacher_id of the four protected tables.
select table_name, column_name, grantee, privilege_type
  from information_schema.column_privileges
 where table_schema = 'public'
   and table_name   in ('students', 'student_results',
                        'student_activities', 'student_certificates')
   and column_name    = 'teacher_id'
   and privilege_type = 'INSERT'
   and grantee in ('anon', 'authenticated');

-- E.2 EXPECTED: ZERO ROWS — no TABLE-level INSERT either
--     (a table-level grant would subsume every column again).
select table_name, grantee, privilege_type
  from information_schema.table_privileges
 where table_schema = 'public'
   and table_name   in ('students', 'student_results',
                        'student_activities', 'student_certificates')
   and privilege_type = 'INSERT'
   and grantee in ('anon', 'authenticated');

-- E.3 EXPECTED: rows present for every column the current frontend
--     inserts (students: student_id,name,phone,parent_phone,
--     created_at,last_activity; student_activities: student_id,
--     activity_type,page,details,created_at; student_results:
--     result_id,student_id,type,grade,unit,title,correct,total,
--     percentage,completed_at; student_certificates: certificate_id,
--     result_id,student_id,student_name,teacher_name,teacher_image,
--     assessment_name,score,message,date,created_at).
--     This proves the cutover capability was preserved.
select table_name, column_name, grantee
  from information_schema.column_privileges
 where table_schema = 'public'
   and table_name   in ('students', 'student_results',
                        'student_activities', 'student_certificates')
   and privilege_type = 'INSERT'
   and grantee in ('anon', 'authenticated')
   and column_name  <> 'teacher_id'
 order by table_name, column_name;

-- ############################################################
-- SECTION F — legacy data untouched (no backfill proof)
-- EXPECTED (4 rows): students = 3 | student_results = 1 |
--                    student_activities = 36 | student_certificates = 1
-- (compare against the X.3 audit baseline — must be identical)
-- ############################################################
select 'students'            as table_name, count(*) as null_teacher_rows
  from public.students
 where teacher_id is null
union all
select 'student_results',      count(*) from public.student_results      where teacher_id is null
union all
select 'student_activities',   count(*) from public.student_activities   where teacher_id is null
union all
select 'student_certificates', count(*) from public.student_certificates where teacher_id is null
 order by table_name;

-- full legacy-student snapshot for the record
-- EXPECTED: 3 rows, all teacher_id NULL, unchanged names/phones/created_at
select student_id, name, phone, parent_phone, teacher_id, created_at
  from public.students
 order by created_at;

-- ############################################################
-- SECTION G — ownership balance & final state
-- EXPECTED: owned_rows = 0 on ALL four tables immediately after
-- X.4-A (no backfill, no registrations yet). Any value > 0 must
-- correspond to registrations performed AFTER the cutover only.
-- ############################################################
select 'students'            as table_name,
       count(*) filter (where teacher_id is not null) as owned_rows,
       count(*) filter (where teacher_id is null)     as null_rows
  from public.students
union all
select 'student_results',
       count(*) filter (where teacher_id is not null),
       count(*) filter (where teacher_id is null)
  from public.student_results
union all
select 'student_activities',
       count(*) filter (where teacher_id is not null),
       count(*) filter (where teacher_id is null)
  from public.student_activities
union all
select 'student_certificates',
       count(*) filter (where teacher_id is not null),
       count(*) filter (where teacher_id is null)
  from public.student_certificates
 order by table_name;

-- G.2 single-active-code sanity: the code must resolve to EXACTLY
-- ONE active teacher (the register_student lookup contract).
-- EXPECTED: 1 row | teacher_id = T-MOHAB-001
select t.teacher_id
  from public.teachers t
 where upper(btrim(t.registration_code)) = upper(btrim('NX-MOHAB-2026'))
   and t.active = true;
