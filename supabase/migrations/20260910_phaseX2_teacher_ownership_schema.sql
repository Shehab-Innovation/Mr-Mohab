-- ============================================================
-- NEXORA — Phase X.2: Teacher Ownership Schema Preparation
-- Owner: Shehab Innovation
-- Date:  2026-09-10
-- Baseline: main @ 41d8567 (Phase 4: separate teacher curriculum content)
--
-- PURPOSE
--   Prepare the schema for multi-teacher ownership BEFORE any
--   backfill or RPC change (those are later phases):
--     1. teacher_id  -> students, student_results,
--                       student_activities, student_certificates
--     2. registration_code -> teachers (server-side teacher
--                       resolution for student registration)
--     3. Supporting indexes
--
-- SAFETY
--   * ADDITIVE only: no column dropped, no value changed,
--     no row touched. All new columns are NULL and stay NULL
--     (backfill is a later phase).
--   * IDEMPOTENT: every step checks before it creates.
--   * SELF-VERIFYING / STOP-ON-DIFFERENCE: the live column
--     types, PKs and constraints could NOT be inspected from
--     the deployment workspace, so NOTHING is assumed:
--       - the new columns inherit the EXACT type of
--         teachers.teacher_id detected via
--         pg_catalog.format_type (length/typmod preserved)
--       - only plain BASE types are auto-copied; domains,
--         enums and custom types stop the migration with
--         BLOCKED
--       - if any assumption fails, the migration raises
--         'BLOCKED: ...' and the transaction aborts with
--         ZERO changes applied.
--   * Run from: Supabase Dashboard -> SQL Editor -> Run.
--
-- NOT DONE HERE (later phases, by design):
--   * No backfill of teacher_id (X.3)
--   * No Foreign Keys created (deferred to a later phase)
--   * No RPC changes (X.4+)
--   * No RLS changes
--   * No registration_code VALUES are written
-- ============================================================

begin;

-- ------------------------------------------------------------
-- GUARD 1 — verify preconditions before touching anything
-- ------------------------------------------------------------
do $$
declare
    v_teachers_type   text;
    v_type_kind       "char";
    v_t               text;
    v_t_full          text;
    v_groups_tid      text;
    v_targets         text[] := array[
        'students',
        'student_results',
        'student_activities',
        'student_certificates'
    ];
begin
    -- 1. teachers.teacher_id must exist (identity anchor).
    --    Exact type captured via pg_catalog.format_type()
    --    (preserves varchar length / typmod) instead of the
    --    lossy information_schema.columns.data_type.
    select pg_catalog.format_type(a.atttypid, a.atttypmod),
           t.typtype
      into v_teachers_type,
           v_type_kind
      from pg_catalog.pg_attribute a
      join pg_catalog.pg_class c
        on c.oid = a.attrelid
      join pg_catalog.pg_namespace n
        on n.oid = c.relnamespace
      join pg_catalog.pg_type t
        on t.oid = a.atttypid
     where n.nspname  = 'public'
       and c.relname  = 'teachers'
       and a.attname  = 'teacher_id'
       and a.attnum   > 0
       and not a.attisdropped;

    if v_teachers_type is null then
        raise exception 'BLOCKED: public.teachers.teacher_id does not exist. Cannot anchor ownership. Run the Phase X.2 evidence queries and report back.';
    end if;

    -- 1b. Only plain BASE types may be copied. Domains ('d'),
    --     enums ('e'), composite/pseudo/custom types are
    --     stopped explicitly (nothing is assumed).
    if v_type_kind is distinct from 'b' then
        raise exception 'BLOCKED: public.teachers.teacher_id is not a plain base type (pg_type.typtype = %). Domains, enums and custom types are not auto-copied. Resolve manually before running X.2.', v_type_kind;
    end if;

    -- 2. all four target tables must exist
    foreach v_t in array v_targets loop
        if not exists (
            select 1 from information_schema.tables
             where table_schema = 'public'
               and table_name   = v_t
        ) then
            raise exception 'BLOCKED: table public.% does not exist. Verify the table name and re-run.', v_t;
        end if;
    end loop;

    -- 3. sanity notice (not blocking): groups.teacher_id
    --    should already exist from the group-scoping work
    select data_type
      into v_groups_tid
      from information_schema.columns
     where table_schema = 'public'
       and table_name   = 'groups'
       and column_name  = 'teacher_id';

    if v_groups_tid is null then
        raise warning 'NOTE: public.groups.teacher_id was NOT found. Group ownership checks must be added in a later phase.';
    end if;

    raise notice 'GUARD OK: teachers.teacher_id detected, type = %', v_teachers_type;

    -- 4. add teacher_id to the four tables, using the EXACT
    --    same type as teachers.teacher_id (no assumption)
    foreach v_t in array v_targets loop
        execute format(
            'alter table public.%I add column if not exists teacher_id %s',
            v_t, v_teachers_type
        );
    end loop;

    -- 5. re-verify: if a pre-existing teacher_id column on any
    --    target has a DIFFERENT EXACT type (base type, length
    --    and typmod via format_type), stop everything
    foreach v_t in array v_targets loop
        select pg_catalog.format_type(a.atttypid, a.atttypmod)
          into v_t_full
          from pg_catalog.pg_attribute a
          join pg_catalog.pg_class c
            on c.oid = a.attrelid
          join pg_catalog.pg_namespace n
            on n.oid = c.relnamespace
         where n.nspname  = 'public'
           and c.relname  = v_t
           and a.attname  = 'teacher_id'
           and a.attnum   > 0
           and not a.attisdropped;

        if v_t_full is distinct from v_teachers_type then
            raise exception 'BLOCKED: public.%.teacher_id has type % which differs from teachers.teacher_id (%). No changes have been committed; investigate before proceeding.', v_t, coalesce(v_t_full, 'MISSING'), v_teachers_type;
        end if;
    end loop;

    raise notice 'teacher_id columns ready on: %', array_to_string(v_targets, ', ');
