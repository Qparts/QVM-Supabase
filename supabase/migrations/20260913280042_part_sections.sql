-- «القسم الرئيسي المعتمد» — the section a part belongs to.
--
-- Not the same axis as clean_part_class, which answers «genuine or aftermarket». This answers
-- «what part of the car is this», and the two are independent: a genuine brake pad and an
-- aftermarket one are both brakes.
--
-- A fixed list rather than free text, because free text is how «فرامل», «الفرامل», «brakes» and
-- «Brake» become four sections that no filter can put back together. The list is a table rather
-- than a check constraint so it can be extended without a migration.

create table if not exists qvm_new_apps.part_sections (
  section_id  bigint generated always as identity primary key,
  name_ar     text not null,
  name_en     text not null,
  sort_order  integer not null default 100,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create unique index if not exists part_sections_name_ar on qvm_new_apps.part_sections (name_ar);

-- RLS on with no policy: reachable only through the RPCs below, like every other table here.
alter table qvm_new_apps.part_sections enable row level security;

insert into qvm_new_apps.part_sections (name_ar, name_en, sort_order)
values ('الميكانيكا',        'Mechanical',        10),
       ('الكهرباء',          'Electrical',        20),
       ('الفرامل',           'Brakes',            30),
       ('التعليق والعفشة',   'Suspension',        40),
       ('ناقل الحركة',       'Transmission',      50),
       ('التبريد والتكييف',  'Cooling & AC',      60),
       ('العادم',            'Exhaust',           70),
       ('الهيكل والبودي',    'Body',              80),
       ('الزجاج والمرايا',   'Glass & Mirrors',   90),
       ('الزيوت والفلاتر',   'Oils & Filters',   100),
       ('الإطارات والجنوط',  'Tyres & Rims',     110),
       ('الإكسسوارات',       'Accessories',      120)
on conflict (name_ar) do nothing;

alter table qvm_new_apps.parts_catalog
  add column if not exists section_id bigint references qvm_new_apps.part_sections(section_id);

create index if not exists parts_catalog_section on qvm_new_apps.parts_catalog (section_id);

-- The list, for the picker on the catalogue screen.
create or replace function qvm_new_apps.part_sections_list()
returns jsonb
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'section_id', s.section_id, 'name_ar', s.name_ar, 'name_en', s.name_en)
         order by s.sort_order, s.name_ar), '[]'::jsonb)
    from qvm_new_apps.part_sections s
   where s.is_active;
$function$;

revoke all on function qvm_new_apps.part_sections_list() from public;
grant execute on function qvm_new_apps.part_sections_list() to authenticated;

-- ① The catalogue reader carries the section, by id for the picker and by name for the cell.
do $patch$
declare
  v_def text := pg_get_functiondef(
    'qvm_new_apps.uploaded_records_get(text,text,text,integer,integer)'::regprocedure);
  v_new text;
begin
  v_new := replace(v_def,
$old$                 'is_complete', c.is_complete, 'is_active', c.is_active,$old$,
$new$                 'is_complete', c.is_complete, 'is_active', c.is_active,
                 -- Both names, and the screen picks. Every other label on this page is chosen
                 -- client-side from label_ar/label_en; resolving it here instead would make this
                 -- one cell the only thing on the table that depends on the request language.
                 'section_id', c.section_id,
                 'section_ar', (select s.name_ar from qvm_new_apps.part_sections s
                                 where s.section_id = c.section_id),
                 'section_en', (select s.name_en from qvm_new_apps.part_sections s
                                 where s.section_id = c.section_id),$new$);
  if v_new = v_def then
    raise exception 'uploaded_records_get: the catalogue flags were not found';
  end if;
  execute v_new;
end
$patch$;

-- ② And the writer accepts it, so the picker can actually set it.
do $patch$
declare
  v_def text := pg_get_functiondef(
    'qvm_new_apps.uploaded_record_update(text,bigint,jsonb)'::regprocedure);
  v_new text;
begin
  v_new := replace(v_def,
$old$    update qvm_new_apps.parts_catalog set
      clean_name_ar = case when p_patch ? 'name' then nullif(btrim(p_patch->>'name'$old$,
$new$    -- Presence semantics, like every other field here: a key that is present and null clears
    -- the section, a key that is absent leaves it alone.
    update qvm_new_apps.parts_catalog set
      section_id = case when p_patch ? 'section_id'
                        then nullif(btrim(coalesce(p_patch->>'section_id', '')), '')::bigint
                        else section_id end,
      clean_name_ar = case when p_patch ? 'name' then nullif(btrim(p_patch->>'name'$new$);
  if v_new = v_def then
    raise exception 'uploaded_record_update: the catalogue update was not found';
  end if;
  execute v_new;
end
$patch$;
