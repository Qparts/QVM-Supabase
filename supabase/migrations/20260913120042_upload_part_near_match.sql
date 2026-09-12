-- Part numbers: reading the ones typed in Arabic, and catching the ones typed by eye.
--
-- normalize_part_number stripped everything outside [A-Za-z0-9], and Arabic-Indic digits are
-- outside it — so «٠٤٤٦٥-٦٠٢٨٠» normalised to nothing at all and the row was rejected for having
-- no part number. Folding the digits first cannot change any existing value: a string that
-- already produced a result contained only ASCII alphanumerics, which norm_digits leaves alone.

create extension if not exists fuzzystrmatch;

create or replace function qvm_new_apps.normalize_part_number(p_value text)
returns text
language sql
immutable
set search_path to 'qvm_new_apps', 'pg_catalog'
as $function$
  select nullif(upper(regexp_replace(
           qvm_new_apps.norm_digits(coalesce(p_value, '')), '[^A-Za-z0-9]', '', 'g')), '');
$function$;

/**
 * A part number folded to the shapes people confuse when copying one down.
 *
 * O and 0, I/L and 1, S and 5, B and 8, Z and 2 are the same glyph to a tired eye reading off a
 * printed invoice. Only ever compared, never stored — the catalogue keeps the number as it is.
 */
create or replace function qvm_new_apps.part_confusable(p text)
returns text language sql immutable set search_path to '' as $function$
  select nullif(translate(upper(coalesce(p, '')), 'OILSBZ', '011582'), '');
$function$;

/**
 * Known part numbers this one is suspiciously close to, and where they are already held.
 *
 * Two different signals, deliberately not merged into one score. Identical-once-folded is close
 * to proof of a typo. An edit distance of one or two is a suspicion, and only worth raising on a
 * number long enough that a single character is unlikely to be a real difference.
 */
create or replace function qvm_new_apps.part_near_match(p_clean text, p_limit integer default 5)
returns table (part_number text, kind text, distance integer, seen_in text)
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'extensions', 'public'
as $function$
  with known as (
    select clean_part_number as pn, 'catalog' as src from qvm_new_apps.parts_catalog
     where clean_part_number is not null
    union all
    select clean_part_number, 'purchases' from qvm_new_apps.part_purchase_history
     where clean_part_number is not null
    union all
    select clean_part_number, 'agency' from qvm_new_apps.agency_price_reference
     where clean_part_number is not null
    union all
    select clean_part_number, 'stock' from qvm_new_apps.inventory_stock
     where clean_part_number is not null
    union all
    select clean_alias, 'alias' from qvm_new_apps.part_aliases
     where clean_alias is not null
  ), rolled as (
    select k.pn, string_agg(distinct k.src, '/' order by k.src) as seen_in
      from known k
     where k.pn <> p_clean
       -- Only worth comparing at a similar length; the distance can never be small otherwise,
       -- and this keeps levenshtein off the whole catalogue.
       and abs(length(k.pn) - length(p_clean)) <= 2
     group by k.pn
  )
  select r.pn,
         case when qvm_new_apps.part_confusable(r.pn) = qvm_new_apps.part_confusable(p_clean)
              then 'confusable' else 'edit' end as kind,
         levenshtein(r.pn, p_clean) as distance,
         r.seen_in
    from rolled r
   where qvm_new_apps.part_confusable(r.pn) = qvm_new_apps.part_confusable(p_clean)
      or (levenshtein(r.pn, p_clean) = 1 and length(p_clean) >= 6)
      or (levenshtein(r.pn, p_clean) = 2 and length(p_clean) >= 10)
   order by (case when qvm_new_apps.part_confusable(r.pn) = qvm_new_apps.part_confusable(p_clean)
                  then 0 else 1 end),
            levenshtein(r.pn, p_clean), r.pn
   limit greatest(coalesce(p_limit, 5), 1);
$function$;

