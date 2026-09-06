-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

do $mig$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.shipment_create(jsonb)'::regprocedure);
  v_old text;
begin
  -- The code called nextval on the identity's own sequence, so every insert consumed two
  -- values and the printed code ran ahead of the id it names. They are the same shipment and
  -- must read as the same shipment, so the code is now stamped from the id the row was
  -- actually given, one update later.
  v_old := '    -- Readable and unique without a second sequence to keep in step.
    ''SHP-'' || to_char(now(), ''YYMM'') || ''-'' || lpad(nextval(''qvm_new_apps.shipments_shipment_id_seq'')::text, 5, ''0''),';
  if position(v_old in v_def) = 0 then raise exception 'code line not found'; end if;
  v_def := replace(v_def, v_old,
'    -- Placeholder; replaced below with a code built from this row''s own id, so the two
    -- can never drift apart the way a second sequence would let them.
    ''SHP-PENDING-'' || gen_random_uuid()::text,');

  v_old := '  returning shipment_id, shipment_code into v_id, v_code;';
  if position(v_old in v_def) = 0 then raise exception 'returning line not found'; end if;
  v_def := replace(v_def, v_old,
'  returning shipment_id into v_id;

  v_code := ''SHP-'' || to_char(now(), ''YYMM'') || ''-'' || lpad(v_id::text, 5, ''0'');
  update qvm_new_apps.shipments set shipment_code = v_code where shipment_id = v_id;');

  execute v_def;
end
$mig$;
