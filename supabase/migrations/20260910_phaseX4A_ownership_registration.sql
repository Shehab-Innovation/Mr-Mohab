-- ============================================================
-- NEXORA — Phase X.4-A: Ownership-Safe Registration (DATABASE-ONLY)
-- Owner: Shehab Innovation
-- Date:  2026-09-10
-- Baseline: main @ 41d8567 (Phase 4: separate teacher curriculum content)
-- Depends on: X.2 executed (teacher_id columns + registration_code exist)
--
-- SCOPE (STRICT)
--   * DATABASE ONLY. No frontend file is modified by this phase.
--   * NO backfill: every existing teacher_id (all NULL) stays NULL.
--     No UPDATE/DELETE touches any existing student/result/activity/
--     certificate row.
--   * NO RLS in this phase (X.5).
--   * Legacy RPCs find_student_by_phone / update_student_by_phone are
--     NOT deleted and NOT revoked (zero-downtime cutover; they will be
--     revoked only after X.4-B frontend migration is verified).
--   * No foreign keys added in this phase (per X.2 decision).
--
-- WHAT IT DOES
--   1. Preflight BLOCKED-guards (schema, capabilities, RPC evidence)
--   2. Assigns ONE enrollment registration_code to T-MOHAB-001 only
--   3. Creates register_student(...)  — SECURITY DEFINER
--   4. Creates the scoped partial unique index (race safety)
--   5. Creates update_student_scoped(...) — SECURITY DEFINER
--   6. Creates nx_stamp_child_teacher() + 3 BEFORE INSERT triggers
--   7. Column-level lockdown: anon/authenticated can no longer INSERT
--      the teacher_id column on the four protected tables
--
-- IDEMPOTENT: every step checks before it acts; safe to re-run.
-- TRANSACTIONAL: any BLOCKED/error aborts with ZERO changes applied.
-- Run as ONE batch: Supabase Dashboard -> SQL Editor -> Run.
-- ============================================================

begin;

-- ============================================================
-- SECTION 1 — PRE-FLIGHT GUARDS (nothing has been changed yet)
-- ============================================================
do $preflight$
declare
    v_regcode_exists   boolean;
    v_regcode_nullable boolean;
    v_teachers_tid     text;
    v_teachers_kind    "char";
    v_t                text;
    v_fn               text;
    v_missing          text;
    v_genc_schema      text;
