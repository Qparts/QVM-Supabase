-- A settlement says what it comes to.
--
-- The panel lists its documents with an amount each and an «المتبقي» each, and then stops. The
-- one number the person approving a transfer actually needs — what the whole request is worth —
-- was nowhere, so it had to be added up by eye from rows that each carry two figures.
--
-- Computed from the member rows the panel is already showing, not from a separate query, so the
-- total and the list can never disagree about which documents are in it. Four numbers rather
-- than one, because «SAR 4,025» hides the difference between what was claimed, what a credit
-- note took off, what has already been paid and what is still owed — and that difference is the
-- whole reason somebody opens this panel.
--
-- NOTE: the field names below are wrong — a member carries its money on a nested `document`, not
-- on the member itself, so this version returns zero for every settlement. Fixed four minutes
-- later in 20260924133021. Kept because it is what the database ran.
do $do$
declare
  v_def  text := pg_get_functiondef('qvm_new_apps.vendor_settlement_detail(bigint)'::regprocedure);
  v_old  text := '    ''header'', v_head, ''members'', v_members, ''bank_accounts'', v_banks,';
  v_new  text := '    ''header'', v_head, ''members'', v_members, ''bank_accounts'', v_banks,
    -- Summed over the members above, so the figure is of exactly the rows on screen.
    -- A cancelled member is excluded on both sides: it is not claimed and not owed.
    ''totals'', (
      select jsonb_build_object(
        ''documents'', count(*),
        ''gross'',     coalesce(sum((m->>''amount'')::numeric), 0),
        ''settled'',   coalesce(sum((m->>''settled_amount'')::numeric), 0),
        ''remaining'', coalesce(sum((m->>''remaining'')::numeric), 0))
      from jsonb_array_elements(coalesce(v_members, ''[]''::jsonb)) m
      where coalesce(m->>''member_status'', '''') <> ''cancelled''),';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'vendor_settlement_detail: expected the header line once, found %', v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$do$;
