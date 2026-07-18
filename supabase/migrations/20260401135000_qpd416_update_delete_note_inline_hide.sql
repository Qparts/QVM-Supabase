BEGIN;

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
      deleted_by = COALESCE(auth.uid(), deleted_by),
      -- Also flip is_internal to true so existing dashboard filters hide it without changing RPC
      is_internal = true
  WHERE note_id = p_note_id;

  RETURN jsonb_build_object('status','success','message','Note soft-deleted','note_id', p_note_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.delete_note_inline(integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.delete_note_inline(integer) TO authenticated;

COMMIT;
