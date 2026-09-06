-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- A code rule was global: one supplier's «CH-» applied to every file they ever sent, so the
-- same list — and the same count on the chip — showed on all five tabs. The tabs hold
-- different kinds of data and a prefix does not always mean the same thing across them, so a
-- rule now says which tab it belongs to.
--
-- Null keeps its old meaning of «everywhere», which is what every rule written before this
-- was, and the only reading of them that is not a guess.
alter table qvm_new_apps.upload_code_rules
  add column if not exists record_kind text;

comment on column qvm_new_apps.upload_code_rules.record_kind is
  'Which records tab the rule applies to (agency/stock/purchases/aliases/catalog). Null = every tab, which is what rules written before scoping existed are.';

-- template_key -> the tab its rows land in, in one place: the mapping is needed both when a
-- file is cleaned and when the rules list is read.
create or replace function qvm_new_apps.upload_template_record_kind(p_template_key text)
returns text
language sql
stable
set search_path to 'qvm_new_apps', 'public'
as $fn$
  select case t.lands
           when 'agency_price_reference' then 'agency'
           when 'inventory_stock'        then 'stock'
           when 'part_purchase_history'  then 'purchases'
           when 'part_aliases'           then 'aliases'
           when 'parts_catalog'          then 'catalog'
           else null
         end
    from qvm_new_apps.upload_templates t
   where t.template_key = p_template_key;
$fn$;
