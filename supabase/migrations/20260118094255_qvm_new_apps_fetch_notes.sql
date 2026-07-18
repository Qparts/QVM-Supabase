-- Function: qvm_new_apps.fetch_notes
-- Description: Fetches notes with user information based on note type and type ID
-- Parameters:
--   p_note_type: The type of note (e.g., 'quotation_items', 'orders', etc.)
--   p_type_id: The ID of the entity the notes belong to
--   p_is_internal: Optional filter for internal/external notes (null = all)

create or replace function qvm_new_apps.fetch_notes(
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
as $$
  select
    n.note_id,
    n.note_description,
    n.note_attachment,
    n.created_at,
    u.user_name,
    n.user_id,
    n.is_internal
  from qvm_new_apps.notes n
  left join qvm_new_apps.user_data u
    on u.user_id = n.user_id
  where n.note_type = p_note_type
    and n.type_id = p_type_id
    and (p_is_internal is null or n.is_internal = p_is_internal)
  order by n.created_at desc;
$$;
