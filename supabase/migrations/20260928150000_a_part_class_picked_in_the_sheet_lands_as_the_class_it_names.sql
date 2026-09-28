-- A part class picked in the sheet lands as the class it names.
--
-- The downloaded templates now offer the make and the part class as dropdowns read from the
-- database lists (car_brand, brand_class). The class list is worded in English («Genuine»,
-- «Aftermarket Grade A»); the catalog, the edit screens and the code rules store keys («genuine»,
-- «aftermarket_a»). Without this, a file filled from the dropdown would split every class in two.
-- The normaliser also takes the Arabic labels the screens show, and leaves anything else as typed.

set search_path to qvm_new_apps, public;

create or replace function qvm_new_apps.upload_norm_part_class(p_text text)
 returns text
 language sql
 immutable
as $function$
  select case lower(regexp_replace(btrim(coalesce(p_text, '')), '\s+', ' ', 'g'))
    when ''                     then null
    when 'genuine'              then 'genuine'
    when 'أصلي'                 then 'genuine'
    when 'اصلي'                 then 'genuine'
    when 'oem'                  then 'oem'
    when 'aftermarket'          then 'commercial'
    when 'commercial'           then 'commercial'
    when 'تجاري'                then 'commercial'
    when 'aftermarket grade a'  then 'aftermarket_a'
    when 'aftermarket_a'        then 'aftermarket_a'
    when 'تجاري درجة أولى'      then 'aftermarket_a'
    when 'aftermarket grade b'  then 'aftermarket_b'
    when 'aftermarket_b'        then 'aftermarket_b'
    when 'تجاري درجة ثانية'     then 'aftermarket_b'
    when 'used'                 then 'used'
    when 'مستعمل'               then 'used'
    when 'remanufactured'       then 'remanufactured'
    when 'مُجدَّد'              then 'remanufactured'
    when 'مجدد'                 then 'remanufactured'
    else btrim(p_text)
  end;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.upload_clean_row(p_raw jsonb, p_template_key text, p_source_kind text, p_source_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_name_guess boolean := false;
  v_approx jsonb;
  v_pn_raw   text := qvm_new_apps.upload_raw_get(p_raw, 'part_number');
  -- The two names are kept apart. `description` is the older single-column template, and it stands
  -- in for the Arabic/primary name so a sheet built against either version still imports.
  v_name_ar  text := coalesce(
                       nullif(btrim(coalesce(p_raw->>'name_ar', '')), ''),
                       nullif(btrim(coalesce(p_raw->>'description', '')), ''));
  v_name_en  text := nullif(btrim(coalesce(p_raw->>'name_en', '')), '');
  -- When only English was given it is also the primary name — a row is never left unnamed just
  -- because the Arabic column was blank.
  v_name_raw text := coalesce(v_name_ar, v_name_en);
  v_name_out text;
  v_pn_norm  text; v_work text; v_probe text; v_stripped text;
  v_rule record; v_code text;
  v_missing text[] := '{}'; v_col jsonb;
  -- The sheet's class column is a list now (Genuine / OEM / Aftermarket …), and whatever wording
  -- it carries lands as the one key the catalog and the edit screens use.
  v_class text := qvm_new_apps.upload_norm_part_class(qvm_new_apps.upload_raw_get(p_raw, 'part_class'));
  v_unknown boolean; v_cut integer; v_key text;
  v_clean jsonb;
begin
  for v_col in
    select c from qvm_new_apps.upload_templates t,
                  lateral jsonb_array_elements(t.columns) c
     where t.template_key = p_template_key and (c->>'required')::boolean
  loop
    if qvm_new_apps.upload_raw_get(p_raw, v_col->>'key') is null then
      v_missing := v_missing || (v_col->>'key');
    end if;
  end loop;

  if array_length(v_missing, 1) is not null then
    return jsonb_build_object(
      'state', 'rejected',
      'reason', 'حقول مطلوبة ناقصة: ' || array_to_string(v_missing, '، '),
      'source_part_number', v_pn_raw, 'clean_part_number', null,
      'display_part_number', null, 'source_name', v_name_raw, 'clean_name', v_name_raw,
      'source_name_en', v_name_en, 'clean_name_en', v_name_en,
      'matched_rule_id', null, 'brand', null, 'part_class', null, 'country_of_origin', null);
  end if;

  v_pn_norm := qvm_new_apps.normalize_part_number(v_pn_raw);
  if v_pn_norm is null then
    return jsonb_build_object(
      'state', 'rejected', 'reason', 'رقم القطعة لا يحتوي على حروف أو أرقام',
      'source_part_number', v_pn_raw, 'clean_part_number', null,
      'display_part_number', null, 'source_name', v_name_raw, 'clean_name', v_name_raw,
      'source_name_en', v_name_en, 'clean_name_en', v_name_en,
      'matched_rule_id', null, 'brand', null, 'part_class', null, 'country_of_origin', null);
  end if;

  v_clean := qvm_new_apps.upload_clean_part_number(
                v_pn_raw,
                qvm_new_apps.upload_template_record_kind(p_template_key),
                p_source_kind, p_source_id);

  select * into v_rule from qvm_new_apps.upload_code_rules r
   where r.rule_id = nullif(v_clean->>'matched_rule_id','')::bigint;

  v_work  := v_clean->>'display_part_number';
  v_probe := v_clean->>'probe';

  v_key := qvm_new_apps.normalize_part_number(v_work);
  if v_key is null then
    return jsonb_build_object(
      'state', 'rejected',
      'reason', 'لم يتبقَّ رقم بعد تطبيق قاعدة الكود — راجع القاعدة',
      'source_part_number', v_pn_raw, 'clean_part_number', null,
      'display_part_number', v_work, 'source_name', v_name_raw, 'clean_name', v_name_raw,
      'source_name_en', v_name_en, 'clean_name_en', v_name_en,
      'matched_rule_id', v_rule.rule_id, 'brand', null, 'part_class', null,
      'country_of_origin', null);
  end if;

  -- The dictionary only ever fills a gap; a name the supplier did send always wins, because they
  -- are the ones who have the part in front of them.
  v_name_out := v_name_raw;
  v_name_guess := false;
  if v_name_out is null then
    select d.name into v_name_out
      from qvm_new_apps.part_name_dictionary d
     where d.clean_part_number = v_key;

    -- Exact matching fills nothing when the number is written even slightly differently, which is
    -- the same file that left the name blank. The ladder in part_name_approx says how certain its
    -- answer is, and only its lower rungs count as guesses.
    if v_name_out is null then
      v_approx := qvm_new_apps.part_name_approx(v_key);
      if v_approx is not null then
        v_name_out := v_approx->>'name';
        v_name_guess := coalesce((v_approx->>'is_guess')::boolean, true);
      end if;
    end if;
  end if;

  -- The prefix guess no longer decides the state, because it was holding back genuine parts.
  -- In the file loaded today it caught ACPZ 1012H, F4AZ-6701-A and RS-76 — all three are part
  -- numbers, not codes with something hidden behind them. A key cannot both be clean by its
  -- length and be waiting for a rule, and length is the answer the team actually asked for. The
  -- shapes are still collected, by upload_batch_unknown_codes, which now reads them off the file
  -- rather than off a state this no longer sets.
  v_unknown := false;

  return jsonb_build_object(
    'state',  qvm_new_apps.part_number_verdict(v_key)->>'state',
    'reason', qvm_new_apps.part_number_verdict(v_key)->>'reason',
    'source_part_number',  v_pn_raw,
    'display_part_number', v_work,
    'clean_part_number',   v_key,
    'source_name', v_name_raw, 'clean_name', v_name_out,
    'name_is_guess', v_name_guess,
    'source_name_en', v_name_en, 'clean_name_en', v_name_en,
    'matched_rule_id', v_rule.rule_id,
    'brand', coalesce(v_rule.brand, qvm_new_apps.upload_raw_get(p_raw, 'make')),
    'part_class', coalesce(v_rule.part_class, v_class),
    'country_of_origin', v_rule.country_of_origin);
end
$function$;
