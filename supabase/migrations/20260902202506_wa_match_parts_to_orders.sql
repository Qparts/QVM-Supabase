-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- Which of our orders is this file about?
--
-- A vendor sends a quote or an invoice with seven part numbers on it. Somebody then reads
-- the numbers, remembers which order they belong to, opens it, and checks. The part numbers
-- are the answer — they are printed on the document and they are stored on every order line,
-- so the match is a lookup, not a memory test.
--
-- Matching is on the part number stripped of punctuation and cased up: vendors print
-- 52129-06380, 5212906380 and 52129 06380 for the same part, and none of those are the
-- same string.

create index if not exists quotation_items_part_norm_idx
  on qvm_new_apps.quotation_items (upper(regexp_replace(part_number, '[^A-Za-z0-9]', '', 'g')));

create or replace function qvm_new_apps.wa_match_parts_to_orders(
  p_parts text[],
  p_vendor_id integer default null,
  p_limit integer default 6)
returns jsonb
language plpgsql
stable security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare v_norm text[]; v jsonb;
begin
  if not qvm_new_apps.wa_is_internal() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select array_agg(distinct x) into v_norm
    from unnest(coalesce(p_parts, '{}')) u(raw)
    cross join lateral (select upper(regexp_replace(u.raw, '[^A-Za-z0-9]', '', 'g'))) n(x)
   where length(x) >= 4;   -- shorter than four characters is not a part number, it is a code

  if v_norm is null or array_length(v_norm, 1) is null then
    return jsonb_build_object('status', true, 'message', 'ok',
      'data', jsonb_build_object('asked', 0, 'orders', '[]'::jsonb));
  end if;

  select coalesce(jsonb_agg(to_jsonb(o) order by o.matched desc, o.vendor_is_on desc, o.created_at desc), '[]'::jsonb)
    into v
    from (
      select q.quotation_id, q.order_number, q.plate_number, q.created_at,
             count(distinct upper(regexp_replace(qi.part_number, '[^A-Za-z0-9]', '', 'g'))) as matched,
             (select count(*) from qvm_new_apps.quotation_items a
               where a.quotation_id = q.quotation_id) as items,
             -- An order this vendor was actually asked to price outranks a coincidence.
             exists (select 1 from qvm_new_apps.quotation_vendors qv
                      where qv.quotation_id = q.quotation_id
                        and p_vendor_id is not null and qv.vendor_id = p_vendor_id) as vendor_is_on
        from qvm_new_apps.quotation_items qi
        join qvm_new_apps.quotations q on q.quotation_id = qi.quotation_id
       where upper(regexp_replace(qi.part_number, '[^A-Za-z0-9]', '', 'g')) = any(v_norm)
       group by q.quotation_id, q.order_number, q.plate_number, q.created_at
       limit greatest(coalesce(p_limit, 6), 1)
    ) o;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('asked', array_length(v_norm, 1), 'orders', v));
end $function$;

revoke execute on function qvm_new_apps.wa_match_parts_to_orders(text[], integer, integer) from public;
grant execute on function qvm_new_apps.wa_match_parts_to_orders(text[], integer, integer) to authenticated, anon;
