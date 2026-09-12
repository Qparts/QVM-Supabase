-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

do $mig$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.uploaded_record_update(text,bigint,jsonb)'::regprocedure);
  v_old text := '      agency_price   = case when p_patch ? ''price'' then nullif(btrim(p_patch->>''price''),'''')::numeric else agency_price end,';
  v_new text;
begin
  if position(v_old in v_def) = 0 then
    raise exception 'anchor line not found';
  end if;

  v_new := v_old || E'\n' ||
'      part_class     = case when p_patch ? ''part_class'' then nullif(btrim(p_patch->>''part_class''),'''') else part_class end,' || E'\n' ||
'      dealer_agency_discount_pct = case when p_patch ? ''discount_pct'' then nullif(btrim(p_patch->>''discount_pct''),'''')::numeric else dealer_agency_discount_pct end,' || E'\n' ||
'      -- The net price and the two numbers it comes from are only meaningful together. Correcting the' || E'\n' ||
'      -- gross price or the discount on its own would otherwise leave a net that matches neither, so' || E'\n' ||
'      -- the number the person did not touch follows the one they did.' || E'\n' ||
'      agency_price_after_discount = case' || E'\n' ||
'        when p_patch ? ''price_after_discount'' then nullif(btrim(p_patch->>''price_after_discount''),'''')::numeric' || E'\n' ||
'        when (p_patch ? ''price'' or p_patch ? ''discount_pct'')' || E'\n' ||
'             and coalesce(nullif(btrim(p_patch->>''discount_pct''),'''')::numeric, dealer_agency_discount_pct) is not null' || E'\n' ||
'             and coalesce(nullif(btrim(p_patch->>''price''),'''')::numeric, agency_price) is not null' || E'\n' ||
'          then round(coalesce(nullif(btrim(p_patch->>''price''),'''')::numeric, agency_price)' || E'\n' ||
'                     * (1 - coalesce(nullif(btrim(p_patch->>''discount_pct''),'''')::numeric, dealer_agency_discount_pct) / 100), 2)' || E'\n' ||
'        else agency_price_after_discount end,';

  execute replace(v_def, v_old, v_new);
end
$mig$;
