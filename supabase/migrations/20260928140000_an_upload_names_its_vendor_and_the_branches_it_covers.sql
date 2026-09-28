-- An upload names its vendor and the branches it covers.
--
-- Past purchases, stock and agency lists are one vendor's, and they describe particular branches
-- of that vendor. Until now the batch kept the chosen branches in an array, a file could be saved
-- with no vendor at all, and a row published for «all branches» carried no branch, so every
-- reader had to treat NULL as «everywhere». From here on:
--
--   • upload_batch_branches holds one row per branch a batch was uploaded for. «All branches»
--     is resolved to the vendor's active branches when the file is staged.
--   • every live row on agency_price_reference, inventory_stock and part_purchase_history names
--     its vendor and its branch (NOT NULL, foreign keys, and the branch has to be that vendor's).
--     A staged row is written once per chosen branch.
--   • the unique keys on agency and stock become plain (vendor_branch_id, clean_part_number);
--     the COALESCE-wrapped ones that tolerated NULLs go.
--   • rows already live without a branch are copied onto each branch their file covered (or the
--     vendor's active branches), and the originals removed. Purchase rows with no vendor at all
--     are moved aside into part_purchase_history_unscoped rather than given a vendor they never had.
--
-- The screen asks for the vendor first and then offers that vendor's branches as a multi-select
-- with «select all»; the manual «add one record» form asks for the branch too.

set search_path to qvm_new_apps, public;

-- ───────────────────────── the link table ─────────────────────────

create table if not exists qvm_new_apps.upload_batch_branches (
  batch_id         bigint not null references qvm_new_apps.upload_batches (batch_id) on delete cascade,
  vendor_branch_id bigint not null references qvm_new_apps.vendor_branches (vendor_branch_id),
  primary key (batch_id, vendor_branch_id)
);
create index if not exists upload_batch_branches_by_branch
  on qvm_new_apps.upload_batch_branches (vendor_branch_id, batch_id);
grant select, insert, update, delete on qvm_new_apps.upload_batch_branches to service_role;

-- ───────────────────────── helpers ─────────────────────────

create or replace function qvm_new_apps.upload_template_is_branch_bound(p_template_key text)
 returns boolean
 language sql
 immutable
as $function$
  select p_template_key in ('agency_price_list', 'stock_on_hand', 'past_purchases');
$function$;

-- The branches a file covers, as an explicit list. «specific» keeps the given ids that are this
-- vendor's active branches; «all» is every active branch when p_all_means_every, otherwise empty
-- (offers and auctions still read an empty list as «no branch»).
create or replace function qvm_new_apps.upload_branches_resolve(
  p_vendor_id integer, p_scope text, p_ids bigint[], p_all_means_every boolean)
 returns bigint[]
 language sql
 stable security definer
 set search_path to 'qvm_new_apps', 'public'
as $function$
  select coalesce(array_agg(vb.vendor_branch_id order by vb.vendor_branch_id), '{}'::bigint[])
    from qvm_new_apps.vendor_branches vb
   where vb.vendor_id = p_vendor_id
     and coalesce(vb.is_active, true)
     and case when p_scope = 'specific' then vb.vendor_branch_id = any(coalesce(p_ids, '{}'::bigint[]))
              else p_all_means_every end;
$function$;

create or replace function qvm_new_apps.upload_batch_branches_json(p_batch_id bigint)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'qvm_new_apps', 'public'
as $function$
  select coalesce((
    select jsonb_agg(jsonb_build_object('id', vb.vendor_branch_id, 'name', vb.branch_name,
                                        'city', vb.city, 'is_active', vb.is_active)
                     order by vb.branch_name, vb.vendor_branch_id)
      from qvm_new_apps.upload_batch_branches bb
      join qvm_new_apps.vendor_branches vb on vb.vendor_branch_id = bb.vendor_branch_id
     where bb.batch_id = p_batch_id), '[]'::jsonb);
$function$;

-- Past purchases now ask for the vendor and the branches like the other two.
update qvm_new_apps.upload_templates
   set needs_vendor = true, needs_branch = true
 where template_key in ('agency_price_list', 'stock_on_hand', 'past_purchases');

-- ───────────────────────── the link table ─────────────────────────


-- Existing files: a specific list of the vendor's branches is kept as it was; anything else a
-- vendor file covered is read as the vendor's active branches today.
insert into qvm_new_apps.upload_batch_branches (batch_id, vendor_branch_id)
select b.batch_id, vb.vendor_branch_id
  from qvm_new_apps.upload_batches b
  join qvm_new_apps.vendor_branches vb on vb.vendor_id = b.source_id
 where b.source_kind = 'vendor' and b.source_id is not null
   and qvm_new_apps.upload_template_is_branch_bound(b.template_key)
   and case when b.branch_kind = 'vendor' and b.branch_scope = 'specific'
                 and coalesce(array_length(b.branch_ids, 1), 0) > 0
            then vb.vendor_branch_id = any(b.branch_ids)
            else coalesce(vb.is_active, true) end
on conflict do nothing;

-- A file whose specific list named nothing of the vendor's (an old client-branch list) falls back
-- to the vendor's active branches, so it is not left covering nowhere.
insert into qvm_new_apps.upload_batch_branches (batch_id, vendor_branch_id)
select b.batch_id, vb.vendor_branch_id
  from qvm_new_apps.upload_batches b
  join qvm_new_apps.vendor_branches vb on vb.vendor_id = b.source_id and coalesce(vb.is_active, true)
 where b.source_kind = 'vendor' and b.source_id is not null
   and qvm_new_apps.upload_template_is_branch_bound(b.template_key)
   and not exists (select 1 from qvm_new_apps.upload_batch_branches x where x.batch_id = b.batch_id)
on conflict do nothing;

update qvm_new_apps.upload_batches b
   set branch_kind = 'vendor',
       branch_ids = array(select bb.vendor_branch_id from qvm_new_apps.upload_batch_branches bb
                           where bb.batch_id = b.batch_id order by 1)
 where qvm_new_apps.upload_template_is_branch_bound(b.template_key)
   and exists (select 1 from qvm_new_apps.upload_batch_branches bb where bb.batch_id = b.batch_id);

-- ───────────────────────── live rows: every row names its branch ─────────────────────────

-- The branches a live row without one is copied onto: its file's, else its vendor's active ones.
create or replace function pg_temp.branches_for(p_batch_id bigint, p_vendor_id integer)
 returns setof bigint language sql stable as $$
  select bb.vendor_branch_id from qvm_new_apps.upload_batch_branches bb where bb.batch_id = p_batch_id
  union all
  select vb.vendor_branch_id from qvm_new_apps.vendor_branches vb
   where vb.vendor_id = p_vendor_id and coalesce(vb.is_active, true)
     and not exists (select 1 from qvm_new_apps.upload_batch_branches bb where bb.batch_id = p_batch_id);
$$;

-- A row is out of place when it names no branch, or a branch that is not its vendor's (old
-- files stored client-branch ids in the vendor column). Both are re-homed the same way.
create or replace function pg_temp.misplaced(p_vendor_id integer, p_vendor_branch_id bigint)
 returns boolean language sql stable as $$
  select p_vendor_branch_id is null
      or not exists (select 1 from qvm_new_apps.vendor_branches vb
                      where vb.vendor_branch_id = p_vendor_branch_id and vb.vendor_id = p_vendor_id);
$$;

do $$
declare v_bad text;
begin
  -- A row whose vendor has nowhere to land would silently vanish below; stop instead.
  select string_agg(distinct t.tbl || ' vendor ' || t.vendor_id, ', ') into v_bad
    from (select 'agency_price_reference' tbl, vendor_id, batch_id from qvm_new_apps.agency_price_reference where pg_temp.misplaced(vendor_id, vendor_branch_id)
          union all select 'inventory_stock', vendor_id, batch_id from qvm_new_apps.inventory_stock where pg_temp.misplaced(vendor_id, vendor_branch_id)
          union all select 'part_purchase_history', vendor_id, batch_id from qvm_new_apps.part_purchase_history where pg_temp.misplaced(vendor_id, vendor_branch_id) and vendor_id is not null) t
   where t.vendor_id is not null
     and not exists (select 1 from pg_temp.branches_for(t.batch_id, t.vendor_id));
  if v_bad is not null then
    raise exception 'rows without a branch whose vendor has no active branch: %', v_bad;
  end if;
  if exists (select 1 from qvm_new_apps.agency_price_reference where vendor_id is null)
     or exists (select 1 from qvm_new_apps.inventory_stock where vendor_id is null) then
    raise exception 'agency or stock rows without a vendor exist; decide where they belong first';
  end if;
end $$;

-- agency: newest first, so where two files priced the same part for the same branch the later
-- price is the one kept.
insert into qvm_new_apps.agency_price_reference
  (source_part_number, clean_part_number, source_name, clean_name, brand, agency_price,
   effective_from, source_label, batch_id, updated_at, expires_on, vendor_id, vendor_branch_id,
   part_class, agency_price_after_discount, dealer_agency_discount_pct, client_branch_id, source_name_en)
select a.source_part_number, a.clean_part_number, a.source_name, a.clean_name, a.brand, a.agency_price,
       a.effective_from, a.source_label, a.batch_id, a.updated_at, a.expires_on, a.vendor_id, br.id,
       a.part_class, a.agency_price_after_discount, a.dealer_agency_discount_pct, null, a.source_name_en
  from qvm_new_apps.agency_price_reference a
  cross join lateral pg_temp.branches_for(a.batch_id, a.vendor_id) as br(id)
 where pg_temp.misplaced(a.vendor_id, a.vendor_branch_id)
 order by a.updated_at desc, a.id desc
on conflict (clean_part_number, coalesce(vendor_id, -1), coalesce(vendor_branch_id, -1::bigint), coalesce(client_branch_id, -1))
do nothing;
delete from qvm_new_apps.agency_price_reference where pg_temp.misplaced(vendor_id, vendor_branch_id);
-- A branch row can still exist twice with different client ids from the old key; keep the newest.
delete from qvm_new_apps.agency_price_reference a
 using qvm_new_apps.agency_price_reference b
 where a.vendor_branch_id = b.vendor_branch_id and a.clean_part_number = b.clean_part_number
   and (a.updated_at, a.id) < (b.updated_at, b.id);
update qvm_new_apps.agency_price_reference set client_branch_id = null where client_branch_id is not null;

-- stock
insert into qvm_new_apps.inventory_stock
  (vendor_id, vendor_branch_id, source_part_number, clean_part_number, source_name, clean_name, brand,
   part_class, country_of_origin, quantity, is_available, wholesale_price, retail_price,
   before_discount_price, claimed_agency_price, claimed_agency_price_after_discount,
   dealer_agency_discount_pct, batch_id, updated_at, source_name_en, clean_name_en, name_is_guess, client_branch_id)
select s.vendor_id, br.id, s.source_part_number, s.clean_part_number, s.source_name, s.clean_name, s.brand,
       s.part_class, s.country_of_origin, s.quantity, s.is_available, s.wholesale_price, s.retail_price,
       s.before_discount_price, s.claimed_agency_price, s.claimed_agency_price_after_discount,
       s.dealer_agency_discount_pct, s.batch_id, s.updated_at, s.source_name_en, s.clean_name_en, s.name_is_guess, null
  from qvm_new_apps.inventory_stock s
  cross join lateral pg_temp.branches_for(s.batch_id, s.vendor_id) as br(id)
 where pg_temp.misplaced(s.vendor_id, s.vendor_branch_id)
 order by s.updated_at desc, s.id desc
on conflict (coalesce(vendor_id, -1), coalesce(vendor_branch_id, -1::bigint), coalesce(client_branch_id, -1), clean_part_number)
do nothing;
delete from qvm_new_apps.inventory_stock where pg_temp.misplaced(vendor_id, vendor_branch_id);
delete from qvm_new_apps.inventory_stock a
 using qvm_new_apps.inventory_stock b
 where a.vendor_branch_id = b.vendor_branch_id and a.clean_part_number = b.clean_part_number
   and (a.updated_at, a.id) < (b.updated_at, b.id);
update qvm_new_apps.inventory_stock set client_branch_id = null where client_branch_id is not null;

-- past purchases: rows with a vendor are copied onto its branches; rows with none are set aside.
create table if not exists qvm_new_apps.part_purchase_history_unscoped
  (like qvm_new_apps.part_purchase_history including defaults);
alter table qvm_new_apps.part_purchase_history_unscoped
  add column if not exists archived_at timestamptz not null default now();
grant select on qvm_new_apps.part_purchase_history_unscoped to service_role;
insert into qvm_new_apps.part_purchase_history_unscoped
  (id, source_part_number, clean_part_number, cost, cost_on, source_cost_date, supplier_name, brand,
   brand_class, origin, batch_id, created_at, city, qty, retail_price, before_discount_price,
   client_branch_id, vendor_id, source_name, source_name_en, vendor_branch_id)
select h.id, h.source_part_number, h.clean_part_number, h.cost, h.cost_on, h.source_cost_date, h.supplier_name, h.brand,
       h.brand_class, h.origin, h.batch_id, h.created_at, h.city, h.qty, h.retail_price, h.before_discount_price,
       h.client_branch_id, h.vendor_id, h.source_name, h.source_name_en, h.vendor_branch_id
  from qvm_new_apps.part_purchase_history h
 where h.vendor_id is null;
delete from qvm_new_apps.part_purchase_history where vendor_id is null;

insert into qvm_new_apps.part_purchase_history
  (source_part_number, clean_part_number, cost, cost_on, source_cost_date, supplier_name, brand,
   brand_class, origin, batch_id, created_at, city, qty, retail_price, before_discount_price,
   client_branch_id, vendor_id, source_name, source_name_en, vendor_branch_id)
select h.source_part_number, h.clean_part_number, h.cost, h.cost_on, h.source_cost_date, h.supplier_name, h.brand,
       h.brand_class, h.origin, h.batch_id, h.created_at, h.city, h.qty, h.retail_price, h.before_discount_price,
       null, h.vendor_id, h.source_name, h.source_name_en, br.id
  from qvm_new_apps.part_purchase_history h
  cross join lateral pg_temp.branches_for(h.batch_id, h.vendor_id) as br(id)
 where pg_temp.misplaced(h.vendor_id, h.vendor_branch_id);
delete from qvm_new_apps.part_purchase_history where pg_temp.misplaced(vendor_id, vendor_branch_id);
update qvm_new_apps.part_purchase_history set client_branch_id = null where client_branch_id is not null;

-- ───────────────────────── constraints and indexes ─────────────────────────

-- A branch is referenced together with its vendor, so a row can never name a branch of some
-- other vendor.
create unique index if not exists vendor_branches_vendor_and_branch
  on qvm_new_apps.vendor_branches (vendor_id, vendor_branch_id);

alter table qvm_new_apps.agency_price_reference
  alter column vendor_id set not null,
  alter column vendor_branch_id set not null,
  add constraint agency_price_reference_vendor_id_fkey
    foreign key (vendor_id) references qvm_new_apps.vendors (vendor_id),
  add constraint agency_price_reference_vendor_branch_fkey
    foreign key (vendor_id, vendor_branch_id) references qvm_new_apps.vendor_branches (vendor_id, vendor_branch_id);
drop index if exists qvm_new_apps.agency_price_reference_part_vendor_branch;
create unique index if not exists agency_price_reference_branch_part
  on qvm_new_apps.agency_price_reference (vendor_branch_id, clean_part_number);
create index if not exists agency_price_reference_part_branch
  on qvm_new_apps.agency_price_reference (clean_part_number, vendor_branch_id);

alter table qvm_new_apps.inventory_stock
  alter column vendor_id set not null,
  alter column vendor_branch_id set not null,
  add constraint inventory_stock_vendor_id_fkey
    foreign key (vendor_id) references qvm_new_apps.vendors (vendor_id),
  add constraint inventory_stock_vendor_branch_fkey
    foreign key (vendor_id, vendor_branch_id) references qvm_new_apps.vendor_branches (vendor_id, vendor_branch_id);
drop index if exists qvm_new_apps.inventory_stock_natural_key;
create unique index if not exists inventory_stock_branch_part
  on qvm_new_apps.inventory_stock (vendor_branch_id, clean_part_number);
create index if not exists inventory_stock_by_part
  on qvm_new_apps.inventory_stock (clean_part_number);

alter table qvm_new_apps.part_purchase_history
  alter column vendor_id set not null,
  alter column vendor_branch_id set not null,
  add constraint part_purchase_history_vendor_branch_fkey
    foreign key (vendor_id, vendor_branch_id) references qvm_new_apps.vendor_branches (vendor_id, vendor_branch_id);
create index if not exists part_purchase_history_branch_part_date
  on qvm_new_apps.part_purchase_history (vendor_branch_id, clean_part_number, cost_on desc);

create index if not exists upload_batches_by_source
  on qvm_new_apps.upload_batches (source_id, template_key, status, created_at desc);

-- ───────────────────────── functions ─────────────────────────

CREATE OR REPLACE FUNCTION qvm_new_apps.upload_batch_stage(p_template_key text, p_file_name text, p_rows jsonb, p_source_kind text DEFAULT 'vendor'::text, p_source_id bigint DEFAULT NULL::bigint, p_source_label text DEFAULT NULL::text, p_branch_scope text DEFAULT 'all'::text, p_branch_ids bigint[] DEFAULT '{}'::bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_batch bigint; v_row jsonb; v_clean jsonb; v_n integer := 0;
  v_seen text[] := '{}'; v_state text;
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_kind text := p_source_kind; v_sid bigint := p_source_id; v_label text := p_source_label;
  v_ids bigint[] := coalesce(p_branch_ids, '{}');
  v_scoped boolean; v_strict boolean;
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  if not exists (select 1 from qvm_new_apps.upload_templates
                  where template_key = p_template_key and is_active
                    and (v_team or allowed_for_vendor)) then
    return jsonb_build_object('status', false,
      'message', case when v_team then 'نوع ملف غير معروف'
                      else 'هذا النوع من الملفات لا يرفعه المورد' end, 'data', null);
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    return jsonb_build_object('status', false, 'message', 'الملف لا يحتوي على صفوف', 'data', null);
  end if;

  -- A vendor writes as themselves whatever the request said. Trusting the
  -- caller here would let one supplier file stock under another's name, and
  -- the code rules are keyed on that name.
  if not v_team then
    v_kind := 'vendor';
    v_sid := v_vendor;
    select vendor_name into v_label from qvm_new_apps.vendors where vendor_id = v_vendor;
  end if;

  -- Agency lists, stock and past purchases are a vendor's and land on that vendor's branches:
  -- the file names the vendor, and the chosen branches are kept as rows on the batch. «All
  -- branches» is resolved here to the branches the vendor has today, so it is a list and not a
  -- promise about branches opened later. Ids that are not this vendor's are dropped rather than
  -- failed on; an empty result is refused, because a file that lands nowhere is not saved.
  select t.needs_branch into v_scoped from qvm_new_apps.upload_templates t
   where t.template_key = p_template_key;
  v_strict := qvm_new_apps.upload_template_is_branch_bound(p_template_key);
  if v_strict and (v_kind <> 'vendor' or v_sid is null) then
    return jsonb_build_object('status', false,
      'message', 'اختر المورّد الذي يخص هذا الملف', 'data', null);
  end if;
  if coalesce(v_scoped, false) and v_kind = 'vendor' and v_sid is not null then
    v_ids := qvm_new_apps.upload_branches_resolve(v_sid::integer, p_branch_scope, v_ids, v_strict);
    if v_strict and coalesce(array_length(v_ids, 1), 0) = 0 then
      return jsonb_build_object('status', false,
        'message', case when p_branch_scope = 'specific'
                        then 'اختر فرعًا واحدًا على الأقل من فروع المورّد'
                        else 'ليس لهذا المورّد فروع نشطة — أضف فرعًا له أولًا' end, 'data', null);
    end if;
    if not v_strict and p_branch_scope = 'specific' and coalesce(array_length(v_ids, 1), 0) = 0 then
      return jsonb_build_object('status', false,
        'message', 'لم تُختَر فروع تخصّ هذا المورّد', 'data', null);
    end if;
  elsif not v_team and p_branch_scope = 'specific' and coalesce(array_length(v_ids, 1), 0) = 0 then
    return jsonb_build_object('status', false,
      'message', 'لم تُختَر فروع تخصّك', 'data', null);
  end if;

  insert into qvm_new_apps.upload_batches
    (template_key, file_name, source_kind, source_id, source_label,
     branch_scope, branch_ids, branch_kind, status, uploaded_by)
  values (p_template_key, p_file_name, v_kind, v_sid, v_label,
          p_branch_scope, v_ids, 'vendor', 'preview', auth.uid())
  returning batch_id into v_batch;

  insert into qvm_new_apps.upload_batch_branches (batch_id, vendor_branch_id)
  select v_batch, x.id from unnest(v_ids) as x(id)
  on conflict do nothing;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_n := v_n + 1;
    v_clean := qvm_new_apps.upload_clean_row(v_row, p_template_key, v_kind, v_sid);
    v_state := v_clean->>'state';
    if v_state not in ('rejected', 'held') and (v_clean->>'clean_part_number') = any(v_seen) then
      v_state := 'duplicate';
    elsif v_state not in ('rejected', 'held') then
      v_seen := v_seen || (v_clean->>'clean_part_number');
    end if;

    insert into qvm_new_apps.upload_rows
      -- raw_source is the file as the supplier wrote it and is never rewritten. Without it,
      -- applying a column map a second time reads our own canonical names back as if they were
      -- the file's headers, offers to ignore them, and destroys the columns it just filled.
      (batch_id, row_number, raw, raw_source, source_part_number, clean_part_number,
       display_part_number, source_name, clean_name, source_name_en, clean_name_en, name_is_guess,
       matched_rule_id, brand,
       part_class, country_of_origin, state, reason)
    values (v_batch, v_n, v_row, v_row,
            v_clean->>'source_part_number', v_clean->>'clean_part_number',
            v_clean->>'display_part_number',
            v_clean->>'source_name', v_clean->>'clean_name',
            v_clean->>'source_name_en', v_clean->>'clean_name_en',
            coalesce((v_clean->>'name_is_guess')::boolean, false),
            nullif(v_clean->>'matched_rule_id', '')::bigint,
            v_clean->>'brand', v_clean->>'part_class', v_clean->>'country_of_origin',
            v_state,
            case when v_state = 'duplicate' then 'مكرر داخل نفس الملف'
                 else v_clean->>'reason' end);
  end loop;

  update qvm_new_apps.upload_batches b set
    rows_total     = v_n,
    rows_ready     = (select count(*) from qvm_new_apps.upload_rows where batch_id = v_batch and state = 'ready'),
    rows_disabled  = (select count(*) from qvm_new_apps.upload_rows where batch_id = v_batch and state = 'disabled'),
    rows_rejected  = (select count(*) from qvm_new_apps.upload_rows where batch_id = v_batch and state = 'rejected'),
    rows_duplicate = (select count(*) from qvm_new_apps.upload_rows where batch_id = v_batch and state = 'duplicate'),
    rows_held      = (select count(*) from qvm_new_apps.upload_rows where batch_id = v_batch and state = 'held'),
    updated_at     = now()
  where b.batch_id = v_batch;

  insert into qvm_new_apps.upload_batch_log (batch_id, action, detail, changed_by)
  values (v_batch, 'stage', jsonb_build_object('file', p_file_name, 'rows', v_n), auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', (select to_jsonb(b) || jsonb_build_object('branches', qvm_new_apps.upload_batch_branches_json(b.batch_id))
               from qvm_new_apps.upload_batches b where b.batch_id = v_batch));
end
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.upload_batch_set_source(p_batch_id bigint, p_vendor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_name text;
  v_batch record;
  v_strict boolean;
  v_ids bigint[];
  v_scope text;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select * into v_batch from qvm_new_apps.upload_batches where batch_id = p_batch_id;
  if v_batch.batch_id is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;
  v_strict := qvm_new_apps.upload_template_is_branch_bound(v_batch.template_key);

  -- Rows of an agency list, a stock file or a purchase file are stamped with the vendor and the
  -- branch when they are published. Moving the file to another vendor afterwards would leave
  -- those rows where they were, so the file's data is removed first, then it is re-attached.
  if v_strict and v_batch.status = 'published' then
    return jsonb_build_object('status', false,
      'message', 'هذا الملف منشور باسم مورّد؛ احذف بياناته المنشورة أولًا ثم غيّر المورّد', 'data', null);
  end if;

  if p_vendor_id is null then
    if v_strict then
      return jsonb_build_object('status', false,
        'message', 'هذا النوع من الملفات يخص مورّدًا ولا يُحفظ بلا مورّد', 'data', null);
    end if;
    update qvm_new_apps.upload_batches
       set source_kind = 'internal', source_id = null, source_label = null, updated_at = now()
     where batch_id = p_batch_id;
    delete from qvm_new_apps.upload_batch_branches where batch_id = p_batch_id;
  else
    select v.vendor_name into v_name from qvm_new_apps.vendors v where v.vendor_id = p_vendor_id;
    if v_name is null then
      return jsonb_build_object('status', false, 'message', 'المورّد غير موجود', 'data', null);
    end if;

    -- The chosen branches were the old vendor's. Whatever of them the new vendor also has is
    -- kept; when nothing carries over, the file covers the new vendor's branches in full, and
    -- the scope says so.
    v_scope := v_batch.branch_scope;
    v_ids := qvm_new_apps.upload_branches_resolve(p_vendor_id::integer, v_scope, v_batch.branch_ids, v_strict);
    if v_strict and coalesce(array_length(v_ids, 1), 0) = 0 and v_scope = 'specific' then
      v_scope := 'all';
      v_ids := qvm_new_apps.upload_branches_resolve(p_vendor_id::integer, 'all', '{}', true);
    end if;
    if v_strict and coalesce(array_length(v_ids, 1), 0) = 0 then
      return jsonb_build_object('status', false,
        'message', 'ليس لهذا المورّد فروع نشطة — أضف فرعًا له أولًا', 'data', null);
    end if;

    update qvm_new_apps.upload_batches
       set source_kind = 'vendor', source_id = p_vendor_id, source_label = v_name,
           branch_scope = v_scope, branch_ids = v_ids, branch_kind = 'vendor', updated_at = now()
     where batch_id = p_batch_id;
    delete from qvm_new_apps.upload_batch_branches where batch_id = p_batch_id;
    insert into qvm_new_apps.upload_batch_branches (batch_id, vendor_branch_id)
    select p_batch_id, x.id from unnest(v_ids) as x(id)
    on conflict do nothing;
  end if;

  insert into qvm_new_apps.upload_batch_log (batch_id, action, detail, changed_by)
  values (p_batch_id, 'set_source',
          jsonb_build_object('vendor_id', p_vendor_id, 'branches', v_ids), auth.uid());

  -- Re-read the file against the newly attached vendor's code rules.
  return qvm_new_apps.upload_batch_recompute(p_batch_id);
end
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.upload_batch_write_rows(p_batch_id bigint)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_b record; v_written integer := 0; v_extra integer := 0; v_branches bigint[];
  v_p jsonb; v_gap integer;
  v_eff date; v_exp date; v_starts date; v_ends date; v_closes date; v_req_end date;
  v_country text; v_terms text; v_weeks integer; v_campaign bigint;
  v_strict boolean;
begin
  select * into v_b from qvm_new_apps.upload_batches where batch_id = p_batch_id;
  if v_b.batch_id is null then return 0; end if;
  v_p := coalesce(v_b.params, '{}'::jsonb);

  v_eff     := nullif(btrim(coalesce(v_p->>'effective_from','')), '')::date;
  v_exp     := nullif(btrim(coalesce(v_p->>'expires_on','')), '')::date;
  v_starts  := nullif(btrim(coalesce(v_p->>'starts_on','')), '')::date;
  v_ends    := nullif(btrim(coalesce(v_p->>'ends_on','')), '')::date;
  v_closes  := nullif(btrim(coalesce(v_p->>'closes_on','')), '')::date;
  v_req_end := nullif(btrim(coalesce(v_p->>'request_end_date','')), '')::date;
  v_country := nullif(btrim(coalesce(v_p->>'origin_country','')), '');
  v_terms   := nullif(btrim(coalesce(v_p->>'payment_terms','')), '');
  v_weeks   := nullif(btrim(coalesce(v_p->>'arrival_weeks','')), '')::integer;
  v_campaign := nullif(btrim(coalesce(v_p->>'campaign_id','')), '')::bigint;
  -- Offers, group imports and auctions each belong to something named. Without it the rows
  -- land as an unattached pile that nothing can close, price or show.
  if v_b.template_key in ('offers','group_import_request','stock_auction')
     and v_campaign is null then
    -- plpgsql's raise takes a bare %, not %s; the stray letter printed as «عرضًاs».
    raise exception 'اختر أو أنشئ % قبل الحفظ',
      case v_b.template_key when 'offers' then 'عرضًا'
                            when 'group_import_request' then 'شحنة'
                            else 'مزادًا' end;
  end if;

  -- Agency lists, stock and past purchases belong to one vendor and to the branches chosen for
  -- the file, which the batch keeps as rows in upload_batch_branches. «All branches» was resolved
  -- to that explicit list when the file was staged, so a branch opened later never inherits an
  -- old file. Every staged row is written once per branch: a lookup by branch is then a plain
  -- index probe with no NULL fallback to reason about.
  v_strict := qvm_new_apps.upload_template_is_branch_bound(v_b.template_key);
  v_branches := array(select bb.vendor_branch_id from qvm_new_apps.upload_batch_branches bb
                       where bb.batch_id = p_batch_id order by bb.vendor_branch_id);
  if v_strict then
    if v_b.source_kind <> 'vendor' or v_b.source_id is null then
      raise exception 'اختر المورّد الذي يخص هذا الملف قبل النشر';
    end if;
    if coalesce(array_length(v_branches, 1), 0) = 0 then
      raise exception 'حدّد فروع المورّد التي يغطيها هذا الملف قبل النشر';
    end if;
  else
    -- Offers and auctions keep their older reading: a specific list fans out, «all» writes one
    -- row with no branch.
    v_branches := case
      when v_b.branch_scope = 'specific' and coalesce(array_length(v_branches, 1), 0) > 0 then v_branches
      when v_b.branch_scope = 'specific' and coalesce(array_length(v_b.branch_ids, 1), 0) > 0 then v_b.branch_ids
      else array[null]::bigint[] end;
  end if;

  if v_b.template_key = 'agency_price_list' then
    insert into qvm_new_apps.agency_price_reference
      (vendor_id, vendor_branch_id, source_part_number, clean_part_number,
       source_name, clean_name, brand, part_class,
       agency_price, agency_price_after_discount, dealer_agency_discount_pct,
       effective_from, expires_on, source_label, batch_id)
    select v_b.source_id::integer, br.id,
           r.source_part_number, r.clean_part_number, r.source_name, r.clean_name,
           r.brand, r.part_class,
           (r.raw->>'agency_price')::numeric,
           nullif(r.raw->>'agency_price_after_discount','')::numeric,
           nullif(r.raw->>'dealer_agency_discount_pct','')::numeric,
           current_date,   -- in force from the day it landed, re-stamped on replacement
           coalesce(nullif(r.raw->>'expires_on','')::date, v_exp),
           coalesce(v_b.source_label, 'agency'), v_b.batch_id
      from qvm_new_apps.upload_rows r
      cross join unnest(v_branches) as br(id)
     where r.batch_id = p_batch_id and r.state = 'ready'
    on conflict (vendor_branch_id, clean_part_number)
    do update set
      source_part_number = excluded.source_part_number,
      source_name = excluded.source_name, clean_name = excluded.clean_name,
      brand = excluded.brand, part_class = excluded.part_class,
      agency_price = excluded.agency_price,
      agency_price_after_discount = excluded.agency_price_after_discount,
      dealer_agency_discount_pct = excluded.dealer_agency_discount_pct,
      effective_from = excluded.effective_from, expires_on = excluded.expires_on,
      source_label = excluded.source_label,
      batch_id = excluded.batch_id, updated_at = now();
    get diagnostics v_written = row_count;

  elsif v_b.template_key = 'stock_on_hand' then
    insert into qvm_new_apps.inventory_stock
      (vendor_id, vendor_branch_id, source_part_number, clean_part_number,
       source_name, clean_name, source_name_en, clean_name_en, name_is_guess, brand, part_class, country_of_origin,
       quantity, is_available, wholesale_price, retail_price, before_discount_price, batch_id)
    select v_b.source_id::integer, br.id,
           r.source_part_number, r.clean_part_number, r.source_name, r.clean_name,
           r.source_name_en, r.clean_name_en, r.name_is_guess,
           r.brand, r.part_class, r.country_of_origin,
           case when r.raw->>'qty' ~ '^[0-9]+$' then (r.raw->>'qty')::integer else null end,
           coalesce(lower(btrim(r.raw->>'qty')) not in ('0','notavailable','not available','غير متوفر'), true),
           nullif(r.raw->>'wholesale_price','')::numeric,
           nullif(r.raw->>'retail_price','')::numeric,
           nullif(r.raw->>'before_discount_price','')::numeric,
           v_b.batch_id
      from qvm_new_apps.upload_rows r
      cross join unnest(v_branches) as br(id)
     where r.batch_id = p_batch_id and r.state = 'ready'
    on conflict (vendor_branch_id, clean_part_number)
    do update set
      source_part_number = excluded.source_part_number,
      source_name = excluded.source_name, clean_name = excluded.clean_name,
      source_name_en = excluded.source_name_en, clean_name_en = excluded.clean_name_en,
      name_is_guess = excluded.name_is_guess,
      brand = excluded.brand, part_class = excluded.part_class,
      country_of_origin = excluded.country_of_origin,
      quantity = excluded.quantity, is_available = excluded.is_available,
      wholesale_price = excluded.wholesale_price, retail_price = excluded.retail_price,
      before_discount_price = excluded.before_discount_price,
      batch_id = excluded.batch_id, updated_at = now();
    get diagnostics v_written = row_count;

  elsif v_b.template_key = 'past_purchases' then
    -- The supplier is resolved to a real vendor rather than filed under whatever was typed, and
    -- numbers and dates go through the shared normalisers — so «١٬٢٣٤٫٥٠» and «1,234.50» are one
    -- price and a spreadsheet serial is a date.
    --
    -- Two passes of de-duplication, because they catch different things. `not exists` compares
    -- against what is already stored, and cannot see rows being written by its own statement —
    -- so a file listing the same purchase twice under two spellings of the supplier wrote it
    -- twice, which is the duplicate this whole feature exists to stop. `distinct on` settles
    -- that within the file first, on the resolved vendor rather than the raw text.
    with src as (
      select r.row_number, r.source_part_number, r.clean_part_number, r.brand, r.part_class,
             r.source_name, r.source_name_en,
             r.raw, br.id as branch_id,
             -- The vendor is the one the file was uploaded for. The supplier column still names
             -- the row (and can still drop it when that name was marked ignored), but it no longer
             -- files the purchase under another vendor than the one whose branches were chosen.
             v_b.source_id::integer as vendor_id, m.vendor_name, m.status as match_status,
             -- The file first, so a sheet written before the source picker existed still
             -- imports as it always did; the form second, which is now where the answer is.
             coalesce(qvm_new_apps.upload_raw_get(r.raw, 'supplier_name'),
                      v_b.source_label) as v_supplier,
             -- Either header. A sheet filled in before the column was renamed is not a
             -- sheet anybody is going to fill in again.
             coalesce(qvm_new_apps.upload_raw_get(r.raw, 'branch'),
                      qvm_new_apps.upload_raw_get(r.raw, 'city')) as v_city,
             -- The line names its branch; the picker covers the line that does not. Only for
             -- batches whose branches are the supplier's — on an old client-scoped batch this
             -- lookup would match a vendor branch id against one of ours.
             -- A line that names one of the chosen branches lands there; any other line lands on
             -- each chosen branch. A name outside the chosen set is not a way around the choice.
             case when bm.id = any(v_branches) then bm.id else br.id end as v_branch_id,
             qvm_new_apps.norm_number(r.raw->>'wholesale_price')::double precision as v_cost,
             qvm_new_apps.norm_date(r.raw->>'purchase_date') as v_date
        from qvm_new_apps.upload_rows r
        cross join unnest(v_branches) as br(id)
        cross join lateral qvm_new_apps.vendor_match(
                     qvm_new_apps.upload_raw_get(r.raw, 'supplier_name')) m
        cross join lateral (select qvm_new_apps.vendor_branch_match(
                     v_b.source_id::integer,
                     coalesce(qvm_new_apps.upload_raw_get(r.raw, 'branch'),
                              qvm_new_apps.upload_raw_get(r.raw, 'city'))) as id) bm
       where r.batch_id = p_batch_id and r.state = 'ready'
         -- A name somebody chose to drop takes its rows with it.
         and m.status <> 'ignored'
    ), dedup_in_file as (
      select distinct on (
               s.clean_part_number, coalesce(s.v_branch_id, s.branch_id),
               coalesce(s.vendor_id::text, qvm_new_apps.norm_text(s.v_supplier)),
               qvm_new_apps.norm_text(s.v_city), s.v_date, s.v_cost) s.*
        from src s
       order by s.clean_part_number, coalesce(s.v_branch_id, s.branch_id),
                coalesce(s.vendor_id::text, qvm_new_apps.norm_text(s.v_supplier)),
                qvm_new_apps.norm_text(s.v_city), s.v_date, s.v_cost, s.row_number
    )
    insert into qvm_new_apps.part_purchase_history
      (source_part_number, clean_part_number, source_name, source_name_en,
       cost, retail_price, before_discount_price,
       cost_on, source_cost_date,
       supplier_name, vendor_id, city, qty, brand, brand_class, origin,
       client_branch_id, vendor_branch_id, batch_id)
    select d.source_part_number, d.clean_part_number, d.source_name, d.source_name_en, d.v_cost,
           qvm_new_apps.norm_number(d.raw->>'retail_price'),
           qvm_new_apps.norm_number(d.raw->>'before_discount_price'),
           d.v_date, d.raw->>'purchase_date',
           coalesce(d.vendor_name, d.v_supplier, v_b.source_label),
           coalesce(d.vendor_id, v_b.source_id::integer), d.v_city,
           qvm_new_apps.norm_number(d.raw->>'qty')::integer,
           d.brand, d.part_class, 'external_excel',
           null, d.v_branch_id,
           v_b.batch_id
      from dedup_in_file d
     where not exists (
       select 1 from qvm_new_apps.part_purchase_history h
        where h.clean_part_number = d.clean_part_number
          and h.vendor_branch_id = d.v_branch_id
          and (h.vendor_id is not distinct from d.vendor_id
               or qvm_new_apps.norm_text(h.supplier_name)
                  is not distinct from qvm_new_apps.norm_text(d.v_supplier))
          and qvm_new_apps.norm_text(h.city) is not distinct from qvm_new_apps.norm_text(d.v_city)
          and h.cost_on is not distinct from d.v_date
          and h.cost is not distinct from d.v_cost);
    get diagnostics v_written = row_count;

  elsif v_b.template_key = 'aliases' then
    insert into qvm_new_apps.part_aliases
      (clean_part_number, clean_alias, source_part_number, source_alias, brand, note, batch_id)
    select r.clean_part_number, qvm_new_apps.normalize_part_number(r.raw->>'alias_part_number'),
           r.source_part_number, r.raw->>'alias_part_number', r.brand, r.raw->>'note', v_b.batch_id
      from qvm_new_apps.upload_rows r
     where r.batch_id = p_batch_id and r.state = 'ready'
       and qvm_new_apps.normalize_part_number(r.raw->>'alias_part_number') is not null
       and qvm_new_apps.normalize_part_number(r.raw->>'alias_part_number') <> r.clean_part_number
    on conflict (clean_part_number, clean_alias) do nothing;
    get diagnostics v_written = row_count;

    insert into qvm_new_apps.part_aliases
      (clean_part_number, clean_alias, source_part_number, source_alias, brand, note, batch_id)
    select qvm_new_apps.normalize_part_number(r.raw->>'alias_part_number'), r.clean_part_number,
           r.raw->>'alias_part_number', r.source_part_number, r.brand, r.raw->>'note', v_b.batch_id
      from qvm_new_apps.upload_rows r
     where r.batch_id = p_batch_id and r.state = 'ready'
       and qvm_new_apps.normalize_part_number(r.raw->>'alias_part_number') is not null
       and qvm_new_apps.normalize_part_number(r.raw->>'alias_part_number') <> r.clean_part_number
    on conflict (clean_part_number, clean_alias) do nothing;
    get diagnostics v_extra = row_count;
    v_written := v_written + v_extra;

  elsif v_b.template_key = 'offers' then
    select count(*) into v_gap
      from qvm_new_apps.upload_rows r
     where r.batch_id = p_batch_id and r.state = 'ready'
       and (coalesce(nullif(r.raw->>'starts_on','')::date, v_starts) is null
         or coalesce(nullif(r.raw->>'ends_on','')::date, v_ends) is null);
    if v_gap > 0 then
      raise exception 'حدّد بداية العرض ونهايته في شاشة الرفع — % صف بلا نافذة سريان', v_gap;
    end if;

    insert into qvm_new_apps.part_offers
      (vendor_id, vendor_branch_id, source_part_number, clean_part_number,
       offer_price, part_class, starts_on, ends_on, qty_limit, campaign_id, batch_id)
    select v_b.source_id::integer, br.id,
           r.source_part_number, r.clean_part_number,
           (r.raw->>'offer_price')::numeric, r.part_class,
           coalesce(nullif(r.raw->>'starts_on','')::date, v_starts),
           coalesce(nullif(r.raw->>'ends_on','')::date, v_ends),
           nullif(r.raw->>'qty_limit','')::integer, v_campaign, v_b.batch_id
      from qvm_new_apps.upload_rows r
      cross join unnest(v_branches) as br(id)
     where r.batch_id = p_batch_id and r.state = 'ready';
    get diagnostics v_written = row_count;

  elsif v_b.template_key = 'group_import_request' then
    insert into qvm_new_apps.group_import_requests
      (source_part_number, clean_part_number, source_name, clean_name, qty,
       target_price, brand, part_class, origin_country, payment_terms, arrival_weeks, request_end_date, campaign_id, batch_id)
    select r.source_part_number, r.clean_part_number, r.source_name, r.clean_name,
           (r.raw->>'qty')::integer, nullif(r.raw->>'target_price','')::numeric,
           r.brand, r.part_class,
           coalesce(nullif(btrim(coalesce(r.raw->>'origin_country','')),''), v_country),
           coalesce(nullif(btrim(coalesce(r.raw->>'payment_terms','')),''), v_terms),
           coalesce(nullif(r.raw->>'arrival_weeks','')::integer, v_weeks),
           coalesce(nullif(r.raw->>'request_end_date','')::date, v_req_end),
           v_campaign, v_b.batch_id
      from qvm_new_apps.upload_rows r
     where r.batch_id = p_batch_id and r.state = 'ready';
    get diagnostics v_written = row_count;

  elsif v_b.template_key = 'stock_auction' then
    insert into qvm_new_apps.stock_auction_items
      (vendor_id, vendor_branch_id, source_part_number, clean_part_number,
       source_name, clean_name, source_name_en, clean_name_en,
       qty, brand, part_class, reserve_price, closes_on, campaign_id, batch_id)
    select v_b.source_id::integer, br.id,
           r.source_part_number, r.clean_part_number, r.source_name, r.clean_name,
           r.source_name_en, r.clean_name_en,
           (r.raw->>'qty')::integer, r.brand, r.part_class,
           nullif(r.raw->>'reserve_price','')::numeric,
           coalesce(nullif(r.raw->>'closes_on','')::date, v_closes), v_campaign, v_b.batch_id
      from qvm_new_apps.upload_rows r
      cross join unnest(v_branches) as br(id)
     where r.batch_id = p_batch_id and r.state = 'ready';
    get diagnostics v_written = row_count;

  else
    raise exception 'نوع ملف غير مدعوم للنشر: %', v_b.template_key;
  end if;

  perform qvm_new_apps.parts_catalog_absorb(
            r.clean_part_number, r.brand, r.part_class, r.country_of_origin,
            r.clean_name, r.clean_name_en,
            case when v_b.source_kind = 'vendor' then 'vendor' else null end,
            v_b.source_id)
     from qvm_new_apps.upload_rows r
    where r.batch_id = p_batch_id and r.state = 'ready';

  return v_written;
end
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.upload_batch_get(p_batch_id bigint, p_state text DEFAULT NULL::text, p_limit integer DEFAULT 200, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
begin
  if not qvm_new_apps.may_touch_upload_batch(p_batch_id) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'batch', (select to_jsonb(b) || jsonb_build_object('branches', qvm_new_apps.upload_batch_branches_json(b.batch_id))
                from qvm_new_apps.upload_batches b where b.batch_id = p_batch_id),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'row_id', r.row_id, 'row_number', r.row_number,
               'source_part_number', r.source_part_number,
               'display_part_number', r.display_part_number,
               'clean_part_number', r.clean_part_number,
               'source_name', r.source_name, 'clean_name', r.clean_name,
               'source_name_en', r.source_name_en, 'clean_name_en', r.clean_name_en,
               -- Whether the name was read from the sheet or worked out from a similar part
               -- number. Without it the preview cannot tell «مُملّى تلقائيًا» from «اسم مقترح»,
               -- and the badge that warns about a guess could never appear at all.
               'name_is_guess', r.name_is_guess,
               -- Set once a person corrected the row by hand; a recompute then leaves it alone.
               'edited_at', r.edited_at,
               'brand', r.brand, 'part_class', r.part_class,
               'country_of_origin', r.country_of_origin,
               'matched_rule', (select rr.code || ' (' || rr.position || ')'
                                  from qvm_new_apps.upload_code_rules rr
                                 where rr.rule_id = r.matched_rule_id),
               'state', r.state, 'reason', r.reason, 'raw', r.raw)
             order by r.row_number)
        from (select * from qvm_new_apps.upload_rows
               where batch_id = p_batch_id and (p_state is null or state = p_state)
               order by row_number limit p_limit offset p_offset) r), '[]'::jsonb),
    'shown', (select count(*) from qvm_new_apps.upload_rows
               where batch_id = p_batch_id and (p_state is null or state = p_state))
  ));
