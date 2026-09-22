-- ============================================================
-- NEXORA Phase N4 — Mobile Web Push layer
-- ============================================================
-- Separate push layer over N1/N2/N3 (NO changes to them):
--   * push_subscriptions table (owner-keyed, endpoint-unique)
--   * RLS enabled, zero policies, privileges revoked from
--     anon/authenticated -> access ONLY via SECDEF RPCs below
--   * teacher RPCs: session-token identity (N1 pattern)
--   * student RPCs: phone+parent_phone identity (X9 pattern)
--   * database hook: AFTER INSERT ON notifications -> pg_net
--     POST to the nx_push_sender Edge Function, authenticated
--     with a stored hook secret. Push failure NEVER affects
--     notification creation (hook swallows all errors).
--
-- Re-runnable. No data changes.
-- HOW TO RUN: Supabase Dashboard -> SQL Editor -> paste -> Run.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- Guard: prerequisites must exist, else fail closed.
-- ------------------------------------------------------------
do $guard$
declare
    v_missing text := '';
begin
    if not exists (
        select 1 from information_schema.tables
         where table_schema='public' and table_name='notifications'
    ) then
        v_missing := 'notifications table (run N1 first)';
    end if;

    if v_missing = '' and not exists (
        select 1 from pg_extension where extname='pgcrypto'
    ) then
        v_missing := 'pgcrypto extension';
    end if;

    if v_missing <> '' then
        raise exception 'BLOCKED: %. No changes committed.', v_missing;
    end if;
end
$guard$;

-- ------------------------------------------------------------
-- 1. push_subscriptions table
-- ------------------------------------------------------------
create table if not exists public.push_subscriptions (
    id          uuid primary key default gen_random_uuid(),
    teacher_id  text null references public.teachers(teacher_id) on delete cascade,
    student_id  text null,
    endpoint    text not null,
    p256dh      text not null,
    auth        text not null,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    constraint push_subs_owner_check check (
        (teacher_id is not null and student_id is null)
        or (teacher_id is null and student_id is not null)
    )
);

create unique index if not exists uq_push_subscriptions_endpoint
    on public.push_subscriptions (endpoint);

create index if not exists idx_push_subs_teacher
    on public.push_subscriptions (teacher_id) where teacher_id is not null;

create index if not exists idx_push_subs_student
    on public.push_subscriptions (student_id) where student_id is not null;

alter table public.push_subscriptions enable row level security;

revoke all on public.push_subscriptions from anon;
revoke all on public.push_subscriptions from authenticated;

-- ------------------------------------------------------------
-- 2. Hook secret storage (server-side only). Deno secrets hold
--    the value; this table keeps the SAME value for the trigger
--    to authenticate with. Not readable by anon/authenticated.
-- ------------------------------------------------------------
create table if not exists public.nx_push_hook_secrets (
    id         integer primary key default 1 check (id = 1),
    hook_secret text not null,
    updated_at timestamptz not null default now()
);

revoke all on public.nx_push_hook_secrets from anon;
revoke all on public.nx_push_hook_secrets from authenticated;

insert into public.nx_push_hook_secrets (id, hook_secret)
values (1, current_setting('app.nx_hook_secret', true))
on conflict (id) do nothing;

do $seed$
declare
    v_secret text;
begin
    select hook_secret into v_secret from public.nx_push_hook_secrets where id = 1;
    if v_secret is null or length(v_secret) < 30 then
        raise exception 'BLOCKED: set hook secret first with: select set_config(''app.nx_hook_secret'', ''<secret>'', false); before running this migration.';
    end if;
end
$seed$;

-- ------------------------------------------------------------
-- 3. TEACHER subscription RPCs (session-token identity)
-- ------------------------------------------------------------
create or replace function public.nx_teacher_id_from_session(p_session_token text)
returns text
language plpgsql stable security definer set search_path = ''
as $fn$
declare v_teacher_id text;
begin
    select ts.teacher_id into v_teacher_id
      from public.teacher_sessions ts
     where ts.token_hash = encode(extensions.digest(p_session_token, 'sha256'), 'hex')
       and ts.expires_at > now()
     limit 1;
    return v_teacher_id;
end;
$fn$;

create or replace function public.save_teacher_push_subscription(
    p_session_token text,
    p_endpoint      text,
    p_p256dh        text,
    p_auth          text
)
returns integer
language plpgsql volatile security definer set search_path = ''
as $fn$
declare
    v_teacher_id text;
