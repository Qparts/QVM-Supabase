-- An organisation asks to be credited, and shows the transfer.
--
-- `wallet_topup` already says why this has to exist: «only the side that receives the money may
-- say it arrived — an owner topping up their own balance by typing a number is not a top-up, it
-- is a wish». That leaves the owner with no way to *start* the conversation, so today the money
-- moves at the bank and nothing moves here until somebody on the Qparts side happens to notice.
--
-- This is the missing half: the owner states an amount and attaches the proof, and Qparts decides.
-- Nothing touches a balance until that decision, and when it does it goes through `wallet_charge`
-- like every other riyal — the one door money enters by.
create table if not exists qvm_new_apps.wallet_topup_requests (
  request_id   bigserial primary key,
  wallet_id    bigint      not null references qvm_new_apps.wallets(wallet_id) on delete cascade,
  amount       numeric     not null,
  currency     text        not null default 'SAR',
  -- The bank's own reference for the transfer. Not required — some transfers do not carry one,
  -- and a field nobody can fill honestly becomes a field everybody fills with junk.
  reference    text,
  note         text,
  -- The proof. Required: a request to be credited with no evidence of a transfer is the «wish»
  -- the direct top-up was written to refuse, wearing a form.
  receipt_url  text        not null,
  receipt_path text,

  status       text        not null default 'pending',
  requested_by uuid,
  requested_at timestamptz not null default now(),

  decided_by   uuid,
  decided_at   timestamptz,
  -- Why it was refused. Enforced below, because «rejected» with no reason is an unanswerable
  -- message: the organisation cannot fix what it is not told.
  reason       text,

  -- What Qparts issues back on approval. Optional at the moment of approval — the money should
  -- not wait on the paperwork — and attachable afterwards.
  invoice_url    text,
  invoice_path   text,
  invoice_number text,

  -- The ledger entry this request became. Null until approved, and unique: two requests can never
  -- point at one credit, and this row is the evidence that the credit happened exactly once.
  entry_id     bigint references qvm_new_apps.wallet_entries(entry_id),

  constraint wallet_topup_requests_amount_ck  check (amount > 0),
  constraint wallet_topup_requests_status_ck  check (status in ('pending', 'approved', 'rejected')),
  -- The states, spelled out. A «rejected» row with no reason, or an «approved» one with no entry,
  -- are both records of something that did not properly happen.
  constraint wallet_topup_requests_reason_ck
    check (status <> 'rejected' or (reason is not null and btrim(reason) <> '')),
  constraint wallet_topup_requests_entry_ck
    check ((status = 'approved') = (entry_id is not null))
);

create unique index if not exists wallet_topup_requests_entry_uq
  on qvm_new_apps.wallet_topup_requests (entry_id) where entry_id is not null;
create index if not exists wallet_topup_requests_wallet_idx
  on qvm_new_apps.wallet_topup_requests (wallet_id, requested_at desc);
-- The admin's queue is «everything still waiting», so that is the index.
create index if not exists wallet_topup_requests_pending_idx
  on qvm_new_apps.wallet_topup_requests (requested_at) where status = 'pending';

alter table qvm_new_apps.wallet_topup_requests enable row level security;

comment on table qvm_new_apps.wallet_topup_requests is
  'An owner-side request to be credited, with the transfer receipt attached. Approving it is the '
  'only way an owner can cause a credit, and it still goes through wallet_charge.';
