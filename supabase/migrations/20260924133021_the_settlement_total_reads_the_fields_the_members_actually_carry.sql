-- The settlement total reads the fields the members actually carry.
--
-- The first version summed `amount`, `settled_amount` and `remaining` off the member row. None
-- of those exist: a member carries `items`, `doc_key` and a nested `document`, and the money is
-- on the document — `total`, `settled`, and `signed_total`, which is the signed figure that makes
-- a credit note subtract instead of add.
--
-- So every settlement reported a total of zero, on a panel whose whole purpose is the total. It
-- looked right — four keys, plausible names, no error — which is exactly the kind of wrong that
-- survives review. Caught by reading one member back rather than trusting the field names I had
-- assumed.
--
-- `signed_total` is what «صافي مبلغ الطلب» means: invoices positive, credit notes negative.
-- `total` is kept beside it as the gross, because «we claimed 4,025 and a credit note took 230
-- off» is two facts and one of them is what the supplier will argue about.
do $do$
declare
  v_def  text := pg_get_functiondef('qvm_new_apps.vendor_settlement_detail(bigint)'::regprocedure);
  v_old  text := '    ''totals'', (
      select jsonb_build_object(
        ''documents'', count(*),
        ''gross'',     coalesce(sum((m->>''amount'')::numeric), 0),
        ''settled'',   coalesce(sum((m->>''settled_amount'')::numeric), 0),
        ''remaining'', coalesce(sum((m->>''remaining'')::numeric), 0))
      from jsonb_array_elements(coalesce(v_members, ''[]''::jsonb)) m
      where coalesce(m->>''member_status'', '''') <> ''cancelled''),';
  v_new  text := '    ''totals'', (
      select jsonb_build_object(
        ''documents'', count(*),
        -- Gross: what the documents say before any sign is applied.
        ''gross'',     coalesce(sum((m->''document''->>''total'')::numeric), 0),
        -- Net: invoices add, credit notes subtract. This is «صافي مبلغ الطلب».
        ''net'',       coalesce(sum((m->''document''->>''signed_total'')::numeric), 0),
        ''settled'',   coalesce(sum((m->''document''->>''settled'')::numeric), 0),
        ''remaining'', coalesce(sum(
                         (m->''document''->>''signed_total'')::numeric
                         - coalesce((m->''document''->>''settled'')::numeric, 0)), 0))
      from jsonb_array_elements(coalesce(v_members, ''[]''::jsonb)) m
      where coalesce(m->>''member_status'', '''') <> ''cancelled''),';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'vendor_settlement_detail: expected the totals block once, found %', v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$do$;