begin

    -- 1.1 teachers.registration_code exists and is nullable
    select exists (
        select 1 from information_schema.columns
         where table_schema = 'public'
           and table_name   = 'teachers'
           and column_name  = 'registration_code'
    ),
    coalesce((
        select is_nullable = 'YES'
          from information_schema.columns
         where table_schema = 'public'
           and table_name   = 'teachers'
           and column_name  = 'registration_code'
    ), false)
      into v_regcode_exists, v_regcode_nullable;

    if not v_regcode_exists then
        raise exception 'BLOCKED: public.teachers.registration_code does not exist. Run Phase X.2 first.';
    end if;
    if not v_regcode_nullable then
        raise exception 'BLOCKED: public.teachers.registration_code is NOT nullable. X.2 expected a nullable enrollment key column. Investigate before running X.4-A.';
    end if;

    -- 1.2 teachers.teacher_id: exact type captured and preserved
    select pg_catalog.format_type(a.atttypid, a.atttypmod),
           t.typtype
      into v_teachers_tid, v_teachers_kind
      from pg_catalog.pg_attribute a
      join pg_catalog.pg_class     c on c.oid = a.attrelid
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      join pg_catalog.pg_type      t on t.oid = a.atttypid
     where n.nspname = 'public'
       and c.relname = 'teachers'
       and a.attname = 'teacher_id'
       and a.attnum  > 0
       and not a.attisdropped;

    if v_teachers_tid is null then
        raise exception 'BLOCKED: public.teachers.teacher_id does not exist.';
    end if;
    if v_teachers_kind is distinct from 'b' then
        raise exception 'BLOCKED: public.teachers.teacher_id is not a plain base type (typtype=%). X.4-A will not guess.', v_teachers_kind;
    end if;

    -- 1.3 the four ownership columns exist with the SAME exact type
    foreach v_t in array array[
        'students',
        'student_results',
        'student_activities',
        'student_certificates'
    ] loop
        if coalesce((
            select pg_catalog.format_type(a.atttypid, a.atttypmod)
              from pg_catalog.pg_attribute a
              join pg_catalog.pg_class     c on c.oid = a.attrelid
              join pg_catalog.pg_namespace n on n.oid = c.relnamespace
             where n.nspname = 'public'
               and c.relname = v_t
               and a.attname = 'teacher_id'
               and a.attnum  > 0
               and not a.attisdropped
        ), 'MISSING') is distinct from v_teachers_tid then
            raise exception 'BLOCKED: public.%.teacher_id missing or type % differs from teachers.teacher_id (%). Run/repair X.2 first.', v_t,
                coalesce((
                    select pg_catalog.format_type(a.atttypid, a.atttypmod)
                      from pg_catalog.pg_attribute a
                      join pg_catalog.pg_class     c on c.oid = a.attrelid
                      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
                     where n.nspname = 'public'
                       and c.relname = v_t
                       and a.attname = 'teacher_id'
                       and a.attnum  > 0
                       and not a.attisdropped
                ), 'MISSING'),
                v_teachers_tid;
        end if;
    end loop;

    -- 1.4 pgcrypto capability — locate gen_random_bytes and pin its
    --     ACTUAL schema before anything references it. This project
    --     exposes pgcrypto under the `extensions` schema; the RPCs
    --     below reference extensions.gen_random_bytes ONLY, so we
    --     verify exactly that and refuse any other location.
    select min(n.nspname)
      into v_genc_schema
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where p.proname = 'gen_random_bytes'
       and p.prokind = 'f';

    if v_genc_schema is null then
        raise exception 'BLOCKED: function gen_random_bytes not found in any schema. Install/enable pgcrypto before running X.4-A.';
    end if;

    if v_genc_schema <> 'extensions' then
        raise exception 'BLOCKED: gen_random_bytes found in schema "%" but X.4-A references extensions.gen_random_bytes only. Adjust the qualified reference before running.', v_genc_schema;
    end if;

    raise notice 'PRE-FLIGHT OK: gen_random_bytes verified in schema "extensions"';

    -- 1.5 legacy RPC signatures — EVIDENCE, then decision.
    --     X.4-A keeps both functions untouched (no revoke, no replace),
    --     but refuses to build the cutover on top of signatures the
    --     frontend does not actually call.
    v_missing := '';
    foreach v_fn in array array['find_student_by_phone', 'update_student_by_phone'] loop
        if not exists (
            select 1 from pg_catalog.pg_proc p
            join pg_catalog.pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = v_fn
        ) then
            v_missing := v_missing || v_fn || ' ';
        end if;
    end loop;

    if v_missing <> '' then
        -- Not fatal by itself: they are only needed at cutover time.
        raise warning 'NOTE: legacy RPC(s) not present: %. They will be needed by the CURRENT frontend until X.4-B. If students register before X.4-B, the old path will fail with "function not found" — coordinate the cutover accordingly.', btrim(v_missing);
    else
        raise notice 'PRE-FLIGHT OK: legacy RPCs find_student_by_phone / update_student_by_phone present and left untouched.';
    end if;

    -- 1.6 register_student must not already exist under a DIFFERENT
    --     signature (idempotency guard)
    if exists (
        select 1 from pg_catalog.pg_proc p
        join pg_catalog.pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname = 'register_student'
           and pg_catalog.pg_get_function_identity_arguments(p.oid)
               <> 'p_name text, p_phone text, p_parent_phone text, p_registration_code text'
    ) then
        raise exception 'BLOCKED: public.register_student already exists with a different signature. Refusing to overwrite blindly.';
    end if;

