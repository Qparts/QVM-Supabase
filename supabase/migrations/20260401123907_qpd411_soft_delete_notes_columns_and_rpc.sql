-- Synced from QVM/test branch applied migration history (version 20260401123907, name: qpd411_soft_delete_notes_columns_and_rpc)
BEGIN;

ALTER TABLE qvm_new_apps.notes
  ADD COLUMN IF NOT EXISTS is_deleted boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS deleted_by uuid NULL;

CREATE OR REPLACE FUNCTION public.delete_note_inline(
  p_note_id integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_exists boolean;
BEGIN
  SELECT EXISTS(SELECT 1 FROM qvm_new_apps.notes WHERE note_id = p_note_id)
  INTO v_exists;

  IF NOT v_exists THEN
    RETURN jsonb_build_object('status','error','message','Note not found','note_id', p_note_id);
  END IF;

  UPDATE qvm_new_apps.notes
  SET is_deleted = true,
      deleted_at = now(),
      deleted_by = COALESCE(auth.uid(), deleted_by)
  WHERE note_id = p_note_id;

  RETURN jsonb_build_object('status','success','message','Note soft-deleted','note_id', p_note_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.delete_note_inline(integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.delete_note_inline(integer) TO authenticated;

COMMIT;;