end
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.upload_page_get()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_scope integer[] := qvm_new_apps.get_internal_branch_scope(auth.uid());
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(

    'is_vendor', not v_team,
    'vendor_id', v_vendor,

    'templates', coalesce((
      select jsonb_agg(to_jsonb(t) order by t.sort_order)
        from qvm_new_apps.upload_templates t
       where t.is_active and (v_team or t.allowed_for_vendor)), '[]'::jsonb),

    'rules', coalesce((
      select jsonb_agg(jsonb_build_object(
               'rule_id', r.rule_id, 'source_kind', r.source_kind,
               'source_id', r.source_id, 'source_label', r.source_label,
               'code', r.code, 'position', r.position, 'treatment', r.treatment,
               'brand', r.brand, 'part_class', r.part_class,
               'record_kind', r.record_kind,
               'country_of_origin', r.country_of_origin, 'created_at', r.created_at,
               'linked', (select count(*) from qvm_new_apps.upload_rows u
                           where u.matched_rule_id = r.rule_id),
               'unlinked', (select count(*) from qvm_new_apps.upload_rows u
                             join qvm_new_apps.upload_batches b on b.batch_id = u.batch_id
                            where b.source_kind = r.source_kind
                              and coalesce(b.source_id, -1) = coalesce(r.source_id, -1)
                              and u.state = 'disabled'))
             order by r.source_label, r.code)
        from qvm_new_apps.upload_code_rules r
       where v_team or (r.source_kind = 'vendor' and r.source_id = v_vendor)), '[]'::jsonb),

    'batches', coalesce((
      select jsonb_agg(jsonb_build_object(
               'batch_id', b.batch_id, 'template_key', b.template_key,
               'file_name', b.file_name, 'status', b.status,
               'source_label', b.source_label, 'branch_scope', b.branch_scope,
               'branches', qvm_new_apps.upload_batch_branches_json(b.batch_id),
               'rows_total', b.rows_total, 'rows_ready', b.rows_ready,
               'rows_disabled', b.rows_disabled, 'rows_rejected', b.rows_rejected,
               'rows_duplicate', b.rows_duplicate, 'rows_held', b.rows_held,
               'uploaded_by_name', u.user_name,
               'created_at', b.created_at, 'published_at', b.published_at)
             order by b.created_at desc)
        from (select * from qvm_new_apps.upload_batches
               where qvm_new_apps.is_qparts_team()
                  or (source_kind = 'vendor' and source_id = qvm_new_apps.current_upload_vendor_id())
               order by created_at desc limit 50) b
        left join qvm_new_apps.user_data u on u.user_id = b.uploaded_by), '[]'::jsonb),

    'totals', (select jsonb_build_object(
                 'accepted', coalesce(sum(rows_ready), 0),
                 'failed', coalesce(sum(rows_rejected), 0))
                 from qvm_new_apps.upload_batches b
                where v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor)),

    'options', jsonb_build_object(
      -- A vendor picks nothing: they are the source, and their own branches
      -- are the only ones on offer.
      'vendors', coalesce((select jsonb_agg(jsonb_build_object('id', v.vendor_id, 'name', v.vendor_name)
                                   order by v.vendor_name)
                             from qvm_new_apps.vendors v
                            where v_team or v.vendor_id = v_vendor), '[]'::jsonb),
      'client_branches', coalesce((select jsonb_agg(jsonb_build_object(
                             'id', cb.customer_id, 'name', cb.branch_name,
                             'city', cb.city, 'company', ld.list_data)
                           order by cb.branch_name)
                             from qvm_new_apps.client_branches cb
                             left join qvm_new_apps.list_data ld on ld.list_data_id = cb.list_data_id
                            where coalesce(btrim(cb.branch_name), '''') <> ''''
                              and (v_scope is null or cb.customer_id = any(v_scope))), '[]'::jsonb),
      'vendor_branches', coalesce((select jsonb_agg(jsonb_build_object(
                             'id', vb.vendor_branch_id, 'vendor_id', vb.vendor_id,
                             'name', coalesce(vb.branch_name, ''), 'city', vb.city)
                           order by vb.branch_name)
                             from qvm_new_apps.vendor_branches vb
                            where coalesce(vb.is_active, true)
                              and (v_team or vb.vendor_id = v_vendor)), '[]'::jsonb),
      'part_classes', jsonb_build_array(
        jsonb_build_object('key','genuine','label_en','Genuine','label_ar','أصلي'),
        jsonb_build_object('key','oem','label_en','OEM','label_ar','OEM'),
        jsonb_build_object('key','commercial','label_en','Aftermarket','label_ar','تجاري'),
        jsonb_build_object('key','aftermarket_a','label_en','Aftermarket Grade A','label_ar','تجاري درجة أولى'),
        jsonb_build_object('key','aftermarket_b','label_en','Aftermarket Grade B','label_ar','تجاري درجة ثانية'),
        jsonb_build_object('key','used','label_en','Used','label_ar','مستعمل'),
        jsonb_build_object('key','remanufactured','label_en','Remanufactured','label_ar','مُجدَّد'))
    )
  ));
