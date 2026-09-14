BEGIN;

-- Phase X.5.3-A
-- Revoke client execution from legacy RPCs.
-- Function bodies are intentionally preserved for rollback.
-- No data, schema, RLS, or frontend changes.

REVOKE EXECUTE
ON FUNCTION public.find_student_by_phone(text, text)
FROM anon, authenticated, PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.update_student_by_phone(text, text, text, text)
FROM anon, authenticated, PUBLIC;

REVOKE EXECUTE
ON FUNCTION public.get_teacher_group_students_by_session(text, uuid)
FROM anon, authenticated, PUBLIC;

COMMIT;
