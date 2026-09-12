-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

do $mig$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.invoices_list(text,integer,text,integer,integer)'::regprocedure);
  v_old text :=
'           case
             when coalesce(i.total, 0) > 0 and coalesce(i.paid_amount, 0) >= i.total then ''paid''
             when i.due_date is not null and i.due_date < current_date then ''overdue''
             else ''pending''
           end as pay_status';
begin
  if position(v_old in v_def) = 0 then raise exception 'status expression not found'; end if;
  -- A zero-value invoice was reading as overdue: the paid test required a total above zero,
  -- so nothing outstanding fell through to the date check and got chased. Owing nothing is
  -- settled, whatever the total was.
  execute replace(v_def, v_old,
'           case
             when coalesce(i.total, 0) - coalesce(i.paid_amount, 0) <= 0 then ''paid''
             when i.due_date is not null and i.due_date < current_date then ''overdue''
             else ''pending''
           end as pay_status');
end
$mig$;
