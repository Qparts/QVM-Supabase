-- A supplier's bank accounts, readable without opening a settlement.
--
-- vendor_settlement_detail already returns them, but only for a settlement that exists. Recording
-- a payment happens before any settlement does, and reaching for a detail call with a made-up id
-- to get at the accounts is the kind of shortcut that works until somebody creates settlement -1.
--
-- Same shape and same scoping as the copy inside the detail — the buying team reads any supplier's,
-- a supplier reads their own — so the two screens can never offer different accounts for the same
-- transfer.
create or replace function qvm_new_apps.vendor_bank_accounts(p_vendor_id integer)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_mine integer := qvm_new_apps.current_upload_vendor_id();
  v_rows jsonb;
begin
  if not v_team and (v_mine is null or v_mine <> p_vendor_id) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select coalesce(jsonb_agg(b order by b->>'bank_iban'), '[]'::jsonb) into v_rows
    from (select distinct jsonb_build_object(
                   'bank_name', e->>'bank_name',
                   'bank_iban', e->>'bank_iban',
                   'bank_account_name', e->>'bank_account_name') as b
            from qvm_new_apps.vendor_branches vb
            cross join lateral jsonb_array_elements(
              case when jsonb_typeof(vb.banks) = 'array' then vb.banks else '[]'::jsonb end) e
           where vb.vendor_id = p_vendor_id and nullif(e->>'bank_iban', '') is not null) k;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('banks', coalesce(v_rows, '[]'::jsonb)));
end
$$;

revoke all on function qvm_new_apps.vendor_bank_accounts(integer) from public;
grant execute on function qvm_new_apps.vendor_bank_accounts(integer)
  to authenticated, service_role;
