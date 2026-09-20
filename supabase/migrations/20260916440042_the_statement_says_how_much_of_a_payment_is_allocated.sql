-- A payment says how much of it has been allocated.
--
-- «مخصصة بالكامل / مخصصة جزئيًا / غير مخصصة» is not a status anybody sets. It is the payment's
-- cash compared with the sum of the documents it has been pointed at, and like every other state
-- in this module it is derived on read — a stored copy would be stale the moment somebody
-- re-allocates, which is the one moment it matters.
--
-- On the statement, a payment line now also carries `allocated`, so the row can show «٣١٥.٧٥
-- المتبقي» without a second round trip, and the settlements list carries the same so the column
-- reads the same figure in both places.
create or replace function qvm_new_apps.vendor_settlement_allocation(p_settlement_id bigint)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'paid', coalesce(s.paid_amount, 0),
    'allocated', coalesce(a.allocated, 0),
    'unallocated', coalesce(s.paid_amount, 0) - coalesce(a.allocated, 0),
    'state', case
      -- A request that has not been paid yet is not «unallocated»; nothing has happened to it.
      when s.status <> 'settled' then 'not_paid'
      when coalesce(a.allocated, 0) <= 0 then 'unallocated'
      when coalesce(a.allocated, 0) >= coalesce(s.paid_amount, 0) then 'full'
      else 'partial' end)
    from qvm_new_apps.vendor_settlements s
    left join lateral (
      select sum(i.amount) as allocated
        from qvm_new_apps.vendor_settlement_items i
       where i.settlement_id = s.settlement_id and i.member_status = 'settled') a on true
   where s.settlement_id = p_settlement_id;
$$;

-- The statement's payment line: the cash that left, and how much of it is spoken for.
do $do$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.vendor_statement(integer,date,date)'::regprocedure);
  v_old text := '    select ''payment'', s.settlement_id,
           ''settlement:'' || s.settlement_id,
           s.code,
           s.settled_at::date,
           -coalesce((select sum(i.amount) from qvm_new_apps.vendor_settlement_items i
                       where i.settlement_id = s.settlement_id and i.member_status = ''settled''), 0),
           s.transfer_ref,
           s.settled_at';
  v_new text := '    select ''payment'', s.settlement_id,
           ''settlement:'' || s.settlement_id,
           s.code,
           coalesce(s.paid_on, s.settled_at::date),
           -- The cash that left. Recorded up front for an on-account payment; for a request it is
           -- the sum of the documents the transfer actually covered, which the previous migration
           -- backfilled into the same column.
           -coalesce(s.paid_amount, 0),
           s.transfer_ref,
           s.settled_at';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'vendor_statement: expected the payment branch once, found %', v_hits;
  end if;
  v_def := replace(v_def, v_old, v_new);

  -- Carry the allocation onto every line. Null on an invoice or a credit note, because only a
  -- payment has anything to allocate — an empty object there would invite the screen to render a
  -- «غير مخصصة» chip on an invoice.
  v_old := '       ''line_date'', l.line_date, ''amount'', l.amount, ''po_text'', l.po_text,
       ''approved_at'', l.approved_at)';
  v_new := '       ''line_date'', l.line_date, ''amount'', l.amount, ''po_text'', l.po_text,
       ''approved_at'', l.approved_at,
       ''allocation'', case when l.kind = ''payment''
                          then qvm_new_apps.vendor_settlement_allocation(l.ref_id) end)';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'vendor_statement: expected the line builder once, found %', v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$do$;

-- The settlements list carries it too, so the same column reads the same number on both screens.
do $do$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.vendor_settlements_list(text,integer,integer)'::regprocedure);
  v_old text := '            ''receipt_url'', f.receipt_url, ''settled_at'', f.settled_at)';
  v_new text := '            ''receipt_url'', f.receipt_url, ''settled_at'', f.settled_at,
            ''paid_amount'', f.paid_amount, ''paid_on'', f.paid_on, ''method'', f.method,
            ''is_adhoc'', f.is_adhoc,
            ''allocation'', qvm_new_apps.vendor_settlement_allocation(f.settlement_id))';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'vendor_settlements_list: expected the row builder once, found %', v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$do$;

-- And the detail panel, which is what the allocation editor opens onto.
do $do$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.vendor_settlement_detail(bigint)'::regprocedure);
  v_old text := '           ''settled_at'', s.settled_at, ''settled_by_name'', su.user_name,
           ''cancelled_at'', s.cancelled_at)';
  v_new text := '           ''settled_at'', s.settled_at, ''settled_by_name'', su.user_name,
           ''cancelled_at'', s.cancelled_at,
           ''paid_amount'', s.paid_amount, ''paid_on'', s.paid_on, ''method'', s.method,
           ''is_adhoc'', s.is_adhoc,
           ''allocation'', qvm_new_apps.vendor_settlement_allocation(s.settlement_id))';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'vendor_settlement_detail: expected the header once, found %', v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$do$;

grant execute on function qvm_new_apps.vendor_settlement_allocation(bigint)
  to authenticated, service_role;
