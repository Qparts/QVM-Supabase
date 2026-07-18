-- Public Wrapper: public.fetch_notes
-- Description: Public wrapper for fetch_notes function with proper security
-- This function provides a safe public interface to the internal fetch_notes function
-- Parameters:
--   p_note_type: The type of note (e.g., 'quotation_items', 'orders', etc.)
--   p_type_id: The ID of the entity the notes belong to
--   p_is_internal: Optional filter for internal/external notes (null = all)

create or replace function public.fetch_notes(
  p_note_type text,
  p_type_id bigint,
  p_is_internal boolean default null
)
returns table (
  note_id bigint,
  note_description text,
  note_attachment text,
  created_at timestamptz,
  user_name text,
  user_id uuid,
  is_internal boolean
)
language sql
stable
security definer
set search_path = public, qvm_new_apps
as $$
  select *
  from qvm_new_apps.fetch_notes(
    p_note_type,
    p_type_id,
    p_is_internal
  );
$$;
