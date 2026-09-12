-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

do $mig$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.upload_page_get()'::regprocedure);
  v_old text :=
'      ''part_classes'', jsonb_build_array(
        jsonb_build_object(''key'',''genuine'',''label_en'',''Genuine'',''label_ar'',''أصلي''),
        jsonb_build_object(''key'',''oem'',''label_en'',''OEM'',''label_ar'',''OEM''),
        jsonb_build_object(''key'',''commercial'',''label_en'',''Commercial'',''label_ar'',''تجاري''),
        jsonb_build_object(''key'',''used'',''label_en'',''Used'',''label_ar'',''مستعمل''))';
  v_new text :=
      -- The list the upload templates validate against. «commercial» keeps its key: it is the
      -- Aftermarket rows already stored, and renaming the key would not move them.
'      ''part_classes'', jsonb_build_array(
        jsonb_build_object(''key'',''genuine'',''label_en'',''Genuine'',''label_ar'',''أصلي''),
        jsonb_build_object(''key'',''oem'',''label_en'',''OEM'',''label_ar'',''OEM''),
        jsonb_build_object(''key'',''commercial'',''label_en'',''Aftermarket'',''label_ar'',''تجاري''),
        jsonb_build_object(''key'',''aftermarket_a'',''label_en'',''Aftermarket Grade A'',''label_ar'',''تجاري درجة أولى''),
        jsonb_build_object(''key'',''aftermarket_b'',''label_en'',''Aftermarket Grade B'',''label_ar'',''تجاري درجة ثانية''),
        jsonb_build_object(''key'',''used'',''label_en'',''Used'',''label_ar'',''مستعمل''),
        jsonb_build_object(''key'',''remanufactured'',''label_en'',''Remanufactured'',''label_ar'',''مُجدَّد''))';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'part_classes block not found verbatim';
  end if;
  execute replace(v_def, v_old, v_new);
end
$mig$;