end
$preflight$;

-- ============================================================
-- SECTION 2 — REGISTRATION CODE (enrollment key, T-MOHAB-001 only)
--   * enrollment key, NOT a password/secret
--   * uniqueness enforced by uq_teachers_registration_code (X.2)
--   * collision -> the operator picks another code; no auto-retry
--   * T-SECURITY-002 intentionally NOT modified
--   * idempotent: existing (non-null) code is preserved untouched
-- ============================================================
do $regcode$
declare
    v_existing   text;
    v_code       constant text := 'NX-MOHAB-2026';
begin
    select t.registration_code
      into v_existing
      from public.teachers t
     where t.teacher_id = 'T-MOHAB-001'
     limit 1;

    if not found then
        raise exception 'BLOCKED: teacher T-MOHAB-001 not found in public.teachers.';
    end if;

    if v_existing is not null and btrim(v_existing) <> '' then
        raise notice 'registration_code for T-MOHAB-001 already set — preserved (idempotent re-run).';
        return;
    end if;

    update public.teachers
       set registration_code = v_code
     where teacher_id = 'T-MOHAB-001'
       and registration_code is null;

    if not found then
        raise exception 'BLOCKED: concurrent registration_code assignment detected for T-MOHAB-001. Re-run to inspect.';
    end if;

    raise notice 'registration_code assigned to T-MOHAB-001 (enrollment key: %). Must match nexora-config.js at X.4-B.', v_code;
end
$regcode$;