end
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.uploaded_data_get(p_template_key text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_search text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'is_team', v_team,

    'batches', coalesce((
      select jsonb_agg(jsonb_build_object(
               'batch_id', b.batch_id, 'template_key', b.template_key,
               'template_label', tpl.label_ar, 'file_name', b.file_name,
               'status', b.status, 'source_kind', b.source_kind,
               'source_id', b.source_id,
               'source_label', b.source_label, 'branch_scope', b.branch_scope,
               'branches', qvm_new_apps.upload_batch_branches_json(b.batch_id),
               'rows_total', b.rows_total, 'rows_ready', b.rows_ready,
               'rows_disabled', b.rows_disabled, 'rows_rejected', b.rows_rejected,
               'rows_duplicate', b.rows_duplicate, 'rows_held', b.rows_held,
               'uploaded_by_name', u.user_name,
               'created_at', b.created_at, 'published_at', b.published_at,
               'delete_request', (
                 select jsonb_build_object('request_id', r.request_id, 'status', r.status,
                                           'reason', r.reason, 'requested_at', r.requested_at,
                                           'requested_by_name', ru.user_name)
                   from qvm_new_apps.upload_delete_requests r
                   left join qvm_new_apps.user_data ru on ru.user_id = r.requested_by
                  where r.batch_id = b.batch_id and r.status = 'pending'
                  limit 1),
               'live_rows', case b.template_key
                 when 'agency_price_list' then (select count(*) from qvm_new_apps.agency_price_reference x where x.batch_id = b.batch_id)
                 when 'stock_on_hand'     then (select count(*) from qvm_new_apps.inventory_stock x where x.batch_id = b.batch_id)
                 when 'past_purchases'    then (select count(*) from qvm_new_apps.part_purchase_history x where x.batch_id = b.batch_id)
                 when 'aliases'           then (select count(*) from qvm_new_apps.part_aliases x where x.batch_id = b.batch_id)
                 when 'offers'            then (select count(*) from qvm_new_apps.part_offers x where x.batch_id = b.batch_id)
                 when 'group_import_request' then (select count(*) from qvm_new_apps.group_import_requests x where x.batch_id = b.batch_id)
                 when 'stock_auction'     then (select count(*) from qvm_new_apps.stock_auction_items x where x.batch_id = b.batch_id)
                 else 0 end)
             order by b.created_at desc)
        from (select * from qvm_new_apps.upload_batches
               where (p_template_key is null or template_key = p_template_key)
                 and (p_status is null or status = p_status)
                 and (p_search is null or file_name ilike '%' || p_search || '%'
                      or coalesce(source_label,'') ilike '%' || p_search || '%')
                 and (qvm_new_apps.is_qparts_team()
                      or (source_kind = 'vendor' and source_id = qvm_new_apps.current_upload_vendor_id()))
               order by created_at desc limit p_limit offset p_offset) b
        join qvm_new_apps.upload_templates tpl on tpl.template_key = b.template_key
        left join qvm_new_apps.user_data u on u.user_id = b.uploaded_by), '[]'::jsonb),

    'total', (select count(*) from qvm_new_apps.upload_batches b
               where (p_template_key is null or b.template_key = p_template_key)
                 and (p_status is null or b.status = p_status)
                 and (p_search is null or b.file_name ilike '%' || p_search || '%'
                      or coalesce(b.source_label,'') ilike '%' || p_search || '%')
                 and (v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor))),

    -- Rows analysed and not yet saved, keyed by file type. Deliberately not filtered by
    -- p_template_key: the tab strip draws every type at once, and a map that only knows about
    -- the tab you are standing on is not a map.
    'pending_rows', coalesce((
      select jsonb_object_agg(p.template_key, p.n)
        from (select b.template_key, sum(b.rows_ready) as n
                from qvm_new_apps.upload_batches b
               where b.status = 'preview' and b.rows_ready > 0
                 and (v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor))
               group by b.template_key) p), '{}'::jsonb),

    'counters', (select jsonb_build_object(
        'files', count(*), 'accepted', coalesce(sum(rows_ready), 0),
        'rejected', coalesce(sum(rows_rejected), 0),
        'awaiting_rule', coalesce(sum(rows_disabled), 0),
        'held', coalesce(sum(rows_held), 0))
        from qvm_new_apps.upload_batches b
       where (p_template_key is null or b.template_key = p_template_key)
         and (p_status is null or b.status = p_status)
         and (p_search is null or b.file_name ilike '%' || p_search || '%'
              or coalesce(b.source_label,'') ilike '%' || p_search || '%')
         and (v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor))),

    'pending_deletes', (select count(*) from qvm_new_apps.upload_delete_requests r
                         join qvm_new_apps.upload_batches b on b.batch_id = r.batch_id
                        where r.status = 'pending'
                          and (v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor))),

    'vendors', case when v_team then coalesce((
        select jsonb_agg(jsonb_build_object('id', v.vendor_id, 'name', v.vendor_name)
               order by v.vendor_name)
          from qvm_new_apps.vendors v), '[]'::jsonb) else '[]'::jsonb end,

    'templates', coalesce((
      select jsonb_agg(jsonb_build_object(
               'template_key', t.template_key, 'label_ar', t.label_ar,
               'files', (select count(*) from qvm_new_apps.upload_batches b
                          where b.template_key = t.template_key
                            and (p_status is null or b.status = p_status)
                            and (p_search is null or b.file_name ilike '%' || p_search || '%'
                                 or coalesce(b.source_label,'') ilike '%' || p_search || '%')
                            and (v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor))))
             order by t.sort_order)
        from qvm_new_apps.upload_templates t
       where v_team or t.allowed_for_vendor), '[]'::jsonb)
  ));
