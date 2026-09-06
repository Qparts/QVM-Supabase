-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

create or replace function qvm_new_apps.upload_clean_row(
  p_raw jsonb, p_template_key text, p_source_kind text, p_source_id bigint)
returns jsonb language plpgsql stable security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_name_guess boolean := false;
  v_approx jsonb;
  v_pn_raw   text := nullif(btrim(coalesce(p_raw->>'part_number', '')), '');
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
  v_class text := nullif(btrim(coalesce(p_raw->>'part_class', '')), '');
  v_unknown boolean; v_cut integer; v_key text;
begin
  for v_col in
    select c from qvm_new_apps.upload_templates t,
                  lateral jsonb_array_elements(t.columns) c
     where t.template_key = p_template_key and (c->>'required')::boolean
  loop
    if nullif(btrim(coalesce(p_raw->>(v_col->>'key'), '')), '') is null then
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

  select r.*, qvm_new_apps.normalize_part_number(r.code) as norm_code into v_rule
    from qvm_new_apps.upload_code_rules r
   where r.source_kind = p_source_kind
     and coalesce(r.source_id, -1) = coalesce(p_source_id, -1)
     and qvm_new_apps.normalize_part_number(r.code) is not null
     and ( (r.position = 'prefix'
            and v_pn_norm like qvm_new_apps.normalize_part_number(r.code) || '%')
        or (r.position = 'suffix'
            and v_pn_norm like '%' || qvm_new_apps.normalize_part_number(r.code)) )
   order by length(qvm_new_apps.normalize_part_number(r.code)) desc
   limit 1;

  -- The part number with the matched code taken off, whatever the treatment.
  -- Used only to decide whether anything *else* is still unexplained.
  v_stripped := v_pn_raw;
  if v_rule.rule_id is not null then
    v_code := v_rule.norm_code;
    if v_rule.position = 'prefix' then
      v_cut := 0;
      for i in 1 .. length(v_pn_raw) loop
        exit when qvm_new_apps.normalize_part_number(left(v_pn_raw, i)) = v_code;
        v_cut := i;
      end loop;
      v_stripped := btrim(substr(v_pn_raw, v_cut + 2), '-_. ');
    else
      v_cut := 0;
      for i in 1 .. length(v_pn_raw) loop
        exit when qvm_new_apps.normalize_part_number(right(v_pn_raw, i)) = v_code;
        v_cut := i;
      end loop;
      v_stripped := btrim(left(v_pn_raw, length(v_pn_raw) - v_cut - 1), '-_. ');
    end if;
    if coalesce(v_stripped, '') = '' then v_stripped := v_pn_raw; end if;
  end if;

  -- What is actually stored: stripped only when the rule says to strip.
  v_work  := case when v_rule.rule_id is not null and v_rule.treatment = 'strip'
                  then v_stripped else v_pn_raw end;
  v_probe := case when v_rule.rule_id is not null then v_stripped else v_pn_raw end;

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

  v_unknown := v_probe ~ '^[A-Za-z]{1,4}[-_. ]'
            or v_probe ~ '[-_. ][A-Za-z]{1,4}$'
            or (v_rule.rule_id is null and v_probe ~ '^[A-Za-z]{1,4}[0-9]{4,}$');

  return jsonb_build_object(
    'state',  case when v_unknown then 'disabled' else 'ready' end,
    'reason', case when v_unknown
                   then 'أضِف قاعدة كود لهذه البادئة أو اللاحقة ثم اربطها لتفعيل الصنف'
                   else null end,
    'source_part_number',  v_pn_raw,
    'display_part_number', v_work,
    'clean_part_number',   v_key,
    'source_name', v_name_raw, 'clean_name', v_name_out,
    'name_is_guess', v_name_guess,
    'source_name_en', v_name_en, 'clean_name_en', v_name_en,
    'matched_rule_id', v_rule.rule_id,
    'brand', coalesce(v_rule.brand, nullif(btrim(coalesce(p_raw->>'make', '')), '')),
    'part_class', coalesce(v_rule.part_class, v_class),
    'country_of_origin', v_rule.country_of_origin);
end
$function$;