/** Two part numbers are the same part — recorded both ways round. */
create or replace function qvm_new_apps.upload_part_alias_save(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'extensions', 'public'
as $function$
declare
  v_from text := qvm_new_apps.normalize_part_number(nullif(btrim(coalesce(p_data->>'from','')), ''));
  v_to   text := qvm_new_apps.normalize_part_number(nullif(btrim(coalesce(p_data->>'to','')), ''));
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if v_from is null or v_to is null then
    return jsonb_build_object('status', false, 'message', 'رقمان مطلوبان', 'data', null);
  end if;
  if v_from = v_to then
    return jsonb_build_object('status', false, 'message', 'الرقمان متطابقان', 'data', null);
  end if;

  -- Both directions, the way upload_batch_write_rows already writes them: an alias pointing one
  -- way answers the question from one side of the file and not the other.
  insert into qvm_new_apps.part_aliases (clean_part_number, clean_alias, source_part_number, source_alias, note)
  values (v_to, v_from, p_data->>'to', p_data->>'from', 'upload mapping'),
         (v_from, v_to, p_data->>'from', p_data->>'to', 'upload mapping')
  on conflict (clean_part_number, clean_alias) do nothing;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('from', v_from, 'to', v_to));
end
$function$;

revoke all on function qvm_new_apps.upload_part_alias_save(jsonb) from public;
grant execute on function qvm_new_apps.upload_part_alias_save(jsonb) to authenticated;

-- The preview's one question-list, now covering both kinds of ambiguity.
create or replace function qvm_new_apps.upload_batch_unresolved(p_batch_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'extensions', 'public'
as $function$
declare v_b record; v_rows jsonb := '[]'::jsonb; v_parts jsonb := '[]'::jsonb;
begin
  if not qvm_new_apps.may_touch_upload_batch(p_batch_id) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  select * into v_b from qvm_new_apps.upload_batches where batch_id = p_batch_id;
  if v_b.batch_id is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;

  -- Only Past Purchases carries the supplier as text in the file; the other two are uploaded
  -- against a vendor chosen on the form, so there is nothing there to reconcile.
  if v_b.template_key = 'past_purchases' then
    select coalesce(jsonb_agg(x order by x.rows desc, x.raw), '[]'::jsonb) into v_rows from (
      select g.raw, g.rows, m.status, m.vendor_id, m.vendor_name, m.score, m.candidates
        from (
          select qvm_new_apps.upload_raw_get(r.raw, 'supplier_name') as raw, count(*) as rows
            from qvm_new_apps.upload_rows r
           where r.batch_id = p_batch_id
             and qvm_new_apps.upload_raw_get(r.raw, 'supplier_name') is not null
           group by 1
        ) g
        cross join lateral qvm_new_apps.vendor_match(g.raw) m
    ) x;
  end if;

  -- Part numbers that look like a slip of the eye off one we already hold. Reported for every
  -- template, because a mistyped part number is wrong in a stock file exactly as it is in a
  -- purchase one. Capped, because a file with a thousand unrecognised parts is a different
  -- problem and a thousand suggestions would bury it.
  select coalesce(jsonb_agg(x order by x.rows desc, x.part), '[]'::jsonb) into v_parts from (
    select g.part, g.sample, g.rows,
           jsonb_agg(jsonb_build_object(
             'part_number', n.part_number, 'kind', n.kind,
             'distance', n.distance, 'seen_in', n.seen_in)
             order by n.distance) as candidates
      from (
        select r.clean_part_number as part,
               min(coalesce(r.display_part_number, r.source_part_number)) as sample,
               count(*) as rows
          from qvm_new_apps.upload_rows r
         where r.batch_id = p_batch_id and r.clean_part_number is not null
         group by 1
         limit 500
      ) g
      cross join lateral qvm_new_apps.part_near_match(g.part, 3) n
     group by g.part, g.sample, g.rows
     limit 50
  ) x;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'field', case when v_b.template_key = 'past_purchases' then 'supplier_name' else null end,
    'values', v_rows,
    'unknown', (select count(*) from jsonb_array_elements(v_rows) e where e->>'status' = 'unknown'),
    'auto',    (select count(*) from jsonb_array_elements(v_rows) e where e->>'status' = 'auto'),
    'parts', v_parts,
    'parts_flagged', jsonb_array_length(v_parts)));
end
$function$;
