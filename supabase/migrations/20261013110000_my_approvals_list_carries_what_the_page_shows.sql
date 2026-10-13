-- My approvals (the customer's queue) becomes a table with tabs, counters and an overdue clock.
-- The list now also carries what that table shows: the round, the claim number from the offer,
-- the VIN, the workshop branch and its company, who sent it, when it was answered and how each
-- line stands — which is what tells "partially approved" apart from waiting and approved.
-- Same rows, same gate (the signed-in user's end customers, latest customer round per order).
create or replace function qvm_new_apps.list_my_customer_approvals()
returns jsonb
language sql
stable security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
  select coalesce((
    select jsonb_agg(jsonb_build_object(
             'quotation_id',      q.quotation_id,
             'approval_round_id', r.approval_round_id,
             'order_number',      q.order_number,
             'plate_number',      q.plate_number,
             'created_at',        q.created_at,
             'sent_at',           r.sent_at,
             'sent_by_name',      sb.user_name,
             'decided_at',        r.decided_at,
             'expires_at',        r.token_expires_at,
             'round_status',      r.status,
             'total_amount',      r.total_amount,
             'items',             li.total,
             'approved_items',    li.approved,
             'cancelled_items',   li.cancelled,
             'pending_items',     li.pending,
             'customer_name',     vec.name,
             'claim_number',      o.claim_number,
             'vehicle',  fi.vehicle,
             'vin',      fi.vin,
             'workshop', fi.branch_name,
             'company',  fi.company_name)
           order by r.sent_at desc)
      from qvm_new_apps.quotation_approval_rounds r
      join qvm_new_apps.quotations q on q.quotation_id = r.quotation_id
      join qvm_new_apps.end_customer_users eu
        on eu.end_customer_id = r.end_customer_id and eu.user_id = auth.uid()
      left join qvm_new_apps.v_end_customers vec on vec.end_customer_id = r.end_customer_id
      left join qvm_new_apps.user_data sb on sb.user_id = r.sent_by
      left join qvm_new_apps.quotation_approval_offers o on o.approval_round_id = r.approval_round_id
      left join lateral (
        select count(*)::int as total,
               count(*) filter (where ai.decision = 'approved')::int as approved,
               count(*) filter (where ai.decision = 'cancelled')::int as cancelled,
               count(*) filter (where ai.decision = 'pending')::int as pending
          from qvm_new_apps.quotation_approval_items ai
         where ai.approval_round_id = r.approval_round_id) li on true
      -- The order's first line names the vehicle and the workshop branch it came from.
      left join lateral (
        select concat_ws(' ', ld.list_data, qi.model, qi.year) as vehicle,
               qi.vin, cb.branch_name, co.list_data as company_name
          from qvm_new_apps.quotation_items qi
          left join qvm_new_apps.list_data ld on ld.list_data_id = qi.main_brand
          left join qvm_new_apps.client_branches cb on cb.customer_id = qi.customer_id
          left join qvm_new_apps.list_data co on co.list_data_id = cb.list_data_id
         where qi.quotation_id = q.quotation_id
         order by qi.quotation_item_id
         limit 1) fi on true
     where r.audience = 'client'
       and r.approval_round_id = (select max(r2.approval_round_id)
                                    from qvm_new_apps.quotation_approval_rounds r2
                                   where r2.quotation_id = r.quotation_id and r2.audience = 'client')),
    '[]'::jsonb);
$function$;

notify pgrst, 'reload schema';
