-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

create or replace function qvm_new_apps.part_name_approx(p_clean_pn text)
returns jsonb language plpgsql stable
set search_path to 'qvm_new_apps', 'public', 'extensions'
as $function$
declare v_hit record;
begin
  if p_clean_pn is null or length(p_clean_pn) < 5 then
    return null;
  end if;

  -- 2 · through a recorded equivalent number. Aliases are written both ways, so one join suffices.
  select d.name, d.clean_part_number as matched, 'alias' as via
    into v_hit
    from qvm_new_apps.part_aliases a
    join qvm_new_apps.part_name_dictionary d on d.clean_part_number = a.clean_alias
   where a.clean_part_number = p_clean_pn
   limit 1;
  if found then
    return jsonb_build_object('name', v_hit.name, 'matched', v_hit.matched,
                              'via', v_hit.via, 'is_guess', false);
  end if;

  -- 3 · the same number with an unexplained supplier affix still attached.
  select d.name, d.clean_part_number as matched, 'affix' as via
    into v_hit
    from qvm_new_apps.part_name_dictionary d
   where length(d.clean_part_number) >= 5
     and length(p_clean_pn) - length(d.clean_part_number) between 1 and 4
     and (p_clean_pn like '%' || d.clean_part_number or p_clean_pn like d.clean_part_number || '%')
     -- What is left over must be letters: digits either side would make it a different number,
     -- not the same one wearing a prefix.
     and replace(replace(p_clean_pn, d.clean_part_number, ''), ' ', '') ~ '^[A-Za-z]+$'
   order by length(d.clean_part_number) desc
   limit 1;
  if found then
    return jsonb_build_object('name', v_hit.name, 'matched', v_hit.matched,
                              'via', v_hit.via, 'is_guess', true);
  end if;

  -- 4 · last resort. 0.88 is above what one differing character can reach on numbers of this
  -- length, so this only fires for near-identical strings.
  select d.name, d.clean_part_number as matched, 'similarity' as via,
         extensions.similarity(d.clean_part_number, p_clean_pn) as sim
    into v_hit
    from qvm_new_apps.part_name_dictionary d
   where d.clean_part_number % p_clean_pn
   order by extensions.similarity(d.clean_part_number, p_clean_pn) desc,
            length(d.clean_part_number)
   limit 1;
  if found and v_hit.sim >= 0.88 then
    return jsonb_build_object('name', v_hit.name, 'matched', v_hit.matched,
                              'via', v_hit.via, 'similarity', round(v_hit.sim::numeric, 3),
                              'is_guess', true);
  end if;

  return null;
end
$function$;

create or replace function qvm_new_apps.upload_batch_set_params(p_batch_id bigint, p_params jsonb)
returns jsonb language plpgsql security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare v_b record;
begin
  if not qvm_new_apps.may_touch_upload_batch(p_batch_id) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  select * into v_b from qvm_new_apps.upload_batches where batch_id = p_batch_id;
  if v_b.batch_id is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;
  -- After publishing, the values are already baked into the rows that were written; changing them
  -- here would leave the batch describing something other than what it did.
  if v_b.published_at is not null then
    return jsonb_build_object('status', false,
      'message', 'الملف منشور بالفعل — لا يمكن تغيير القيم العامة بعد النشر', 'data', null);
  end if;

  update qvm_new_apps.upload_batches
     set params = coalesce(p_params, '{}'::jsonb), updated_at = now()
   where batch_id = p_batch_id;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('batch_id', p_batch_id, 'params', coalesce(p_params, '{}'::jsonb)));
end
$function$;