end
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.upload_rows_across_files(p_template_key text DEFAULT NULL::text, p_state text DEFAULT NULL::text, p_search text DEFAULT NULL::text, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_team   boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_limit  integer := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_search text    := nullif(btrim(coalesce(p_search, '')), '');
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'row_id', r.row_id, 'row_number', r.row_number,
               'batch_id', r.batch_id, 'file_name', r.file_name,
               -- Which sites this file was uploaded against. 'all' is a real answer and is
               -- not the same as «nobody chose» — an empty list on a specific scope is.
               'branch_scope', r.branch_scope,
               'branches', r.branches,
               'source_part_number', r.source_part_number,
               'clean_part_number', r.clean_part_number,
               'display_part_number', r.display_part_number,
               'clean_name', r.clean_name, 'source_name', r.source_name,
               'state', r.state, 'reason', r.reason, 'raw', r.raw,
               -- The sheet's own headers and values. Null on rows staged before raw_source
               -- existed, which the screen has to treat as «no sheet columns», not as an error.
               'raw_source', r.raw_source)
             order by r.file_created_at desc, r.row_number)
        from (
          -- Named one by one rather than u.*: upload_rows carries its own created_at, and
          -- `u.*, b.created_at` would put two columns of that name in here — after which
          -- ordering by it is ambiguous and the function will not even compile.
          select u.row_id, u.row_number, u.batch_id, u.source_part_number,
                 u.clean_part_number, u.display_part_number,
                 u.clean_name, u.source_name, u.state, u.reason, u.raw, u.raw_source,
                 b.file_name, b.created_at as file_created_at,
                 b.branch_scope,
                 -- `client_branches` is keyed by customer_id, not list_data_id.
                 case when b.branch_kind = 'vendor'
                      then qvm_new_apps.upload_batch_branches_json(b.batch_id)
                      else (select coalesce(jsonb_agg(jsonb_build_object(
                                     'id', cb.customer_id, 'name', cb.branch_name)
                                   order by cb.branch_name), '[]'::jsonb)
                              from qvm_new_apps.client_branches cb
                             where cb.customer_id = any(coalesce(b.branch_ids, '{}'::integer[])))
                 end as branches
            from qvm_new_apps.upload_rows u
            join qvm_new_apps.upload_batches b on b.batch_id = u.batch_id
           where (p_template_key is null or b.template_key = p_template_key)
             and (p_state is null or u.state = p_state)
             and (v_search is null
                  or u.source_part_number ilike '%' || v_search || '%'
                  or coalesce(u.clean_part_number, '') ilike '%' || v_search || '%'
                  or coalesce(u.clean_name, '') ilike '%' || v_search || '%'
                  or b.file_name ilike '%' || v_search || '%')
             and (v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor))
           order by b.created_at desc, u.row_number
           limit v_limit offset greatest(coalesce(p_offset, 0), 0)
        ) r), '[]'::jsonb),

    'total', (
      select count(*)
        from qvm_new_apps.upload_rows u
        join qvm_new_apps.upload_batches b on b.batch_id = u.batch_id
       where (p_template_key is null or b.template_key = p_template_key)
         and (p_state is null or u.state = p_state)
         and (v_search is null
              or u.source_part_number ilike '%' || v_search || '%'
              or coalesce(u.clean_part_number, '') ilike '%' || v_search || '%'
              or coalesce(u.clean_name, '') ilike '%' || v_search || '%'
              or b.file_name ilike '%' || v_search || '%')
         and (v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor)))
  ));