-- ============================================================
-- SECTION 3 — register_student RPC
--   SECURITY DEFINER, VOLATILE, callable by anon (current MVP).
--   Teacher identity resolved SERVER-SIDE from the normalized code.
--   No p_teacher_id parameter exists — client authority is impossible.
-- ============================================================
create or replace function public.register_student(
    p_name              text,
    p_phone             text,
    p_parent_phone      text,
    p_registration_code text
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

    -- 3.2 resolve teacher server-side (active only).
    --     Same error for unknown/inactive code: no teacher enumeration.
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
    --     Same phone pair under ANOTHER teacher -> fall through and
    --     create a separate student here (no transfer, by design).
    select s.student_id
      into v_existing
      from public.students s
     where s.teacher_id   = v_teacher
       and s.phone        = p_phone
       and s.parent_phone = p_parent_phone
     limit 1;

    if v_existing is not null then
        return query select v_existing, false;
        return;
    end if;

    -- 3.4 server-generated student_id.
    --     Same visual shape as the legacy client-side ids.
    --     pgcrypto is referenced as extensions.gen_random_bytes — the
    --     location VERIFIED by preflight 1.4 — and converted to hex
    --     with pg_catalog.encode.
    v_new_id := 'ST-'
             || upper(substring(pg_catalog.encode(extensions.gen_random_bytes(5), 'hex') from 1 for 8))
             || '-'
             || upper(substring(pg_catalog.encode(extensions.gen_random_bytes(3), 'hex') from 1 for 6));

    -- 3.5 insert with SERVER-side ownership. grade is intentionally
    --     NOT part of the database payload (UI/local-only, by design).
    begin
        insert into public.students
            (student_id, name, phone, parent_phone,
             created_at, last_activity, teacher_id)
        values
            (v_new_id, btrim(p_name), p_phone, p_parent_phone,
             now(), now(), v_teacher);
    exception
        when unique_violation then
            -- concurrent duplicate lost the race on
            -- uq_students_teacher_phone_pair -> return the winner
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

revoke all on function public.register_student(text, text, text, text) from public;
grant execute on function public.register_student(text, text, text, text) to anon, authenticated;

-- ============================================================
-- SECTION 4 — RACE-SAFETY INDEX (scoped to owning teacher)
--   Created only if no equivalent partial unique index exists.
--   Legacy rows (teacher_id NULL) are excluded by the WHERE clause.
-- ============================================================
do $idx$
declare
    v_count     integer;
    v_keycols   text;
    v_pred      text;
begin
    -- robust equivalence check: unique + partial + exactly the three
    -- key columns + exactly the predicate (formatting-independent)
    select count(*),
           max(
               (select string_agg(a.attname, ',' order by x.ord)
                  from unnest(i.indkey::int2[]) with ordinality x(attnum, ord)
                  join pg_catalog.pg_attribute a
                    on a.attrelid = i.indrelid and a.attnum = x.attnum)
           ),
           max(pg_catalog.pg_get_expr(i.indpred, i.indrelid))
      into v_count, v_keycols, v_pred
      from pg_catalog.pg_index i
      join pg_catalog.pg_class     c on c.oid = i.indrelid
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relname = 'students'
       and i.indisunique
       and i.indpred is not null
       and pg_catalog.pg_get_expr(i.indpred, i.indrelid) = '(teacher_id IS NOT NULL)'
       and (
           select string_agg(a.attname, ',' order by x.ord)
             from unnest(i.indkey::int2[]) with ordinality x(attnum, ord)
             join pg_catalog.pg_attribute a
               on a.attrelid = i.indrelid and a.attnum = x.attnum
       ) = 'teacher_id,phone,parent_phone';

    if coalesce(v_count, 0) = 0 then
        -- also refuse if an index with the SAME NAME but different
        -- definition exists (would mean a drifted object)
        if exists (
            select 1 from pg_catalog.pg_indexes
             where schemaname = 'public'
               and indexname  = 'uq_students_teacher_phone_pair'
        ) then
            raise exception 'BLOCKED: index uq_students_teacher_phone_pair exists with a different definition. Investigate before re-running.';
        end if;

        create unique index uq_students_teacher_phone_pair
            on public.students (teacher_id, phone, parent_phone)
            where teacher_id is not null;

        raise notice 'created partial unique index uq_students_teacher_phone_pair';
    else
        raise notice 'equivalent scoped partial unique index already exists exactly once — skipped (idempotent)';
    end if;
end
$idx$;

-- ============================================================
-- SECTION 5 — update_student_scoped RPC
--   SECURITY DEFINER. Cross-tenant mismatch returns false and does
--   NOT reveal whether the student exists under another teacher.
--   teacher_id is NEVER an updatable column here.
-- ============================================================
create or replace function public.update_student_scoped(
    p_registration_code text,
    p_student_id        text,
    p_name              text,
    p_phone             text,
    p_parent_phone      text
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
           last_activity = now()
     where s.student_id = p_student_id
       and s.teacher_id = v_teacher;

    get diagnostics v_updated = row_count;

    -- 5.3 safe result: false = "no scoped update occurred".
    --     No distinction between "not mine" and "does not exist".
    return v_updated > 0;
end
$fn$;

revoke all on function public.update_student_scoped(text, text, text, text, text) from public;
grant execute on function public.update_student_scoped(text, text, text, text, text) to anon, authenticated;

-- ============================================================
-- SECTION 6 — CHILD OWNERSHIP STAMPING
--   SECURITY DEFINER trigger function + 3 BEFORE INSERT triggers.
--   * child.teacher_id is OVERWRITTEN with the parent student's
--     teacher_id (client-supplied values are never trusted)
--   * NULL parent ownership -> child stays NULL (legacy preserved)
--   * existing rows are never touched (INSERT-only trigger)
-- ============================================================
create or replace function public.nx_stamp_child_teacher()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
    v_parent_teacher public.students.teacher_id%type;
begin
    select s.teacher_id
      into v_parent_teacher
      from public.students s
     where s.student_id = new.student_id
     limit 1;

    new.teacher_id := v_parent_teacher;   -- parent's value, or NULL
    return new;
end
$fn$;

revoke all on function public.nx_stamp_child_teacher() from public;

do $triggers$
declare
    v_t text;
begin
    foreach v_t in array array[
        'student_activities',
        'student_results',
        'student_certificates'
    ] loop
        if not exists (
            select 1 from pg_catalog.pg_trigger
             where tgrelid = ('public.' || v_t)::regclass
               and tgname  = 'trg_stamp_child_teacher'
               and not tgisinternal
        ) then
            execute format(
                'create trigger trg_stamp_child_teacher
                   before insert on public.%I
                   for each row
                   execute function public.nx_stamp_child_teacher()',
                v_t
            );
            raise notice 'trigger created: trg_stamp_child_teacher on public.%', v_t;
        else
            raise notice 'trigger already exists on public.% — skipped (idempotent)', v_t;
        end if;
    end loop;
end
$triggers$;

-- ============================================================
-- SECTION 7 — COLUMN-LEVEL INSERT LOCKDOWN
--   PostgreSQL semantics: a TABLE-level INSERT grant subsumes ALL
--   columns, so merely revoking INSERT(teacher_id) would be a NO-OP.
--   The effective lockdown is therefore:
--     1) REVOKE table-level INSERT from anon/authenticated
--     2) GRANT column-level INSERT on every column EXCEPT teacher_id
--   PostgREST always emits an explicit column list (the payload
--   keys), so:
--     * current frontend inserts (no teacher_id in payload) keep
--       working unchanged
--     * any payload that includes teacher_id -> permission denied
--   SECURITY DEFINER RPCs are unaffected (owner privileges).
--   Idempotent: skipped if the lockdown state is already correct.
-- ============================================================
do $lockdown$
declare
    v_t            text;
    v_cols         text;
    v_table_grant  boolean;
    v_col_grant    boolean;