begin
    select public.nx_teacher_id_from_session(p_session_token) into v_teacher_id;
    if v_teacher_id is null then
        return 0; -- fail closed
    end if;

    if coalesce(p_endpoint,'') = '' or coalesce(p_p256dh,'') = '' or coalesce(p_auth,'') = ''
       or length(p_endpoint) > 1000 or length(p_p256dh) > 200 or length(p_auth) > 200 then
        return 0;
    end if;

    insert into public.push_subscriptions (teacher_id, student_id, endpoint, p256dh, auth)
    values (v_teacher_id, null, p_endpoint, p_p256dh, p_auth)
    on conflict (endpoint) do update
        set teacher_id = excluded.teacher_id,
            student_id = null,
            p256dh     = excluded.p256dh,
            auth       = excluded.auth,
            updated_at = now();

    return 1;
end;
$fn$;

create or replace function public.delete_teacher_push_subscription(
    p_session_token text,
    p_endpoint      text
)
returns integer
language plpgsql volatile security definer set search_path = ''
as $fn$
declare v_teacher_id text; v_deleted integer;
begin
    select public.nx_teacher_id_from_session(p_session_token) into v_teacher_id;
    if v_teacher_id is null then return 0; end if;

    delete from public.push_subscriptions
     where teacher_id = v_teacher_id and endpoint = p_endpoint;
    get diagnostics v_deleted = row_count;
    return v_deleted;
end;
$fn$;

create or replace function public.get_teacher_push_subscriptions(p_session_token text)
returns table (endpoint text, created_at timestamptz)
language sql stable security definer set search_path = ''
as $fn$
    select ps.endpoint::text, ps.created_at
      from public.push_subscriptions ps
     where ps.teacher_id = public.nx_teacher_id_from_session(p_session_token)
       and ps.teacher_id is not null;
$fn$;

-- ------------------------------------------------------------
-- 4. STUDENT subscription RPCs (phone-pair identity, X9 pattern)
-- ------------------------------------------------------------
create or replace function public.save_student_push_subscription(
    p_phone        text,
    p_parent_phone text,
    p_endpoint     text,
    p_p256dh       text,
    p_auth         text
)
returns integer
language plpgsql volatile security definer set search_path = ''
as $fn$
declare
    v_student_id text;
begin
    select s.student_id::text into v_student_id
      from public.students s
     where s.phone::text = p_phone
       and s.parent_phone::text = p_parent_phone
     limit 1;

    if v_student_id is null then
        return 0; -- fail closed (unknown identity)
    end if;

    if coalesce(p_endpoint,'') = '' or coalesce(p_p256dh,'') = '' or coalesce(p_auth,'') = ''
       or length(p_endpoint) > 1000 or length(p_p256dh) > 200 or length(p_auth) > 200 then
        return 0;
    end if;

    insert into public.push_subscriptions (teacher_id, student_id, endpoint, p256dh, auth)
    values (null, v_student_id, p_endpoint, p_p256dh, p_auth)
    on conflict (endpoint) do update
        set student_id = excluded.student_id,
            teacher_id = null,
            p256dh     = excluded.p256dh,
            auth       = excluded.auth,
            updated_at = now();

    return 1;
end;
$fn$;

create or replace function public.delete_student_push_subscription(
    p_phone        text,
    p_parent_phone text,
    p_endpoint     text
)
returns integer
language plpgsql volatile security definer set search_path = ''
as $fn$
declare v_student_id text; v_deleted integer;
begin
    select s.student_id::text into v_student_id
      from public.students s
     where s.phone::text = p_phone
       and s.parent_phone::text = p_parent_phone
     limit 1;
    if v_student_id is null then return 0; end if;

    delete from public.push_subscriptions
     where student_id = v_student_id and endpoint = p_endpoint;
    get diagnostics v_deleted = row_count;
    return v_deleted;
end;
$fn$;

create or replace function public.get_student_push_subscriptions(
    p_phone        text,
    p_parent_phone text
)
returns table (endpoint text, created_at timestamptz)
language sql stable security definer set search_path = ''
as $fn$
    select ps.endpoint::text, ps.created_at
      from public.push_subscriptions ps
     where ps.student_id::text in (
            select s.student_id::text from public.students s
             where s.phone::text = p_phone and s.parent_phone::text = p_parent_phone
           );
