-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- فهرس الكتالوج — one canonical row per real part.
--
-- Everything uploaded so far describes a part *from somewhere*: this vendor's stock, that agency
-- list, last year's purchase. Nothing has said what the part **is**. Without that, the same number
-- written three ways is three parts, and searching by name finds nothing, because the workshop and
-- the vendor never call it the same thing.
--
-- Two mandatory facts beyond the number: the make and the class. A part number without a make is
-- not unique across brands, and the class is what a price is even comparable within.
create table if not exists qvm_new_apps.parts_catalog (
  part_id                  bigint generated always as identity primary key,
  clean_part_number        text not null,
  clean_make               text not null,
  clean_part_class         text not null,
  -- Mandatory except for a genuine part, whose origin is the agency's rather than a country any
  -- supplier declares — the same rule the code-rule editor already enforces.
  clean_country_manufacture text,
  clean_name_ar            text,
  clean_name_en            text,
  -- How the catalog row came to exist, so a row derived from an upload can be told from one a
  -- person entered deliberately.
  source                   text not null default 'upload',
  is_active                boolean not null default true,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  constraint parts_catalog_country_required check (
    lower(clean_part_class) in ('genuine', 'أصلي') or clean_country_manufacture is not null)
);

-- One row per part per make: the same number under two brands is two parts.
create unique index if not exists parts_catalog_number_make
  on qvm_new_apps.parts_catalog (clean_part_number, lower(clean_make));
create index if not exists parts_catalog_name_ar on qvm_new_apps.parts_catalog (clean_name_ar);

-- What each side calls it.
--
-- The workshop asks for «مساعد أمامي», the vendor's sheet says «مساعد امامى», the catalog holds one
-- canonical name. Searching by name only works if all three point at the same row, so the variants
-- are rows here rather than columns there — a part has no fixed number of names.
create table if not exists qvm_new_apps.parts_catalog_names (
  name_id     bigint generated always as identity primary key,
  part_id     bigint not null references qvm_new_apps.parts_catalog(part_id) on delete cascade,
  name        text not null,
  -- Who calls it this: the canonical name, a workshop's wording, or a vendor's.
  used_by     text not null check (used_by in ('canonical', 'workshop', 'vendor')),
  -- Which workshop or vendor, when it is theirs.
  party_kind  text check (party_kind in ('workshop', 'vendor')),
  party_id    bigint,
  lang        text not null default 'ar' check (lang in ('ar', 'en')),
  created_at  timestamptz not null default now()
);

create unique index if not exists parts_catalog_names_unique
  on qvm_new_apps.parts_catalog_names
     (part_id, lower(name), used_by, coalesce(party_id, -1));
create index if not exists parts_catalog_names_lookup
  on qvm_new_apps.parts_catalog_names (lower(name));

alter table qvm_new_apps.parts_catalog        enable row level security;
alter table qvm_new_apps.parts_catalog_names  enable row level security;

-- Every upload feeds the catalog. The row is created if the part is new and filled in if it was
-- thin, but an existing fact is never overwritten by a later, poorer one: a name already recorded
-- stays, and a country already known is not replaced by a null.
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
  -- A part with no number, no make or no class is not identifiable, and a half-identified row in
  -- the catalog is worse than no row: everything downstream would match against it.
  if p_clean_pn is null or v_make is null or v_class is null then
    return null;
  end if;
  if lower(v_class) not in ('genuine', 'أصلي') and v_country is null then
    return null;
  end if;

  insert into qvm_new_apps.parts_catalog
    (clean_part_number, clean_make, clean_part_class, clean_country_manufacture,
     clean_name_ar, clean_name_en)
  values (p_clean_pn, v_make, v_class, v_country, v_ar, v_en)
  on conflict (clean_part_number, lower(clean_make)) do update set
    -- Fill the gaps only.
    clean_part_class          = coalesce(qvm_new_apps.parts_catalog.clean_part_class, excluded.clean_part_class),
    clean_country_manufacture = coalesce(qvm_new_apps.parts_catalog.clean_country_manufacture, excluded.clean_country_manufacture),
    clean_name_ar             = coalesce(qvm_new_apps.parts_catalog.clean_name_ar, excluded.clean_name_ar),
    clean_name_en             = coalesce(qvm_new_apps.parts_catalog.clean_name_en, excluded.clean_name_en),
    updated_at                = now()
  returning part_id into v_id;

  -- The canonical names, and whatever this party calls it.
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
