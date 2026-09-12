-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

do $mig$
declare
  v_def text := pg_get_functiondef(
    'qvm_new_apps.uploaded_records_get(text,text,text,integer,integer)'::regprocedure);
  -- Every row now says how it got here. `entry_source` and not `origin`: purchases already
  -- publishes an `origin` meaning something else entirely (excel / ERP / quoted-not-bought),
  -- and quietly reusing the name would have replaced one fact with another.
  v_pairs text[][] := array[
    array['                 ''updated_at'', a.updated_at, ''batch_id'', a.batch_id) as x,',
          '                 ''updated_at'', a.updated_at, ''batch_id'', a.batch_id,
                 ''entry_source'', case when a.batch_id is null then ''manual'' else ''file'' end,
                 ''entry_file'', (select b.file_name from qvm_new_apps.upload_batches b
                                   where b.batch_id = a.batch_id)) as x,'],
    array['                 ''updated_at'', i.updated_at, ''batch_id'', i.batch_id) as x,',
          '                 ''updated_at'', i.updated_at, ''batch_id'', i.batch_id,
                 ''entry_source'', case when i.batch_id is null then ''manual'' else ''file'' end,
                 ''entry_file'', (select b.file_name from qvm_new_apps.upload_batches b
                                   where b.batch_id = i.batch_id)) as x,'],
    array['                 ''origin'', h.origin, ''batch_id'', h.batch_id) as x,',
          '                 ''origin'', h.origin, ''batch_id'', h.batch_id,
                 ''entry_source'', case when h.batch_id is null then ''manual'' else ''file'' end,
                 ''entry_file'', (select b.file_name from qvm_new_apps.upload_batches b
                                   where b.batch_id = h.batch_id)) as x,'],
    array['                 ''make'', al.brand, ''note'', al.note, ''batch_id'', al.batch_id) as x,',
          '                 ''make'', al.brand, ''note'', al.note, ''batch_id'', al.batch_id,
                 ''entry_source'', case when al.batch_id is null then ''manual'' else ''file'' end,
                 ''entry_file'', (select b.file_name from qvm_new_apps.upload_batches b
                                   where b.batch_id = al.batch_id)) as x,']
  ];
  i integer;
begin
  for i in 1 .. array_length(v_pairs, 1) loop
    if position(v_pairs[i][1] in v_def) = 0 then
      raise exception 'anchor % not found', i;
    end if;
    v_def := replace(v_def, v_pairs[i][1], v_pairs[i][2]);
  end loop;
  execute v_def;
end
$mig$;
