-- A branch is keyed by customer_id, not list_data_id.
--
-- client_branches has both, and the name of the second one is the trap: list_data_id is a
-- reference into the shared list table, not the branch's own identity. Three of this company's
-- branches — Body and Paint, PCVC, PAC — all carry list_data_id = 1.
--
-- Read back, the settings screen showed three branches with the same id. Written, all three
-- toggles would have collapsed onto one row of carrier_branch_settings: switching Jeddah on would
-- have switched Riyadh on, and switching it off again would have switched both off. The primary
-- key would have hidden it perfectly — one row, no error, wrong answer.
--
-- Nothing had been saved yet, so there is no data to repair; the toggle had not been wired to a
-- screen. Caught by reading the output rather than by a failure, which is the only way this class
-- of bug ever surfaces.
do $do$
declare
  v_def  text := pg_get_functiondef('qvm_new_apps.carrier_settings_get(text,integer)'::regprocedure);
  v_old  text := '           ''branch_id'', b.list_data_id, ''branch_name'', b.branch_name,';
  v_new  text := '           ''branch_id'', b.customer_id, ''branch_name'', b.branch_name,';
  v_old2 text := 'and s.branch_id = b.list_data_id';
  v_new2 text := 'and s.branch_id = b.customer_id';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'carrier_settings_get: expected the branch id once, found %', v_hits;
  end if;
  v_def := replace(v_def, v_old, v_new);

  v_hits := (length(v_def) - length(replace(v_def, v_old2, ''))) / greatest(length(v_old2), 1);
  if v_hits <> 1 then
    raise exception 'carrier_settings_get: expected the settings join once, found %', v_hits;
  end if;
  execute replace(v_def, v_old2, v_new2);
end
$do$;

do $do$
declare
  v_def  text := pg_get_functiondef(
    'qvm_new_apps.carrier_branch_set(text,integer,boolean,text,integer)'::regprocedure);
  v_old  text := 'where b.list_data_id = p_branch_id and w.company_id = v_co';
  v_new  text := 'where b.customer_id = p_branch_id and w.company_id = v_co';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'carrier_branch_set: expected the ownership check once, found %', v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$do$;

-- And the column says which id it holds, so the next person reading this table does not have to
-- go and find out.
comment on column qvm_new_apps.carrier_branch_settings.branch_id is
  'client_branches.customer_id — the branch''s own key. NOT list_data_id, which several branches '
  'share.';
