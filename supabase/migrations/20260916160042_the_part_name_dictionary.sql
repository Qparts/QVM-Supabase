-- A controlled vocabulary for part names, and the sections it is organised by.
--
-- The business already had this: a curated sheet of 615 part names, each with an Arabic and an
-- English form, a section, and the wordings the trade actually uses for it — 1,356 of them. It
-- lived in Excel, so the system could not consult it, and every file that arrived invented its
-- own spelling of a name the company had already decided on.
--
-- Two tables, because they answer two different questions:
--   · part_name_terms    — «فحمات فرامل أمامي» is a thing, and it belongs to Brakes.
--   · part_name_synonyms — «FRT BRAKE PADS» and «فحمات امامي» are ways of writing that thing.
-- The term's own two names are synonyms of it as well, flagged canonical, so one lookup against
-- one index answers «do we already say this» whatever form the question arrives in.
--
-- This is NOT parts_catalog_names, which records what a particular vendor called a particular
-- part. That is evidence about one row; this is the company's vocabulary.
--
-- Nothing is guessed here. A wording that points at more than one term is not resolved by a rule
-- — it goes to part_name_conflicts for a person to settle, because picking the more popular
-- reading is exactly how «سير خارجي» would end up meaning «حزام أمان».

-- ── Sections ───────────────────────────────────────────────────────────────────────────────────
-- The twelve seeded in 20260913280042 are replaced by the dictionary's own nineteen, which are
-- finer (محرك · جيربوكس · قير · وقود where there was one «الميكانيكا») and are what the 615 terms
-- are already filed under. The old rows are deactivated rather than deleted: nothing points at
-- them today, and a delete would be the one irreversible step in this migration.
--
-- Four of the sheet's twenty-three rows are the same section spelled twice. Merged by which
-- spelling the terms themselves use: هيكل وبودي (150 terms, over بودي), نظام تعليق (56, over
-- تعليق), نظام توجيه (19, over دركسون), فرامل (Brake and Brakes, 23 together).
-- جيربوكس and قير are left apart on purpose — the sheet treats them as different sections and
-- merging two things the business distinguishes is not a cleanup, it is a loss.
update qvm_new_apps.part_sections set is_active = false;

insert into qvm_new_apps.part_sections (name_ar, name_en, sort_order, is_active)
values ('كهرباء',        'Electrical',        10, true),
       ('هيكل وبودي',    'Body',              20, true),
       ('محرك',          'Engine',            30, true),
       ('نظام تعليق',    'Suspension System', 40, true),
       ('فلاتر وزيوت',   'Oil & Filter',      50, true),
       ('تكييف',         'AC',                60, true),
       ('فرامل',         'Brakes',            70, true),
       ('جيربوكس',       'Gear box',          80, true),
       ('نظام توجيه',    'Steering System',   90, true),
       ('قير',           'Transmission',     100, true),
       ('داخلية',        'Interior',         110, true),
       ('إطارات وجنوط',  'Wheels & Tires',   120, true),
       ('تبريد',         'Cooling System',   130, true),
       ('إنارة',         'Lighting',         140, true),
       ('سوائل',         'Fluids',           150, true),
       ('زجاج',          'Glass',            160, true),
       ('وقود',          'Fuel System',      170, true),
       ('أمان',          'Safety',           180, true),
       ('عادم',          'Exhaust System',   190, true);

-- ── The vocabulary ─────────────────────────────────────────────────────────────────────────────
create table if not exists qvm_new_apps.part_name_terms (
  term_id     bigint generated always as identity primary key,
  -- The sheet's own code. Kept so a correction made in the sheet can still be matched to the row
  -- it became, and so a reviewer can say «DIC-0360 is wrong» and be understood.
  code        text unique,
  name_ar     text not null,
  name_en     text,
  section_id  bigint references qvm_new_apps.part_sections(section_id),
  is_active   boolean not null default true,
  origin      text not null default 'dictionary',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists qvm_new_apps.part_name_synonyms (
  synonym_id   bigint generated always as identity primary key,
  term_id      bigint not null references qvm_new_apps.part_name_terms(term_id) on delete cascade,
  text         text not null,
  -- The comparison form. Generated, so it can never drift from the text beside it.
  norm         text generated always as (qvm_new_apps.normalize_part_name(text)) stored,
  lang         text,
  -- True for the term's own Arabic and English names: the wording to write back, as opposed to
  -- a wording merely recognised.
  is_canonical boolean not null default false,
  origin       text not null default 'dictionary',
  created_at   timestamptz not null default now()
);

-- One wording per term, however many times the sheet repeated it.
create unique index if not exists part_name_synonyms_term_norm
  on qvm_new_apps.part_name_synonyms (term_id, norm);
-- Exact lookup is the common path and must not scan.
create index if not exists part_name_synonyms_norm
  on qvm_new_apps.part_name_synonyms (norm);
-- Near lookup, for «is this the same wording as something we already have».
create index if not exists part_name_synonyms_norm_trgm
  on qvm_new_apps.part_name_synonyms using gin (norm extensions.gin_trgm_ops);

-- ── What could not be decided ──────────────────────────────────────────────────────────────────
-- 103 of the sheet's wordings are listed under more than one term. Some are real ambiguity
-- («Struts» is both مساعدات and مساعدات أمامي); some are plainly wrong — DIC-0360 «حزام أمان»
-- claims «سير», «سير مكينة» and «سير خارجي», which are engine-belt terms in a different section.
-- Loading either reading would put a wrong answer into the vocabulary everything else trusts.
create table if not exists qvm_new_apps.part_name_conflicts (
  conflict_id  bigint generated always as identity primary key,
  text         text not null,
  norm         text generated always as (qvm_new_apps.normalize_part_name(text)) stored,
  -- Every term that claims this wording, so the reviewer sees the whole choice at once.
  candidates   jsonb not null,
  status       text not null default 'open',   -- open | resolved | dropped
  resolved_term_id bigint references qvm_new_apps.part_name_terms(term_id),
  note         text,
  created_at   timestamptz not null default now(),
  reviewed_at  timestamptz,
  reviewed_by  uuid
);
create unique index if not exists part_name_conflicts_norm
  on qvm_new_apps.part_name_conflicts (norm);

-- Reached only through the RPCs below, like everything else in this schema.
alter table qvm_new_apps.part_name_terms     enable row level security;
alter table qvm_new_apps.part_name_synonyms  enable row level security;
alter table qvm_new_apps.part_name_conflicts enable row level security;

grant select on qvm_new_apps.part_name_terms, qvm_new_apps.part_name_synonyms,
                qvm_new_apps.part_name_conflicts to authenticated;
