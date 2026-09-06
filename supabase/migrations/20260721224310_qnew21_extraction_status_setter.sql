-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.


create or replace function qvm_new_apps.update_quotation_item_extraction_status(
  p_quotation_item_id int, p_extraction_status text)
returns jsonb language plpgsql security definer set search_path to '' as $$
begin
  if auth.uid() is null then
    return jsonb_build_object('status', false, 'message', 'No session', 'data', null);
  end if;
  if p_extraction_status is not null and p_extraction_status not in ('cannot_extract','unclear') then
    return jsonb_build_object('status', false, 'message', 'Invalid status', 'data', null);
  end if;
  update qvm_new_apps.quotation_items set extraction_status = p_extraction_status where quotation_item_id = p_quotation_item_id;
  if not found then
    return jsonb_build_object('status', false, 'message', 'Item not found', 'data', null);
  end if;
  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object('quotation_item_id', p_quotation_item_id, 'extraction_status', p_extraction_status));
end; $$;
grant execute on function qvm_new_apps.update_quotation_item_extraction_status(int,text) to authenticated;
notify pgrst, 'reload schema';
