-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

do $mig$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.uploaded_record_create(text,jsonb)'::regprocedure);
  v_old text;
  v_n integer;
begin
  v_old := '  v_num numeric;';
  if position(v_old in v_def) = 0 then raise exception 'declare line not found'; end if;
  v_def := replace(v_def, v_old, v_old || E'\n' ||
'  v_clean jsonb;
  v_brand text; v_class text; v_country text;');

  -- The whole cleaning policy, not just the separator and case part of it. A prefix the
  -- supplier puts on their numbers is theirs, not part of the part number, and it is taken
  -- off a typed number exactly as it is taken off an imported one — otherwise the same part
  -- sits under two keys depending on how somebody happened to enter it.
  v_old := '  -- The same normalisation an imported row goes through. A number typed here and the same
  -- number arriving in tomorrow''s file have to land on one row, not two.
  v_pn := qvm_new_apps.normalize_part_number(v_pn_raw);
  if v_pn is null then';
  if position(v_old in v_def) = 0 then raise exception 'normalize line not found'; end if;
  v_def := replace(v_def, v_old,
'  -- The same cleaning an imported row goes through — code rules included. A number typed
  -- here and the same number arriving in tomorrow''s file have to land on one row, not two.
  v_clean := qvm_new_apps.upload_clean_part_number(
               v_pn_raw, p_kind, ''vendor'',
               case when v_team then nullif(p_data->>''vendor_id'','''')::bigint
                    else v_vendor::bigint end);
  v_pn := v_clean->>''clean_part_number'';
  -- What the matched rule says about the part. It fills gaps and never argues with a value
  -- the person typed: they have the part in front of them, the rule is a generalisation.
  v_brand   := coalesce(nullif(btrim(coalesce(p_data->>''make'','''')), ''''), v_clean->>''brand'');
  v_class   := coalesce(nullif(btrim(coalesce(p_data->>''part_class'','''')), ''''), v_clean->>''part_class'');
  v_country := coalesce(nullif(btrim(coalesce(p_data->>''country'','''')), ''''), v_clean->>''country_of_origin'');
  if v_pn is null then');

  -- Everywhere those three were read straight off the payload, they now come from the
  -- variables that already folded the rule in.
  v_def := replace(v_def, 'nullif(btrim(coalesce(p_data->>''make'','''')), '''')', 'v_brand');
  v_def := replace(v_def, 'nullif(btrim(coalesce(p_data->>''part_class'','''')), '''')', 'v_class');
  v_def := replace(v_def, 'nullif(btrim(coalesce(p_data->>''country'','''')), '''')', 'v_country');

  execute v_def;

  select count(*) into v_n
    from pg_get_functiondef('qvm_new_apps.uploaded_record_create(text,jsonb)'::regprocedure) d,
         lateral unnest(string_to_array(d, E'\n')) t(l)
   where l like '%p_data->>''make''%' and l not like '%v_brand :=%';
  if v_n > 0 then raise exception 'a raw make reference survived: % lines', v_n; end if;
end
$mig$;

drop function if exists qvm_new_apps.zz_clean_row_prev(jsonb, text, text, bigint);
