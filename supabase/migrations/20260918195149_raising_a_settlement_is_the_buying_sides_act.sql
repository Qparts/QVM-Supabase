-- Raising a settlement request belongs to the buying side.
--
-- The function was written to let either side raise one — it even stamped `raised_by_side` from
-- whoever was asking. That followed the design, which shows the same button under both roles. It
-- is wrong: a supplier asking to be paid is a conversation, not a payment instruction, and the
-- request it created sat in the buying team's queue as though they had decided to pay it.
--
-- It also could not be completed from that side. Only purchasing may confirm a transfer, so a
-- request a vendor raised was a row nobody on the vendor's side could ever close.
--
-- The button is gone from the supplier's screen in the same change. This check is here because a
-- hidden button is not a rule — the RPC is reachable with or without one.
--
-- What a supplier keeps: seeing every request raised against them, its documents, its amounts, its
-- receipt and its notes. Nothing is hidden from them; they just do not start it.
do $do$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.vendor_settlement_create(jsonb)'::regprocedure);
  v_old text := '  if not v_team and v_vendor is null then
    return jsonb_build_object(''status'', false, ''message'', ''forbidden'', ''data'', null);
  end if;';
  v_new text := '  -- Not «are you signed in» — «are you the side that pays».
  if not v_team then
    return jsonb_build_object(''status'', false, ''data'', null,
      ''message'', ''إنشاء طلب التسوية من صلاحية المشتريات'');
  end if;';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'vendor_settlement_create: expected the caller check exactly once, found %', v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$do$;
