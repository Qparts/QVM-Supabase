-- Synced from QVM/test branch applied migration history (version 20260625031827, name: create_save_unrecognized_part_name_rpc)

CREATE OR REPLACE FUNCTION qvm_new_apps.save_unrecognized_part_name(
  p_entered_text  TEXT,
  p_request_id    TEXT DEFAULT NULL,
  p_user_id       UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_id BIGINT;
BEGIN
  INSERT INTO qvm_new_apps.unrecognized_part_names (entered_text, request_id, user_id)
  VALUES (p_entered_text, p_request_id, p_user_id)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('status','success','id', v_id);
END;
$$;
;
