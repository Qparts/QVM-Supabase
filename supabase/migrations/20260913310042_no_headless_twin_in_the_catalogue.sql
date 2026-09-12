-- A part number held with a make, then met again without one, was getting a second row.
--
-- 20260913250042 handled the other direction — a make-less row that later learns its brand fills
-- the blank instead of splitting — but not this one. So part 123, known from the agency file as
-- make «gu», met again in a purchase file that carries no make, ended up twice in the index: once
-- as itself and once headless. That is the twin the earlier migration's own comment promised to
-- avoid, and it is the row every Official_* column would have started reading.
--
-- The rule: a fact with no make attaches to the part that is already there. It only creates a row
-- when the number is genuinely new.
--
-- Except when the number is already held under two makes. 1234509395 is exactly that — تويوتا
-- «صدام امامي» and ford «تيست» — two real parts that share a number, which is the case the
-- (number, make) key exists for. A make-less fact cannot be attributed to either, so it is
-- dropped rather than guessed onto one of them or added as a third headless row.
create or replace function qvm_new_apps.parts_catalog_absorb(
  p_clean_pn text, p_make text, p_part_class text, p_country text,
  p_name_ar text, p_name_en text,
  p_party_kind text default null, p_party_id bigint default null)
returns bigint
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_id bigint;
  v_existing integer;
  v_make text := nullif(btrim(coalesce(p_make, '')), '');
  v_class text := nullif(btrim(coalesce(p_part_class, '')), '');
  v_country text := nullif(btrim(coalesce(p_country, '')), '');
  v_ar text := nullif(btrim(coalesce(p_name_ar, '')), '');
  v_en text := nullif(btrim(coalesce(p_name_en, '')), '');
begin
  if p_clean_pn is null then
    return null;
  end if;

  -- A number already held with no make, now arriving with one, is the same part learning its
  -- brand — not a second part.
  if v_make is not null then
    update qvm_new_apps.parts_catalog
       set clean_make = v_make, updated_at = now()
     where clean_part_number = p_clean_pn and clean_make is null;
  end if;

  -- And the reverse: a fact with no make joins the part that is already there rather than
  -- starting a headless copy of it.
  if v_make is null then
    select count(*) into v_existing
      from qvm_new_apps.parts_catalog where clean_part_number = p_clean_pn;

    if v_existing = 1 then
      update qvm_new_apps.parts_catalog c set
        clean_part_class          = coalesce(c.clean_part_class, v_class),
        clean_country_manufacture = coalesce(c.clean_country_manufacture, v_country),
        clean_name_ar             = coalesce(c.clean_name_ar, v_ar),
        clean_name_en             = coalesce(c.clean_name_en, v_en),
        updated_at                = now()
       where c.clean_part_number = p_clean_pn
      returning c.part_id into v_id;
      return v_id;
    elsif v_existing > 1 then
      -- Two makes already. Nothing here says which one this belongs to, and inventing a third
      -- row would only add a part that does not exist.
      return null;
    end if;
  end if;

  insert into qvm_new_apps.parts_catalog
    (clean_part_number, clean_make, clean_part_class, clean_country_manufacture,
     clean_name_ar, clean_name_en)
  values (p_clean_pn, v_make, v_class, v_country, v_ar, v_en)
  on conflict (clean_part_number, lower(clean_make)) do update set
    clean_part_class          = coalesce(qvm_new_apps.parts_catalog.clean_part_class, excluded.clean_part_class),
    clean_country_manufacture = coalesce(qvm_new_apps.parts_catalog.clean_country_manufacture, excluded.clean_country_manufacture),
    clean_name_ar             = coalesce(qvm_new_apps.parts_catalog.clean_name_ar, excluded.clean_name_ar),
    clean_name_en             = coalesce(qvm_new_apps.parts_catalog.clean_name_en, excluded.clean_name_en),
    updated_at                = now()
  returning part_id into v_id;

  if v_ar is not null then
    insert into qvm_new_apps.parts_catalog_names (part_id, name, used_by, lang)
    values (v_id, v_ar, 'canonical', 'ar') on conflict do nothing;
    if p_party_kind in ('workshop', 'vendor') then
      insert into qvm_new_apps.parts_catalog_names (part_id, name, used_by, party_kind, party_id, lang)
      values (v_id, v_ar, p_party_kind, p_party_kind, p_party_id, 'ar') on conflict do nothing;
    end if;
  end if;
  if v_en is not null then
    insert into qvm_new_apps.parts_catalog_names (part_id, name, used_by, lang)
    values (v_id, v_en, 'canonical', 'en') on conflict do nothing;
  end if;

  return v_id;
end
$function$;

-- The twins already written. Only where the number has exactly one make-bearing row beside the
-- headless one — a number held under two real makes keeps both, and has no headless row anyway.
do $merge$
declare r record; v_merged integer := 0;
begin
  for r in
    select headless.part_id as drop_id, keeper.part_id as keep_id
      from qvm_new_apps.parts_catalog headless
      join qvm_new_apps.parts_catalog keeper
        on keeper.clean_part_number = headless.clean_part_number
       and keeper.clean_make is not null
     where headless.clean_make is null
       and (select count(*) from qvm_new_apps.parts_catalog x
             where x.clean_part_number = headless.clean_part_number
               and x.clean_make is not null) = 1
  loop
    update qvm_new_apps.parts_catalog k set
      clean_part_class          = coalesce(k.clean_part_class, d.clean_part_class),
      clean_country_manufacture = coalesce(k.clean_country_manufacture, d.clean_country_manufacture),
      clean_name_ar             = coalesce(k.clean_name_ar, d.clean_name_ar),
      clean_name_en             = coalesce(k.clean_name_en, d.clean_name_en),
      updated_at                = now()
      from qvm_new_apps.parts_catalog d
     where k.part_id = r.keep_id and d.part_id = r.drop_id;

    update qvm_new_apps.parts_catalog_names set part_id = r.keep_id where part_id = r.drop_id;
    delete from qvm_new_apps.parts_catalog where part_id = r.drop_id;
    v_merged := v_merged + 1;
  end loop;
  raise notice 'merged % headless twin(s)', v_merged;
end
$merge$;
