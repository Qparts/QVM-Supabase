-- A vendor may attach an invoice, to an order they actually won, and to no other.
--
-- add_purchase_invoice_attachment refused every non-internal caller outright, so the supplier side
-- of invoicing could not exist — which is why the column it writes has always accepted
-- uploaded_source = 'vendor' and nothing had ever written one.
--
-- Two changes, and the second matters more than the feature that prompted it.
--
-- 1 · A vendor is allowed if and only if they hold a line on this confirmed order. The order is
--     not taken on trust from the caller: the check is a join through quotation_vendor_items,
--     which is where «who won this» is actually recorded.
--
-- 2 · The permission is decided from auth.uid(), not from p_user_id. p_user_id arrives in the
--     request body — it is the caller telling the function who they are, and the function was
--     believing it. Anyone signed in could pass an internal user's id and be treated as internal.
--     p_user_id stays, because it is what the row records as the uploader, but it no longer
--     decides anything. Where there is no JWT at all — a service-role call from an edge function
--     — the old behaviour stands, because then there is no better identity to prefer.
--
-- And a vendor's upload is stamped 'vendor' whatever the caller asked for. A source field the
-- uploader can choose records nothing.
do $do$
declare
  v_def text := pg_get_functiondef(
    'public.add_purchase_invoice_attachment(uuid,integer,text,text,text,text,integer,text)'::regprocedure);
  v_old text := '  SELECT user_type INTO v_user_type FROM user_data WHERE user_id = p_user_id;
  v_is_internal := (v_user_type = 185);
  IF NOT v_is_internal THEN
    RETURN jsonb_build_object(''status'',''error'',''message'',''Access denied: Internal users only'');
  END IF;';
  v_new text := '  -- Who is asking is the JWT''''s answer, not the request body''''s. p_user_id is kept for
  -- attribution and no longer decides anything; with no JWT (service role) it is all there is.
  SELECT user_type INTO v_user_type FROM user_data WHERE user_id = COALESCE(auth.uid(), p_user_id);
  v_is_internal := (v_user_type = 185);

  IF NOT v_is_internal THEN
    -- A vendor, and only on an order they hold a line of.
    IF v_user_type = 205 AND EXISTS (
      SELECT 1
        FROM qvm_new_apps.confirmed_items ci
        JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
        JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = qi.cost_id
        JOIN qvm_new_apps.user_data ud ON ud.user_vendor = qvi.vendor_id
       WHERE ci.confirmed_order_id = p_confirmed_order_id
         AND ud.user_id = COALESCE(auth.uid(), p_user_id)
    ) THEN
      -- An uploader does not get to say what kind of uploader they were.
      p_uploaded_source := ''vendor'';
    ELSE
      RETURN jsonb_build_object(''status'',''error'',''message'',''Access denied'');
    END IF;
  END IF;';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'add_purchase_invoice_attachment: expected the access check exactly once, found %', v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$do$;
