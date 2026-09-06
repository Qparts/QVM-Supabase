-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- Every template describes a part from somewhere; the catalog is where the part itself lives, so
-- every published row feeds it. Rows too thin to identify a part (no number, no make) are skipped
-- inside absorb rather than half-entered.
do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='qvm_new_apps' and p.proname='upload_batch_write_rows';
  if strpos(v_def, 'parts_catalog_absorb') > 0 then
    raise notice 'already wired';
    return;
  end if;

  v_def := replace(v_def,
'  else
    raise exception ''نوع ملف غير مدعوم للنشر: %'', v_b.template_key;
  end if;

  return v_written;',
'  else
    raise exception ''نوع ملف غير مدعوم للنشر: %'', v_b.template_key;
  end if;

  perform qvm_new_apps.parts_catalog_absorb(
            r.clean_part_number, r.brand, r.part_class, r.country_of_origin,
            r.clean_name, r.clean_name_en,
            case when v_b.source_kind = ''vendor'' then ''vendor'' else null end,
            v_b.source_id)
     from qvm_new_apps.upload_rows r
    where r.batch_id = p_batch_id and r.state = ''ready'';

  return v_written;');

  if strpos(v_def, 'parts_catalog_absorb') = 0 then
    raise exception 'the anchor for the catalog call was not found';
  end if;
  execute v_def;
end $$;
