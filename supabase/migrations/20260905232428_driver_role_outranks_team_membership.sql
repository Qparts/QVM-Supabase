-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

do $mig$
declare
  v_def text;
  v_old text;
begin
  -- A driver is a user with the Driver role, and Open Decision 2 puts that role under the
  -- Qparts Team user type — which makes is_qparts_team() true for every driver. Checking team
  -- first therefore handed each driver the entire board. Being a driver is the more specific
  -- fact and has to win: the role says what this person does, the user type only says who
  -- employs them.
  v_def := pg_get_functiondef('qvm_new_apps.shipments_board(integer,integer,text,integer,integer)'::regprocedure);
  v_old := '  if not (v_team or v_vendor is not null or v_is_driver) then';
  if position(v_old in v_def) = 0 then raise exception 'board guard not found'; end if;
  v_def := replace(v_def, v_old,
'  -- Being a driver is the more specific fact about a person than being on the team, so it
  -- decides what they see. Otherwise every driver reads as team and the board stops being
  -- «my jobs» the moment somebody is both.
  if v_is_driver then
    v_team := false;
    v_vendor := null;
  end if;

  if not (v_team or v_vendor is not null or v_is_driver) then');
  execute v_def;

  -- Same reasoning on the tracking page: a driver may see the shipment they are carrying,
  -- and only that one.
  v_def := pg_get_functiondef('qvm_new_apps.shipment_track(bigint,integer)'::regprocedure);
  v_old := '  v_vendor integer := qvm_new_apps.current_upload_vendor_id();';
  if position(v_old in v_def) = 0 then raise exception 'track declare not found'; end if;
  v_def := replace(v_def, v_old, v_old || E'\n  v_is_driver boolean;');

  v_old := '  if v_uid is null then
    return jsonb_build_object(''status'', false, ''message'', ''forbidden'', ''data'', null);
  end if;';
  if position(v_old in v_def) = 0 then raise exception 'track guard not found'; end if;
  v_def := replace(v_def, v_old, v_old || E'\n\n' ||
'  select exists (
    select 1 from qvm_new_apps.user_data u
     join qvm_new_apps.list_data d on d.list_data_id = u.user_role
    where u.user_id = v_uid and d.list_id = 16 and d.list_data = ''Driver'')
  into v_is_driver;

  if v_is_driver then
    v_team := false;
    v_vendor := null;
  end if;');
  execute v_def;
end
$mig$;