$fn$;

-- ------------------------------------------------------------
-- 5. Server-side lookup for the sender (service_role only)
--    + dead-endpoint delete (service_role only).
--    teacher_id resolved from students when recipient is a
--    student (ownership inheritance like N2).
-- ------------------------------------------------------------
create or replace function public.nx_push_subscriptions_for_recipient(
    p_recipient_type text,
    p_recipient_id   text
)
returns table (endpoint text, p256dh text, auth text)
language sql stable security definer set search_path = ''
as $fn$
    select ps.endpoint::text, ps.p256dh::text, ps.auth::text
      from public.push_subscriptions ps
     where (p_recipient_type = 'teacher'
            and ps.teacher_id = p_recipient_id)
        or (p_recipient_type = 'student'
            and ps.student_id = p_recipient_id);
$fn$;

create or replace function public.nx_push_subscription_delete(p_endpoint text)
returns integer
language plpgsql volatile security definer set search_path = ''
as $fn$
declare v_deleted integer;
begin
    delete from public.push_subscriptions where endpoint = p_endpoint;
    get diagnostics v_deleted = row_count;
    return v_deleted;
end;
$fn$;

-- ------------------------------------------------------------
-- 6. Database hook: notifications insert -> pg_net POST to the
--    Edge Function. Errors swallowed (push never blocks N2).
-- ------------------------------------------------------------
create or replace function public.nx_push_hook()
returns trigger
language plpgsql security definer set search_path = ''
as $fn$
declare
    v_secret text;
    v_guts   jsonb;
begin
    select hook_secret into v_secret from public.nx_push_hook_secrets where id = 1;

    v_guts := jsonb_build_object(
        'record', to_jsonb(new)
    );

    begin
        perform net.http_post(
            url     := 'https://bbiflvdwardvozjvrsya.supabase.co/functions/v1/nx_push_sender',
            headers := jsonb_build_object(
                'Content-Type', 'application/json',
                'x-nexora-hook', v_secret
            ),
            body    := v_guts,
            timeout_milliseconds := 5000
        );
    exception when others then
        null; -- push failure must never break notification creation
    end;

    return null;
end;
$fn$;

drop trigger if exists trg_nx_push_hook on public.notifications;
create trigger trg_nx_push_hook
    after insert on public.notifications
    for each row execute function public.nx_push_hook();

-- ------------------------------------------------------------
-- 7. Grants: only the RPCs are reachable by clients. The
--    service-role lookup + hook helper are revoked from anon
--    and granted to service_role.
-- ------------------------------------------------------------
revoke all on function public.nx_teacher_id_from_session(text) from public;
revoke execute on function public.nx_teacher_id_from_session(text) from anon, authenticated;

revoke all on function public.nx_push_subscriptions_for_recipient(text, text) from public;
revoke execute on function public.nx_push_subscriptions_for_recipient(text, text) from anon, authenticated;
grant execute on function public.nx_push_subscriptions_for_recipient(text, text) to service_role;

revoke all on function public.nx_push_subscription_delete(text) from public;
revoke execute on function public.nx_push_subscription_delete(text) from anon, authenticated;
grant execute on function public.nx_push_subscription_delete(text) to service_role;

revoke all on function public.save_teacher_push_subscription(text, text, text, text) from public;
revoke all on function public.delete_teacher_push_subscription(text, text) from public;
revoke all on function public.get_teacher_push_subscriptions(text) from public;
revoke all on function public.save_student_push_subscription(text, text, text, text, text) from public;
revoke all on function public.delete_student_push_subscription(text, text, text) from public;
revoke all on function public.get_student_push_subscriptions(text, text) from public;

grant execute on function public.save_teacher_push_subscription(text, text, text, text) to anon, authenticated;
grant execute on function public.delete_teacher_push_subscription(text, text) to anon, authenticated;
grant execute on function public.get_teacher_push_subscriptions(text) to anon, authenticated;
grant execute on function public.save_student_push_subscription(text, text, text, text, text) to anon, authenticated;
grant execute on function public.delete_student_push_subscription(text, text, text) to anon, authenticated;
grant execute on function public.get_student_push_subscriptions(text, text) to anon, authenticated;

commit;

-- ============================================================
-- Enable pg_net (outside the transaction; not supported inside).
-- Run this statement right after the migration:
--     create extension if not exists pg_net;
-- ============================================================