create or replace function qvm_new_apps.upload_batch_unknown_codes(p_batch_id bigint)
returns jsonb language plpgsql stable security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_b record;
begin
  if not qvm_new_apps.may_touch_upload_batch(p_batch_id) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  select * into v_b from qvm_new_apps.upload_batches where batch_id = p_batch_id;
  if v_b.batch_id is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data',
    coalesce((
      select jsonb_agg(x order by x->>'rows' desc, x->>'code')
      from (
        select jsonb_build_object(
                 'code', code, 'position', position, 'rows', count(*),
                 'sample', (array_agg(source_part_number order by row_number))[1]) as x
        from (
          select r.row_number, r.source_part_number,
                 coalesce(
                   substring(r.source_part_number from '^([A-Za-z]{1,4})[-_. ]'),
                   substring(r.source_part_number from '^([A-Za-z]{1,4})[0-9]{4,}$'),
                   substring(r.source_part_number from '[-_. ]([A-Za-z]{1,4})$')) as code,
                 case
                   when r.source_part_number ~ '^[A-Za-z]{1,4}[-_. ]'
                     or r.source_part_number ~ '^[A-Za-z]{1,4}[0-9]{4,}$' then 'prefix'
                   else 'suffix'
                 end as position
          from qvm_new_apps.upload_rows r
          where r.batch_id = p_batch_id
            and r.state = 'disabled'
            -- A row that already matched a rule is explained; only the unexplained ones are asked
            -- about, which is what makes this "ask once per code" rather than every upload.
            and r.matched_rule_id is null
        ) found
        where code is not null
        group by code, position
      ) grouped), '[]'::jsonb),
    'source', jsonb_build_object('kind', v_b.source_kind, 'id', v_b.source_id, 'label', v_b.source_label));
end
$function$;

create or replace function qvm_new_apps.upload_campaign_create(
  p_kind text, p_title text, p_ends_on text default null,
  p_source_kind text default null, p_source_id bigint default null)
returns jsonb language plpgsql security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_kind text; v_sid bigint; v_id bigint;
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if p_kind not in ('offers', 'group_import', 'auction') then
    return jsonb_build_object('status', false, 'message', 'unknown kind', 'data', null);
  end if;
  if v_title is null then
    return jsonb_build_object('status', false, 'message', 'الاسم مطلوب', 'data', null);
  end if;

  -- A vendor may only create their own; the team says whose it is.
  if v_team then
    v_kind := coalesce(nullif(p_source_kind, ''), 'internal');
    v_sid  := p_source_id;
  else
    v_kind := 'vendor'; v_sid := v_vendor;
  end if;

  insert into qvm_new_apps.upload_campaigns (kind, title, ends_on, source_kind, source_id, created_by)
  values (p_kind, v_title, nullif(btrim(coalesce(p_ends_on, '')), '')::date,
          v_kind, v_sid, auth.uid())
  returning campaign_id into v_id;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('campaign_id', v_id, 'title', v_title));
end
$function$;

create or replace function qvm_new_apps.upload_campaigns_get(p_kind text)
returns jsonb language plpgsql stable security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if p_kind not in ('offers', 'group_import', 'auction') then
    return jsonb_build_object('status', false, 'message', 'unknown kind', 'data', null);
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', coalesce((
    select jsonb_agg(jsonb_build_object(
             'campaign_id', c.campaign_id, 'title', c.title, 'ends_on', c.ends_on,
             'source_label', case when c.source_kind = 'vendor'
                                  then (select v.vendor_name from qvm_new_apps.vendors v
                                         where v.vendor_id = c.source_id)
                                  else null end,
             -- What is already in it, so picking one is an informed choice.
             'items', case p_kind
               when 'offers' then (select count(*) from qvm_new_apps.part_offers o
                                    where o.campaign_id = c.campaign_id)
               when 'group_import' then (select count(*) from qvm_new_apps.group_import_requests g
                                          where g.campaign_id = c.campaign_id)
               else (select count(*) from qvm_new_apps.stock_auction_items a
                      where a.campaign_id = c.campaign_id) end)
           order by c.created_at desc)
      from qvm_new_apps.upload_campaigns c
     where c.kind = p_kind and c.is_active
       and (v_team or (c.source_kind = 'vendor' and c.source_id = v_vendor))), '[]'::jsonb));
end
$function$;

grant execute on function qvm_new_apps.part_name_approx(text) to authenticated;
grant execute on function qvm_new_apps.upload_batch_set_params(bigint, jsonb) to authenticated;
grant execute on function qvm_new_apps.upload_batch_unknown_codes(bigint) to authenticated;
grant execute on function qvm_new_apps.upload_campaigns_get(text) to authenticated;
grant execute on function qvm_new_apps.upload_campaign_create(text, text, text, text, bigint) to authenticated;
