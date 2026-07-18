-- Synced from QVM/test branch applied migration history (version 20260625030732, name: create_seed_part_dictionary_function)

CREATE OR REPLACE FUNCTION qvm_new_apps.seed_part_dictionary(
  p_main JSONB,
  p_syn  JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_dict_count INT := 0;
  v_syn_count  INT := 0;
  r JSONB;
BEGIN
  FOR r IN SELECT jsonb_array_elements(p_main) LOOP
    INSERT INTO qvm_new_apps.part_dictionary (main_part_code, name_ar, name_en, category_ar, category_en)
    VALUES (r->>'code', r->>'name_ar', r->>'name_en', r->>'cat_ar', r->>'cat_en')
    ON CONFLICT (main_part_code) DO NOTHING;
    v_dict_count := v_dict_count + 1;
  END LOOP;

  FOR r IN SELECT jsonb_array_elements(p_syn) LOOP
    INSERT INTO qvm_new_apps.part_synonyms (synonym_code, synonym_text, main_part_code, source)
    VALUES (r->>'syn_code', r->>'syn_text', r->>'main_code', 'excel_import')
    ON CONFLICT (synonym_code) DO NOTHING;
    v_syn_count := v_syn_count + 1;
  END LOOP;

  RETURN jsonb_build_object('dict_inserted', v_dict_count, 'syn_inserted', v_syn_count);
END;
$$;
;
