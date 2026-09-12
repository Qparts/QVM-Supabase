-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

do $mig$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.customer_statement(integer,date,date)'::regprocedure);
begin
  -- «Everything before the window» has to mean nothing at all when there is no window start.
  -- Written as `p_from is null or …` it meant the opposite: with no start date every invoice
  -- and every payment counted as opening *and* was listed again below it, so the statement
  -- added up to twice the balance.
  if position('       and (p_from is null or i.created_at::date < p_from)' in v_def) = 0 then
    raise exception 'opening invoice predicate not found';
  end if;
  v_def := replace(v_def,
    '       and (p_from is null or i.created_at::date < p_from)',
    '       and (p_from is not null and i.created_at::date < p_from)');

  if position('       and (p_from is null or pay.paid_on < p_from)' in v_def) = 0 then
    raise exception 'opening payment predicate not found';
  end if;
  v_def := replace(v_def,
    '       and (p_from is null or pay.paid_on < p_from)',
    '       and (p_from is not null and pay.paid_on < p_from)');

  execute v_def;
end
$mig$;
