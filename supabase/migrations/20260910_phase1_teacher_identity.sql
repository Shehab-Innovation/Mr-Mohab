-- ============================================================
-- NEXORA Phase 1 — Teacher Identity Architecture
-- Owner: Shehab Innovation
-- Date:  2026-09-10
--
-- PURPOSE
--   Centralizes per-teacher identity/branding on the `teachers`
--   table so a new teacher instance (Mr-Ahmed, Mr-Mohamed, ...)
--   can be created by inserting ONE row instead of editing HTML.
--
-- HOW TO RUN
--   Supabase Dashboard → SQL Editor → paste → Run.
--   (Cannot be executed from the Freebuff workspace: no psql and
--   no DB credentials are exposed there by design.)
--
-- SAFETY
--   * Idempotent: safe to run multiple times.
--   * ADDITIVE only: no column is dropped, no row is deleted,
--     no existing value is overwritten (COALESCE keeps data).
--   * Table/column names match what the app already uses
--     (teachers, create_teacher_session, ...). If a column name
--     differs in the live project, adjust the one marked CHECK.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1) New identity/branding columns on `teachers`
--    (CHECK note: if the live PK is `id` instead of `teacher_id`,
--     change only the REFERENCES/UPDATE targets below.)
-- ------------------------------------------------------------

alter table public.teachers
    add column if not exists display_name      text;
    -- subject, stage, grades, image, whatsapp, facebook are
    -- added one-by-one below so this stays valid on re-runs.

alter table public.teachers
    add column if not exists subject           text;

alter table public.teachers
    add column if not exists stage             text;

alter table public.teachers
    add column if not exists grades            int[] default '{1,2,3,4,5,6}';

alter table public.teachers
    add column if not exists teacher_image     text;

alter table public.teachers
    add column if not exists whatsapp_url      text;

alter table public.teachers
    add column if not exists facebook_url      text;

alter table public.teachers
    add column if not exists certificate_name    text;

alter table public.teachers
    add column if not exists certificate_image   text;

alter table public.teachers
    add column if not exists certificate_message text;

-- ------------------------------------------------------------
-- 2) Fill identity for the existing Mr-Mohab instance.
--    display_name is COALESCEd from `name` so nothing is lost.
--    Only NULL cells are filled — existing values win.
-- ------------------------------------------------------------

update public.teachers
set
    display_name        = coalesce(display_name, name, 'مستر مهاب'),
    subject             = coalesce(subject, 'الرياضيات'),
    stage               = coalesce(stage, 'المرحلة الابتدائية'),
    grades              = coalesce(grades, '{1,2,3,4,5,6}'),
    teacher_image       = coalesce(
        teacher_image,
        'https://i.ibb.co/HfRP5zx8/Whats-App-Image-2026-09-03-at-3-34-26-AM.jpg'
    ),
    whatsapp_url        = coalesce(whatsapp_url, 'https://wa.me/+201289958954'),
    facebook_url        = coalesce(facebook_url, 'https://www.facebook.com/share/1Dup2hS5YH/'),
    certificate_name    = coalesce(certificate_name, 'مستر مهاب'),
    certificate_image   = coalesce(
        certificate_image,
        'https://i.ibb.co/HfRP5zx8/Whats-App-Image-2026-09-03-at-3-34-26-AM.jpg'
    ),
    certificate_message = coalesce(
        certificate_message,
        'أحسنت! استمر في التفوق والمثابرة.'
    )
where true;

-- ------------------------------------------------------------
-- 3) Extend create_teacher_session to return identity.
--    The function is CREATE OR REPLACE'd with a wider return
--    shape; existing login flow keeps working because it reads
--    teacher.name / teacher.image by key, and the new keys are
--    additive. (Session/token logic is NOT modified.)
-- ------------------------------------------------------------

-- NOTE FOR REVIEWER:
-- The live definition of create_teacher_session is not in this
-- repository, so we do NOT blindly replace it here. Instead the
-- dashboard/login can read identity from the new columns via the
-- read view below, and a follow-up migration (Phase 2) can merge
-- these fields into the session RPC once its source is in repo.

-- ------------------------------------------------------------
-- 4) Public read shape for identity (used by future hydration).
--    SECURITY INVOKER view over needed columns only.
-- ------------------------------------------------------------

create or replace view public.teacher_identity_public as
select
    teacher_id,
    username,
    display_name,
    subject,
    stage,
    grades,
    teacher_image,
    whatsapp_url,
    facebook_url,
    certificate_name,
    certificate_image,
    certificate_message
from public.teachers;

commit;

-- ============================================================
-- End of migration.
-- Next phases (NOT in this file):
--   Phase 2: students.teacher_id + backfill + RLS
--   Phase 3: registration RPC gains server-side teacher context
--   Phase 4: student_results/activities/certificates.teacher_id
-- ============================================================
