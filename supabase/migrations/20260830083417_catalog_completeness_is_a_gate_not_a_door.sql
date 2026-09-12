-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- The first cut treated «إجباري» as a condition for the row to *exist*, and the test showed what
-- that costs: a commercial part with no code rule has no country, so it never reached the catalog
-- at all — which is most parts. The catalog would have stayed almost empty while every upload
-- quietly dropped its parts on the floor.
--
-- The fields are mandatory for a part to be **usable**, not for it to be **recorded**. So the row
-- goes in, its completeness is computed, and an incomplete part simply does not count as active:
-- it stays out of workshop search and automatic pricing until someone fills the gap. That is also
-- what the design's completeness grading describes.
alter table qvm_new_apps.parts_catalog
  drop constraint if exists parts_catalog_country_required;

alter table qvm_new_apps.parts_catalog
  add column if not exists is_complete boolean
    generated always as (
      clean_make is not null
      and clean_part_class is not null
      and (lower(clean_part_class) in ('genuine', 'أصلي') or clean_country_manufacture is not null)
      and clean_name_ar is not null
    ) stored;

comment on column qvm_new_apps.parts_catalog.is_active is
  'A part only counts as usable when it is complete. Kept separate from is_complete so a complete
   part can still be stopped deliberately.';

create index if not exists parts_catalog_usable
  on qvm_new_apps.parts_catalog (clean_part_number) where is_active and is_complete;

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
  v_make text := nullif(btrim(coalesce(p_make, '')), '');
  v_class text := nullif(btrim(coalesce(p_part_class, '')), '');
  v_country text := nullif(btrim(coalesce(p_country, '')), '');
  v_ar text := nullif(btrim(coalesce(p_name_ar, '')), '');
  v_en text := nullif(btrim(coalesce(p_name_en, '')), '');
begin
  -- The one thing a catalog row cannot be created without: a number and a make. The same number
  -- under two brands is two different parts, so without the make there is nothing to key on.
  -- Everything else may arrive later, from another upload or from a person.
  if p_clean_pn is null or v_make is null then
    return null;
  end if;

  insert into qvm_new_apps.parts_catalog
    (clean_part_number, clean_make, clean_part_class, clean_country_manufacture,
     clean_name_ar, clean_name_en)
  values (p_clean_pn, v_make, v_class, v_country, v_ar, v_en)
  on conflict (clean_part_number, lower(clean_make)) do update set
    -- Fill the gaps only: a fact already recorded is never replaced by a later, poorer one.
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

revoke all on function qvm_new_apps.parts_catalog_absorb(text, text, text, text, text, text, text, bigint)
  from public, anon, authenticated;