end
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.uploaded_record_create(p_kind text, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_pn_raw text := nullif(btrim(coalesce(p_data->>'part_number','')), '');
  v_pn text;
  v_id bigint;
  v_vendor_id integer;
  v_branch integer;
  v_vb bigint;
  v_num numeric;
  v_clean jsonb;
  v_brand text; v_class text; v_country text;
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if v_pn_raw is null then
    return jsonb_build_object('status', false, 'message', 'رقم القطعة مطلوب', 'data', null);
  end if;

  -- The same cleaning an imported row goes through — code rules included. A number typed
  -- here and the same number arriving in tomorrow's file have to land on one row, not two.
  v_clean := qvm_new_apps.upload_clean_part_number(
               v_pn_raw, p_kind, 'vendor',
               case when v_team then nullif(p_data->>'vendor_id','')::bigint
                    else v_vendor::bigint end);
  v_pn := v_clean->>'clean_part_number';
  -- What the matched rule says about the part. It fills gaps and never argues with a value
  -- the person typed: they have the part in front of them, the rule is a generalisation.
  v_brand   := coalesce(v_brand, v_clean->>'brand');
  v_class   := coalesce(v_class, v_clean->>'part_class');
  v_country := coalesce(v_country, v_clean->>'country_of_origin');
  if v_pn is null then
    return jsonb_build_object('status', false,
      'message', 'رقم القطعة لا يحتوي على حروف أو أرقام', 'data', null);
  end if;

  -- A vendor adds under their own name and cannot type somebody else's.
  v_vendor_id := case when v_team then nullif(p_data->>'vendor_id','')::integer else v_vendor end;
  v_branch := nullif(p_data->>'client_branch_id','')::integer;

  -- An agency price, a stock line or a purchase is a vendor branch's. A vendor with one branch
  -- is not asked which; anyone else names it, and it has to be that vendor's.
  if p_kind in ('agency', 'stock', 'purchases') then
    if v_vendor_id is null then
      return jsonb_build_object('status', false, 'message', 'اختر المورّد', 'data', null);
    end if;
    v_vb := nullif(p_data->>'vendor_branch_id','')::bigint;
    if v_vb is null then
      select case when count(*) = 1 then min(vb.vendor_branch_id) end into v_vb
        from qvm_new_apps.vendor_branches vb
       where vb.vendor_id = v_vendor_id and coalesce(vb.is_active, true);
      if v_vb is null then
        return jsonb_build_object('status', false, 'message', 'اختر فرع المورّد', 'data', null);
      end if;
    elsif not exists (select 1 from qvm_new_apps.vendor_branches vb
                       where vb.vendor_branch_id = v_vb and vb.vendor_id = v_vendor_id) then
      return jsonb_build_object('status', false,
        'message', 'هذا الفرع لا يتبع المورّد المختار', 'data', null);
    end if;
  end if;

  if p_kind = 'catalog' then
    if not v_team then
      return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
    end if;
    insert into qvm_new_apps.parts_catalog
      (clean_part_number, clean_make, clean_part_class, clean_country_manufacture,
       clean_name_ar, clean_name_en, source)
    values (v_pn,
            coalesce(v_brand, 'UNKNOWN'),
            coalesce(v_class, 'commercial'),
            v_country,
            nullif(btrim(coalesce(p_data->>'name','')), ''),
            nullif(btrim(coalesce(p_data->>'name_en','')), ''),
            'manual')
    on conflict do nothing
    returning part_id into v_id;

  elsif p_kind = 'agency' then
    if not v_team then
      return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
    end if;
    v_num := nullif(btrim(coalesce(p_data->>'price','')), '')::numeric;
    if v_num is null then
      return jsonb_build_object('status', false, 'message', 'سعر الوكالة مطلوب', 'data', null);
    end if;
    insert into qvm_new_apps.agency_price_reference
      (source_part_number, clean_part_number, source_name, source_name_en, clean_name,
       brand, part_class, agency_price, dealer_agency_discount_pct,
       agency_price_after_discount, vendor_id, vendor_branch_id, source_label)
    values (v_pn_raw, v_pn,
            nullif(btrim(coalesce(p_data->>'name','')), ''),
            nullif(btrim(coalesce(p_data->>'name_en','')), ''),
            nullif(btrim(coalesce(p_data->>'name','')), ''),
            v_brand,
            v_class,
            v_num,
            nullif(btrim(coalesce(p_data->>'discount_pct','')), '')::numeric,
            nullif(btrim(coalesce(p_data->>'price_after_discount','')), '')::numeric,
            v_vendor_id, v_vb, 'manual')
    on conflict do nothing
    returning id into v_id;

  elsif p_kind = 'stock' then
    v_num := nullif(btrim(coalesce(p_data->>'wholesale_price','')), '')::numeric;
    if v_num is null then
      return jsonb_build_object('status', false, 'message', 'سعر الجملة مطلوب', 'data', null);
    end if;
    insert into qvm_new_apps.inventory_stock
      (source_part_number, clean_part_number, source_name, clean_name, clean_name_en,
       brand, part_class, country_of_origin, quantity, is_available,
       wholesale_price, retail_price, vendor_id, vendor_branch_id)
    values (v_pn_raw, v_pn,
            nullif(btrim(coalesce(p_data->>'name','')), ''),
            nullif(btrim(coalesce(p_data->>'name','')), ''),
            nullif(btrim(coalesce(p_data->>'name_en','')), ''),
            v_brand,
            v_class,
            v_country,
            nullif(btrim(coalesce(p_data->>'quantity','')), '')::integer,
            -- Same rule the edit path uses: availability follows the quantity, so a row
            -- entered as zero is not offered to a workshop that would never receive it.
            coalesce(nullif(btrim(coalesce(p_data->>'quantity','')), '')::integer, 0) > 0,
            v_num,
            nullif(btrim(coalesce(p_data->>'retail_price','')), '')::numeric,
            v_vendor_id, v_vb)
    on conflict do nothing
    returning id into v_id;

  elsif p_kind = 'purchases' then
    if not v_team then
      return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
    end if;
    insert into qvm_new_apps.part_purchase_history
      (source_part_number, clean_part_number, cost, cost_on, supplier_name,
       brand, brand_class, qty, retail_price, vendor_id, vendor_branch_id, origin)
    values (v_pn_raw, v_pn,
            nullif(btrim(coalesce(p_data->>'cost','')), '')::double precision,
            nullif(btrim(coalesce(p_data->>'cost_on','')), '')::date,
            coalesce(nullif(btrim(coalesce(p_data->>'supplier','')), ''),
                     (select v.vendor_name from qvm_new_apps.vendors v where v.vendor_id = v_vendor_id)),
            v_brand,
            v_class,
            nullif(btrim(coalesce(p_data->>'qty','')), '')::integer,
            nullif(btrim(coalesce(p_data->>'retail_price','')), '')::numeric,
            v_vendor_id, v_vb, 'manual_entry')
    returning id into v_id;

  elsif p_kind = 'aliases' then
    if not v_team then
      return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
    end if;
    if qvm_new_apps.normalize_part_number(coalesce(p_data->>'alias','')) is null then
      return jsonb_build_object('status', false, 'message', 'الرقم المكافئ مطلوب', 'data', null);
    end if;
    insert into qvm_new_apps.part_aliases
      (clean_part_number, clean_alias, source_part_number, source_alias, brand, note)
    values (v_pn, qvm_new_apps.normalize_part_number(p_data->>'alias'),
            v_pn_raw, btrim(p_data->>'alias'),
            v_brand,
            nullif(btrim(coalesce(p_data->>'note','')), ''))
    on conflict do nothing
    returning id into v_id;

  else
    return jsonb_build_object('status', false, 'message', 'unknown tab', 'data', null);
  end if;

  -- A row that is already there was not created, and saying «saved» would send somebody away
  -- believing a number is recorded that is not the one on screen.
  if v_id is null then
    return jsonb_build_object('status', false,
      'message', 'هذا الصنف موجود بالفعل في هذا الجدول — عدِّله من الصف نفسه', 'data', null);
  end if;

  insert into qvm_new_apps.upload_batch_log (action, detail, changed_by)
  values ('record_manual_create',
          jsonb_build_object('kind', p_kind, 'id', v_id, 'data', p_data), auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('id', v_id));
end
$function$;