begin
    foreach v_t in array array[
        'students',
        'student_results',
        'student_activities',
        'student_certificates'
    ] loop
        -- does anon/authenticated still hold TABLE-level INSERT?
        select exists (
            select 1 from information_schema.table_privileges
             where table_schema = 'public'
               and table_name   = v_t
               and privilege_type = 'INSERT'
               and grantee in ('anon', 'authenticated')
        ) into v_table_grant;

        -- is teacher_id (wrongly) column-granted for INSERT?
        select exists (
            select 1 from information_schema.column_privileges
             where table_schema = 'public'
               and table_name   = v_t
               and column_name  = 'teacher_id'
               and privilege_type = 'INSERT'
               and grantee in ('anon', 'authenticated')
        ) into v_col_grant;

        if v_table_grant or v_col_grant then
            -- 1) drop the table-level authority entirely
            execute format(
                'revoke insert on public.%I from anon, authenticated',
                v_t
            );

            -- 2) re-grant column-level INSERT on all columns EXCEPT
            --    teacher_id (derived from the live catalog — nothing
            --    assumed; the frontend keeps its current capability)
            select string_agg(
                       quote_ident(column_name), ', '
                       order by ordinal_position
                   )
              into v_cols
              from information_schema.columns
             where table_schema = 'public'
               and table_name   = v_t
               and column_name <> 'teacher_id';

            if v_cols is null then
                raise exception 'BLOCKED: no insertable columns found for public.% — aborting lockdown for this table.', v_t;
            end if;

            execute format(
                'grant insert (%s) on public.%I to anon, authenticated',
                v_cols, v_t
            );

            raise notice 'lockdown applied on public.%: table INSERT revoked; column INSERT granted on all columns except teacher_id', v_t;
        else
            raise notice 'lockdown already in place on public.% — skipped (idempotent)', v_t;
        end if;
    end loop;
end
$lockdown$;

commit;

-- ============================================================
-- END OF X.4-A MIGRATION
-- Post-execution verification: run the companion READ-ONLY file
--   supabase/migrations/20260910_phaseX4A_verification.sql
-- ============================================================
