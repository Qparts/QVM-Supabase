-- A vendor invoice is a document with money, a due date and a state. It had none of the three.
--
-- purchase_invoice_attachments and vendor_creditnotes record that a file arrived and nothing else.
-- Everything the invoices screen shows — «معتمدة», «متأخرة», «تسوية جزئية», the totals, the ageing
-- — has to live somewhere, and it belongs on these two rows. An invoice is not a property of the
-- purchase order: an order can carry several, and a credit note against it is a document of its
-- own.
--
-- Columns on the two tables rather than a third «documents» table pointing at them. The union
-- happens once, in the read, where the screen needs it; a wrapper table would put a second id on
-- every fact and a second place for the two to disagree.
--
-- Deliberately absent: a status column. See 20260916280042 — «متأخرة» is a date having passed, and
-- a stored copy of that is wrong every midnight until something rewrites it.

alter table qvm_new_apps.purchase_invoice_attachments
  add column if not exists total_amount      numeric(14,2),
  add column if not exists settled_amount    numeric(14,2) not null default 0,
  add column if not exists issued_on         date,
  add column if not exists payment_term_days integer not null default 30,
  add column if not exists approved_at       timestamptz,
  add column if not exists approved_by       uuid,
  add column if not exists settled_at        timestamptz,
  add column if not exists cancelled_at      timestamptz,
  add column if not exists match_pct         numeric(5,2);

alter table qvm_new_apps.vendor_creditnotes
  add column if not exists total_amount   numeric(14,2),
  add column if not exists settled_amount numeric(14,2) not null default 0,
  add column if not exists issued_on      date,
  add column if not exists approved_at    timestamptz,
  add column if not exists approved_by    uuid,
  add column if not exists settled_at     timestamptz,
  add column if not exists cancelled_at   timestamptz;

-- ── The settlement request ─────────────────────────────────────────────────────────────────────
-- One transfer, one supplier, any number of their invoices and credit notes across any number of
-- branches. One supplier is a hard rule and not a convention: a bank transfer cannot be split
-- between two companies, so a request that mixed them could never be closed.
create table if not exists qvm_new_apps.vendor_settlements (
  settlement_id  bigint generated always as identity primary key,
  code           text unique not null,
  vendor_id      integer not null references qvm_new_apps.vendors(vendor_id),
  raised_by_side text not null default 'purchasing'
                 check (raised_by_side in ('purchasing', 'vendor')),
  status         text not null default 'pending'
                 check (status in ('pending', 'settled', 'cancelled')),
  -- Stored, not recomputed: it is what was agreed when the request was raised, and recomputing it
  -- later would silently restate a transfer that has already left the bank.
  net_amount     numeric(14,2) not null default 0,
  bank_account   text,
  transfer_ref   text,
  receipt_url    text,
  receipt_path   text,
  note           text,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  settled_at     timestamptz,
  settled_by     uuid,
  cancelled_at   timestamptz,
  cancelled_by   uuid
);

create table if not exists qvm_new_apps.vendor_settlement_items (
  item_id       bigint generated always as identity primary key,
  settlement_id bigint not null references qvm_new_apps.vendor_settlements(settlement_id) on delete cascade,
  doc_kind      text not null check (doc_kind in ('invoice', 'return')),
  doc_id        bigint not null,
  -- What this request claims for that document — for a partly settled invoice, the remainder.
  amount        numeric(14,2) not null,
  -- Per member, which is what lets one transfer close on some documents and release the others.
  member_status text not null default 'pending'
                 check (member_status in ('pending', 'settled', 'cancelled')),
  created_at    timestamptz not null default now()
);

-- A document belongs to at most one OPEN request. Two would mean two transfers about to pay it.
create unique index if not exists vendor_settlement_items_one_open
  on qvm_new_apps.vendor_settlement_items (doc_kind, doc_id)
  where member_status = 'pending';
create index if not exists vendor_settlement_items_by_settlement
  on qvm_new_apps.vendor_settlement_items (settlement_id);
create index if not exists vendor_settlements_by_vendor
  on qvm_new_apps.vendor_settlements (vendor_id, status);

-- ── Notes, and who may read them ───────────────────────────────────────────────────────────────
-- The design gives every note a visibility: «فريقي فقط» or «الطرفين». That is a permission and not
-- a label — an internal note about a supplier's invoice must not reach the supplier — so the
-- column exists to be enforced against in the read.
create table if not exists qvm_new_apps.vendor_document_notes (
  note_id        bigint generated always as identity primary key,
  doc_kind       text not null check (doc_kind in ('invoice', 'return', 'settlement')),
  doc_id         bigint not null,
  body           text not null,
  visibility     text not null default 'internal' check (visibility in ('internal', 'both')),
  author_side    text not null check (author_side in ('purchasing', 'vendor')),
  author_id      uuid,
  attachment_url text,
  created_at     timestamptz not null default now()
);
create index if not exists vendor_document_notes_by_doc
  on qvm_new_apps.vendor_document_notes (doc_kind, doc_id, created_at desc);

alter table qvm_new_apps.vendor_settlements      enable row level security;
alter table qvm_new_apps.vendor_settlement_items enable row level security;
alter table qvm_new_apps.vendor_document_notes   enable row level security;

grant select on qvm_new_apps.vendor_settlements, qvm_new_apps.vendor_settlement_items,
                qvm_new_apps.vendor_document_notes to authenticated;

-- ── What the documents already in the system are worth ─────────────────────────────────────────
-- A starting point, not a verdict: the value of the purchase lines the document covers, VAT
-- included. The supplier's claim is whatever their file says, and the gap between the two is the
-- reason a person reviews it. Only nulls are filled, so a corrected figure is never overwritten.
with po_value as (
  select pi.purchase_order_id,
         sum(coalesce(qvi.cost, 0) * greatest(coalesce(pi.approved_qty,0) - coalesce(pi.returned_qty,0), 0)) as net
    from qvm_new_apps.purchase_items pi
    join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = pi.confirmed_item_id
    left join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
    left join qvm_new_apps.quotation_vendor_items qvi on qvi.cost_id = qi.cost_id
   group by pi.purchase_order_id
)
update qvm_new_apps.purchase_invoice_attachments a
   set total_amount = round(coalesce(p.net, 0) * 1.15, 2),
       issued_on    = coalesce(a.issued_on, a.uploaded_at::date)
  from po_value p
 where p.purchase_order_id = a.purchase_order_id and a.total_amount is null;

with cn_value as (
  select vci.vendor_creditnote_id,
         sum(coalesce(qvi.cost, 0) * coalesce(vci.return_qty, 0)) as net
    from qvm_new_apps.vendor_creditnote_items vci
    join qvm_new_apps.purchase_items pi on pi.purchase_item_id = vci.purchase_item_id
    join qvm_new_apps.confirmed_items ci on ci.confirmed_item_id = pi.confirmed_item_id
    left join qvm_new_apps.quotation_items qi on qi.quotation_item_id = ci.quotation_item_id
    left join qvm_new_apps.quotation_vendor_items qvi on qvi.cost_id = qi.cost_id
   group by vci.vendor_creditnote_id
)
update qvm_new_apps.vendor_creditnotes cn
   set total_amount = round(coalesce(c.net, 0) * 1.15, 2),
       issued_on    = coalesce(cn.issued_on, cn.created_at::date)
  from cn_value c
 where c.vendor_creditnote_id = cn.vendor_creditnote_id and cn.total_amount is null;
