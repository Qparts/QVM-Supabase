-- The catalogue index reads 0 while the three tabs below it hold 64 rows.
--
-- parts_catalog_absorb refuses anything without a make, and parts_catalog refuses anything
-- without a make or a class — both columns are NOT NULL. Of the 63 distinct cleaned part numbers
-- now in agency, stock and past purchases, exactly 3 carry a make and almost none carry a class.
-- The other 60 were absorbed into nothing, silently, on every publish. That is why the tab is
-- empty, and why every Official_* column on the other tabs prints a dash: they read the
-- catalogue, and the catalogue was never allowed to hold anything.
--
-- The rule is real — the same number under two brands is two different parts, which is why the
-- key is (number, make). But it was written as a condition for existing at all, and that is the
-- wrong shape. A purchase file naming a part and its price is a fact about a real part; the brand
-- is a fact we do not have yet. Refusing the row does not keep the catalogue clean, it keeps the
-- catalogue empty, and the part exists either way.
--
-- The table already has the right idea in it. is_complete, the partial index
-- parts_catalog_usable (is_active AND is_complete), and the reader's «ينقصها …» column were all
-- written for a catalogue that holds incomplete parts and keeps them out of workshop search and
-- automatic pricing until somebody fills the gap. Two NOT NULLs made that unreachable: the
-- reader's own `case when clean_part_class is null` could never fire. This makes the columns
-- match the design that was already there.

-- ① The two gates.
alter table qvm_new_apps.parts_catalog alter column clean_make      drop not null;
alter table qvm_new_apps.parts_catalog alter column clean_part_class drop not null;

-- ② A null make has to collide with itself, or every absorb inserts another copy.
--
-- Postgres treats nulls as distinct in a unique index by default, so a make-less part would never
-- match ON CONFLICT and would be inserted again on every publish — the catalogue would fill with
-- duplicates of one part instead of staying empty, which is worse than the bug being fixed.
-- NULLS NOT DISTINCT needs Postgres 15; this is 15.14.
drop index if exists qvm_new_apps.parts_catalog_number_make;
create unique index parts_catalog_number_make
  on qvm_new_apps.parts_catalog (clean_part_number, lower(clean_make)) nulls not distinct;

-- ③ Absorb what arrives, mark what is still missing, and let the rest arrive later.
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
  -- The one thing a catalogue row cannot be created without. Everything else, the make included,
  -- may arrive later — from another upload or from a person.
  if p_clean_pn is null then
    return null;
  end if;

  -- A number already held with no make, now arriving with one, is the same part learning its
  -- brand — not a second part. Filling the blank keeps one row; inserting would leave a headless
  -- twin behind for ever, and the twin is the one every Official_* column would keep reading.
  if v_make is not null then
    update qvm_new_apps.parts_catalog
       set clean_make = v_make, updated_at = now()
     where clean_part_number = p_clean_pn and clean_make is null;
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

  -- is_complete is not set here, and must not be: it is a generated column, and its expression is
  -- already precisely «make and class and a name, and either a country or a genuine part». That
  -- expression tests IS NOT NULL on the two columns this migration unlocks — dead logic for as
  -- long as they were NOT NULL, and the clearest evidence the table was built for this all along.
  -- It maintains itself, so an incomplete part stays out of parts_catalog_usable, and therefore
  -- out of workshop search and automatic pricing, without anybody remembering to say so.

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

-- ④ Everything already published, absorbed now rather than on some future upload.
--
-- These rows were written while the make rule was refusing them, and a batch is absorbed once, at
-- publish — nothing will ever come back for them. Without this the tab stays empty for every file
-- uploaded before today.
do $backfill$
declare r record; v_before bigint; v_after bigint;
begin
  select count(*) into v_before from qvm_new_apps.parts_catalog;

  for r in
    select clean_part_number, brand, part_class, country_of_origin, clean_name, clean_name_en
      from qvm_new_apps.inventory_stock
    union all
    -- Agency keeps no country, and its English name is the one the file carried.
    select clean_part_number, brand, part_class, null::text, clean_name, source_name_en
      from qvm_new_apps.agency_price_reference
    union all
    -- Purchases call the class brand_class, and now carry the supplier's own names.
    --
    -- No country: part_purchase_history.origin is not one. It holds the literal 'external_excel'
    -- on every row — a marker for how the row arrived, not where the part was made. Passing it
    -- through wrote «external_excel» into clean_country_manufacture for every purchased part,
    -- which reads as a real answer and would have counted towards is_complete.
    select clean_part_number, brand, brand_class, null::text, source_name, source_name_en
      from qvm_new_apps.part_purchase_history
  loop
    perform qvm_new_apps.parts_catalog_absorb(
      r.clean_part_number, r.brand, r.part_class, r.country_of_origin,
      r.clean_name, r.clean_name_en);
  end loop;

  select count(*) into v_after from qvm_new_apps.parts_catalog;
  raise notice 'catalogue: % -> % parts', v_before, v_after;
end
$backfill$;
