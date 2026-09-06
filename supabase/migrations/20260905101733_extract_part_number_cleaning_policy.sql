-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- The cleaning policy for a part number, in one place.
--
-- It lived inside the file importer, so it was the policy for numbers that arrive in a
-- spreadsheet and nothing else. A number typed on the records screen got the separator and
-- case normalisation and none of the rest, so «ch12345-09395» was stored under CH1234509395
-- while the same number in a file was stored under 1234509395 — two rows, one part, and the
-- prefix left inside the key it is supposed to be kept out of.
--
-- Both callers use this now, so a number means the same thing however it arrived.
create or replace function qvm_new_apps.upload_clean_part_number(
  p_pn_raw text,
  p_record_kind text,
  p_source_kind text,
  p_source_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_pn_norm text := qvm_new_apps.normalize_part_number(p_pn_raw);
  v_rule record;
  v_code text; v_cut integer; v_stripped text; v_work text; v_probe text;
begin
  if v_pn_norm is null then
    return jsonb_build_object('matched_rule_id', null,
      'display_part_number', null, 'clean_part_number', null, 'probe', p_pn_raw,
      'brand', null, 'part_class', null, 'country_of_origin', null);
  end if;

  select r.*, qvm_new_apps.normalize_part_number(r.code) as norm_code into v_rule
    from qvm_new_apps.upload_code_rules r
   where r.source_kind = p_source_kind
     and coalesce(r.source_id, -1) = coalesce(p_source_id, -1)
     -- A rule belongs to one records tab. An older rule has no tab and still applies
     -- everywhere, which is what it meant when it was written.
     and (r.record_kind is null or r.record_kind = p_record_kind)
     and qvm_new_apps.normalize_part_number(r.code) is not null
     and ( (r.position = 'prefix'
            and v_pn_norm like qvm_new_apps.normalize_part_number(r.code) || '%')
        or (r.position = 'suffix'
            and v_pn_norm like '%' || qvm_new_apps.normalize_part_number(r.code)) )
   order by length(qvm_new_apps.normalize_part_number(r.code)) desc,
            (r.record_kind is null)
   limit 1;

  -- The part number with the matched code taken off, whatever the treatment.
  -- Used only to decide whether anything *else* is still unexplained.
  v_stripped := p_pn_raw;
  if v_rule.rule_id is not null then
    v_code := v_rule.norm_code;
    if v_rule.position = 'prefix' then
      v_cut := 0;
      for i in 1 .. length(p_pn_raw) loop
        exit when qvm_new_apps.normalize_part_number(left(p_pn_raw, i)) = v_code;
        v_cut := i;
      end loop;
      v_stripped := btrim(substr(p_pn_raw, v_cut + 2), '-_. ');
    else
      v_cut := 0;
      for i in 1 .. length(p_pn_raw) loop
        exit when qvm_new_apps.normalize_part_number(right(p_pn_raw, i)) = v_code;
        v_cut := i;
      end loop;
      v_stripped := btrim(left(p_pn_raw, length(p_pn_raw) - v_cut - 1), '-_. ');
    end if;
    if coalesce(v_stripped, '') = '' then v_stripped := p_pn_raw; end if;
  end if;

  -- What is actually stored: stripped only when the rule says to strip.
  v_work  := case when v_rule.rule_id is not null and v_rule.treatment = 'strip'
                  then v_stripped else p_pn_raw end;
  v_probe := case when v_rule.rule_id is not null then v_stripped else p_pn_raw end;

  return jsonb_build_object(
    'matched_rule_id', v_rule.rule_id,
    'display_part_number', v_work,
    'clean_part_number', qvm_new_apps.normalize_part_number(v_work),
    'probe', v_probe,
    'brand', v_rule.brand,
    'part_class', v_rule.part_class,
    'country_of_origin', v_rule.country_of_origin);
end
$function$;
