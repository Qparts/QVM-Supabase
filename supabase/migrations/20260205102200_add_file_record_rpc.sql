BEGIN;

CREATE OR REPLACE FUNCTION public.add_file_record(
  p_module_id bigint,
  p_module_type text,
  p_user_id uuid,
  p_user_type text,
  p_field_id text,
  p_file_path text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_row qvm_new_apps.files%ROWTYPE;
BEGIN
  INSERT INTO qvm_new_apps.files(
    module_id,
    module_type,
    user_id,
    user_type,
    file_path,
    field_id
  ) VALUES (
    p_module_id,
    p_module_type,
    p_user_id,
    p_user_type,
    p_file_path,
    p_field_id
  )
  RETURNING * INTO v_row;

  RETURN to_json(v_row);
END;
$$;

REVOKE ALL ON FUNCTION public.add_file_record(bigint, text, uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.add_file_record(bigint, text, uuid, text, text, text) TO service_role;

COMMIT;