end $$;

-- ------------------------------------------------------------
-- STEP 3 — teachers.registration_code
--   Server-side teacher resolution for student registration:
--   the student submits a CODE (not a teacher_id); the future
--   registration RPC resolves the teacher from it.
--   Partial unique index: multiple NULLs allowed, so existing
--   teachers without codes are never affected.
-- ------------------------------------------------------------
do $$
declare
    v_exists boolean;
begin
    select exists (
        select 1 from information_schema.columns
         where table_schema = 'public'
           and table_name   = 'teachers'
           and column_name  = 'registration_code'
    )
      into v_exists;

    if not v_exists then
        alter table public.teachers add column registration_code text;
        raise notice 'column added: teachers.registration_code (text, NULL — values assigned in a later phase)';
    else
        raise notice 'column already exists: teachers.registration_code';
    end if;

    if not exists (
        select 1 from pg_indexes
         where schemaname = 'public'
           and tablename  = 'teachers'
           and indexname  = 'uq_teachers_registration_code'
    ) then
        create unique index uq_teachers_registration_code
            on public.teachers (registration_code)
            where registration_code is not null;
        raise notice 'unique index created: uq_teachers_registration_code (partial, NULL-safe)';
    else
        raise notice 'unique index already exists: uq_teachers_registration_code';
    end if;
end $$;

-- ------------------------------------------------------------
-- STEP 4 — supporting indexes for future teacher-scoped reads
--   (created after the columns exist; small tables, plain
--    in-transaction index is correct here)
-- ------------------------------------------------------------
create index if not exists idx_students_teacher_id
    on public.students (teacher_id);

create index if not exists idx_student_results_teacher_id
    on public.student_results (teacher_id);

create index if not exists idx_student_activities_teacher_id
    on public.student_activities (teacher_id);

create index if not exists idx_student_certificates_teacher_id
    on public.student_certificates (teacher_id);

-- ------------------------------------------------------------
-- STEP 5 — documentation comments (metadata only)
-- ------------------------------------------------------------
comment on column public.students.teacher_id              is 'NEXORA X.2: owning teacher. NULL until X.3 backfill.';
comment on column public.student_results.teacher_id       is 'NEXORA X.2: owning teacher. NULL until X.3 backfill.';
comment on column public.student_activities.teacher_id    is 'NEXORA X.2: owning teacher. NULL until X.3 backfill.';
comment on column public.student_certificates.teacher_id  is 'NEXORA X.2: owning teacher. NULL until X.3 backfill.';
comment on column public.teachers.registration_code       is 'NEXORA X.2: public registration code; future registration RPC resolves teacher server-side from this code.';

commit;

-- ============================================================
-- POST-MIGRATION VERIFICATION (READ-ONLY — run separately
-- AFTER the migration commits, or any time later)
-- ============================================================
-- select table_name, column_name, data_type
--   from information_schema.columns
--  where table_schema = 'public'
--    and ((table_name in ('students','student_results','student_activities','student_certificates')
--          and column_name = 'teacher_id')
--      or (table_name = 'teachers' and column_name in ('teacher_id','registration_code')))
--  order by table_name, column_name;
--
-- select indexname, indexdef
--   from pg_indexes
--  where schemaname = 'public'
--    and indexname in (
--        'uq_teachers_registration_code',
--        'idx_students_teacher_id',
--        'idx_student_results_teacher_id',
--        'idx_student_activities_teacher_id',
--        'idx_student_certificates_teacher_id');
-- ============================================================
