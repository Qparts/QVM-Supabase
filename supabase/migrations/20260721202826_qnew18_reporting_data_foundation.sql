-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.


-- QNEW-18: Reporting Data Foundation
alter table qvm_new_apps.client_branches add column if not exists city text;

alter table qvm_new_apps.quotation_items add column if not exists extracted_by uuid;
alter table qvm_new_apps.quotation_items add column if not exists extracted_at timestamptz;

create or replace function qvm_new_apps.set_part_extraction()
returns trigger language plpgsql set search_path to '' as $$
begin
  if TG_OP = 'INSERT' then
    if NEW.part_number is not null and btrim(NEW.part_number) <> '' and NEW.extracted_by is null then
      NEW.extracted_by := auth.uid();
      NEW.extracted_at := now();
    end if;
  elsif TG_OP = 'UPDATE' then
    if OLD.extracted_by is not null then
      NEW.extracted_by := OLD.extracted_by;
      NEW.extracted_at := OLD.extracted_at;
    elsif (OLD.part_number is null or btrim(OLD.part_number) = '')
          and NEW.part_number is not null and btrim(NEW.part_number) <> '' then
      NEW.extracted_by := auth.uid();
      NEW.extracted_at := now();
    end if;
  end if;
  return NEW;
end; $$;

drop trigger if exists trg_set_part_extraction on qvm_new_apps.quotation_items;
create trigger trg_set_part_extraction
  before insert or update on qvm_new_apps.quotation_items
  for each row execute function qvm_new_apps.set_part_extraction();

alter table qvm_new_apps.quotation_vendor_items
  add column if not exists sla_hours numeric
  generated always as (
    case
      when regexp_replace(coalesce(sla,''), '[^0-9.]', '', 'g') ~ '^\d+(\.\d+)?$'
      then regexp_replace(coalesce(sla,''), '[^0-9.]', '', 'g')::numeric
      else null
    end
  ) stored;

alter table qvm_new_apps.cost_logs    add column if not exists pricing_source text;
alter table qvm_new_apps.pricing_logs add column if not exists pricing_source text;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'cost_logs_pricing_source_chk') then
    alter table qvm_new_apps.cost_logs add constraint cost_logs_pricing_source_chk
      check (pricing_source is null or pricing_source in
        ('Powerbi','SOP','Inventory File','Contact Supplier','On-Site Pricing'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'pricing_logs_pricing_source_chk') then
    alter table qvm_new_apps.pricing_logs add constraint pricing_logs_pricing_source_chk
      check (pricing_source is null or pricing_source in
        ('Powerbi','SOP','Inventory File','Contact Supplier','On-Site Pricing'));
  end if;
end $$;

create or replace function qvm_new_apps.set_cost_log_source()
returns trigger language plpgsql set search_path to '' as $$
begin
  if NEW.pricing_source is null and NEW.cost_id is not null then
    select qvi.price_source into NEW.pricing_source
    from qvm_new_apps.quotation_vendor_items qvi
    where qvi.cost_id = NEW.cost_id
      and qvi.price_source in ('Powerbi','SOP','Inventory File','Contact Supplier','On-Site Pricing')
    limit 1;
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_set_cost_log_source on qvm_new_apps.cost_logs;
create trigger trg_set_cost_log_source before insert on qvm_new_apps.cost_logs
  for each row execute function qvm_new_apps.set_cost_log_source();

create or replace function qvm_new_apps.set_pricing_log_source()
returns trigger language plpgsql set search_path to '' as $$
begin
  if NEW.pricing_source is null and NEW.quotation_item_id is not null then
    select qvi.price_source into NEW.pricing_source
    from qvm_new_apps.quotation_vendor_items qvi
    where qvi.quotation_item_id = NEW.quotation_item_id
      and qvi.price_source in ('Powerbi','SOP','Inventory File','Contact Supplier','On-Site Pricing')
    order by qvi.best_cost desc nulls last, qvi.cost_id desc
    limit 1;
  end if;
  return NEW;
end; $$;
drop trigger if exists trg_set_pricing_log_source on qvm_new_apps.pricing_logs;
create trigger trg_set_pricing_log_source before insert on qvm_new_apps.pricing_logs
  for each row execute function qvm_new_apps.set_pricing_log_source();

alter table qvm_new_apps.invoices add column if not exists due_date date;
alter table qvm_new_apps.invoices add column if not exists paid_at  timestamptz;

insert into qvm_new_apps.list_data (list_id, list_data)
select 16, v
from (values ('Purchasing'), ('Part Number Extractor')) as t(v)
where not exists (
  select 1 from qvm_new_apps.list_data d where d.list_id = 16 and d.list_data = t.v
);

alter table qvm_new_apps.purchase_orders add column if not exists created_by uuid;
alter table qvm_new_apps.status_logs     add column if not exists created_by uuid;
alter table qvm_new_apps.quotation_items add column if not exists updated_by uuid;
alter table qvm_new_apps.confirmed_items add column if not exists updated_by uuid;
alter table qvm_new_apps.purchase_orders add column if not exists updated_by uuid;
alter table qvm_new_apps.purchase_items  add column if not exists updated_by uuid;
alter table qvm_new_apps.cost_logs       add column if not exists updated_by uuid;
alter table qvm_new_apps.pricing_logs    add column if not exists updated_by uuid;
alter table qvm_new_apps.status_logs     add column if not exists updated_by uuid;

create or replace function qvm_new_apps.set_updated_by()
returns trigger language plpgsql set search_path to '' as $$
begin
  if TG_OP = 'INSERT' then
    NEW.updated_by := auth.uid();
  else
    NEW.updated_by := coalesce(auth.uid(), OLD.updated_by);
  end if;
  return NEW;
end; $$;

do $$
declare tname text;
begin
  foreach tname in array array['cost_logs','pricing_logs','purchase_orders','status_logs'] loop
    execute format('drop trigger if exists trg_set_created_by on qvm_new_apps.%I', tname);
    execute format('create trigger trg_set_created_by before insert on qvm_new_apps.%I for each row execute function qvm_new_apps.set_created_by()', tname);
    execute format('drop trigger if exists trg_freeze_created_by on qvm_new_apps.%I', tname);
    execute format('create trigger trg_freeze_created_by before update on qvm_new_apps.%I for each row execute function qvm_new_apps.freeze_created_by()', tname);
  end loop;
  foreach tname in array array['quotation_items','confirmed_items','purchase_orders','purchase_items','cost_logs','pricing_logs','status_logs'] loop
    execute format('drop trigger if exists trg_set_updated_by on qvm_new_apps.%I', tname);
    execute format('create trigger trg_set_updated_by before insert or update on qvm_new_apps.%I for each row execute function qvm_new_apps.set_updated_by()', tname);
  end loop;
end $$;
