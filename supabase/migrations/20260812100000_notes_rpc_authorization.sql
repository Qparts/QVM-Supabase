-- QNEW-101 prerequisite: close the notes-RPC authorization gap flagged in the ticket ("fetch_notes
-- and add_note currently have no role or entity-ownership check — any authenticated user can call
-- them with any type_id"). Live verification on QVM/dev turned up a wider gap than the ticket
-- describes:
--   - qvm_new_apps.add_note / qvm_new_apps.fetch_notes (and their public.* wrappers) are EXECUTE-
--     granted to `anon` — fully unauthenticated callers, not just "any authenticated user".
--   - public.create_quotation_note takes p_user_id as a raw untrusted parameter with no check it
--     matches the caller, and is also anon-executable — anyone could forge a note as any user.
--   - public.upsert_note_inline checks user_type=185 (internal-only) but has no ownership check on
--     type_id at all, and hard-rejects note_type NOT IN ('quotations','quotation_items') — meaning
--     Orders-dashboard notes (confirmed_items/confirmed_orders, called via OrderItemsTable.tsx/
--     OrdersListView.tsx) are already broken today independent of this fix.
--   - public.delete_note_inline regressed to zero auth check in 20260401151342_qpd416_... (an
--     earlier version had one) — any authenticated user can soft-delete any note by note_id.
--   - qvm_new_apps.notes has no RLS — all protection is expected to live in this RPC layer.
--
-- Frontend usage (hooks/useNotesController.ts and 8 consumers, plus NotesCell.tsx on the internal
-- dashboard) confirms: vendors never call any notes RPC today (no route in the vendor tree
-- references notes), while both internal staff (user_type=185) and client users (e.g. 183) call
-- these RPCs on all four note_types via /rfqs and /orders. Client users can currently set/read
-- is_internal=true ("Internal Only") notes through the same audience dropdown shown on those
-- client-facing pages — an existing bug this migration also closes.

-- Shared ownership check, reused by every notes RPC below — mirrors the existing
-- resolve_client_recipients/resolve_vendor_recipients/is_internal_user() pattern from
-- 20260809101000_notification_rules_dispatch.sql and 20260706141923_vendor_branches_and_roles_phase1.sql.
-- Internal staff (user_type=185) get unconditional access, matching upsert_note_inline's existing
-- precedent — this migration closes the client/vendor exposure, not internal-to-internal visibility.
-- Client users (183) are scoped via the same two-tier company-admin (role 170) vs single-branch
-- pattern already used in 20260405072037_qpd422_item_level_invoice_in_dashboard.sql. Everyone else
-- (vendors, unauthenticated) gets false — vendors have never used notes, so this is not a regression.
CREATE OR REPLACE FUNCTION qvm_new_apps.can_access_note_record(p_note_type text, p_type_id bigint)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_user_type integer;
  v_user_role integer;
  v_user_company integer;
  v_user_branch integer;
  v_customer_id integer;
BEGIN
  IF v_uid IS NULL THEN
    RETURN false;
  END IF;

  SELECT user_type, user_role, user_company, user_branch
  INTO v_user_type, v_user_role, v_user_company, v_user_branch
  FROM qvm_new_apps.user_data WHERE user_id = v_uid;

  IF v_user_type = 185 THEN
    RETURN true;
  END IF;

  IF v_user_type IS DISTINCT FROM 183 THEN
    RETURN false;
  END IF;

  CASE p_note_type
    WHEN 'quotation_items' THEN
      SELECT qi.customer_id INTO v_customer_id
      FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_item_id = p_type_id;
    WHEN 'quotations' THEN
      SELECT qi.customer_id INTO v_customer_id
      FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_id = p_type_id LIMIT 1;
    WHEN 'confirmed_items' THEN
      SELECT qi.customer_id INTO v_customer_id
      FROM qvm_new_apps.confirmed_items ci
      JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
      WHERE ci.confirmed_item_id = p_type_id;
    WHEN 'confirmed_orders' THEN
      SELECT qi.customer_id INTO v_customer_id
      FROM qvm_new_apps.confirmed_orders co
      JOIN qvm_new_apps.quotation_items qi ON qi.quotation_id = co.quotation_id
      WHERE co.confirmed_order_id = p_type_id LIMIT 1;
    ELSE
      RETURN false;
  END CASE;

  IF v_customer_id IS NULL THEN
    RETURN false;
  END IF;

  IF v_user_role = 170 THEN
    RETURN EXISTS (
      SELECT 1 FROM qvm_new_apps.client_branches cb
      WHERE cb.customer_id = v_customer_id AND cb.list_data_id = v_user_company
    );
  END IF;

  RETURN v_user_branch = v_customer_id;
END;
$function$;

REVOKE ALL ON FUNCTION qvm_new_apps.can_access_note_record(text, bigint) FROM public, anon, authenticated;

-- add_note: the real implementation lives in qvm_new_apps (public.add_note is a thin wrapper) —
-- add the access check and stop trusting p_is_internal=true from non-internal callers. user_id was
-- already correctly derived from auth.uid(), not client-supplied — that part was fine.
CREATE OR REPLACE FUNCTION qvm_new_apps.add_note(p_note_type text, p_type_id integer, p_is_internal boolean, p_note_description text, p_note_attachment text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
    v_note_id INTEGER;
    v_user_id UUID := auth.uid();
    v_is_internal boolean;
    result JSONB;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('status', false, 'message', 'Unauthorized: user_id is null', 'data', NULL);
    END IF;

    IF NOT qvm_new_apps.can_access_note_record(p_note_type, p_type_id) THEN
        RETURN jsonb_build_object('status', false, 'message', 'Access denied', 'data', NULL);
    END IF;

    v_is_internal := COALESCE(p_is_internal, false) AND qvm_new_apps.is_internal_user();

    INSERT INTO qvm_new_apps.notes (
        note_type, type_id, user_id, is_internal, note_description, note_attachment, created_at, updated_at
    )
    VALUES (
        p_note_type, p_type_id, v_user_id, v_is_internal, p_note_description, p_note_attachment, NOW(), NOW()
    )
    RETURNING note_id INTO v_note_id;

    SELECT jsonb_build_object(
        'status', true,
        'message', 'Note added successfully',
        'data', jsonb_build_object(
            'note_id', v_note_id, 'note_type', p_note_type, 'type_id', p_type_id,
            'user_id', v_user_id, 'is_internal', v_is_internal,
            'note_description', p_note_description, 'note_attachment', p_note_attachment
        )
    ) INTO result;

    RETURN result;
END;
$function$;

REVOKE ALL ON FUNCTION qvm_new_apps.add_note(text, integer, boolean, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION qvm_new_apps.add_note(text, integer, boolean, text, text) TO authenticated;
REVOKE ALL ON FUNCTION public.add_note(text, integer, boolean, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.add_note(text, integer, boolean, text, text) TO authenticated;

-- fetch_notes: public.fetch_notes is a thin wrapper calling this one (same-transaction nested
-- call), but qvm_new_apps.fetch_notes is ALSO independently anon-executable and directly reachable
-- via supabase.schema('qvm_new_apps').rpc(...), so the check has to live here, not just be relied
-- on via the wrapper. Returns an empty set (not an error) when access is denied, to avoid leaking
-- record existence through an error message. Non-internal callers never see is_internal=true rows,
-- regardless of what p_is_internal was requested — closes the client-can-read-internal-notes gap.
CREATE OR REPLACE FUNCTION qvm_new_apps.fetch_notes(p_note_type text, p_type_id bigint, p_is_internal boolean DEFAULT NULL::boolean)
 RETURNS TABLE(note_id bigint, note_description text, note_attachment text, created_at timestamp with time zone, user_name text, user_id uuid, is_internal boolean)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_effective_is_internal boolean;
BEGIN
  IF NOT qvm_new_apps.can_access_note_record(p_note_type, p_type_id) THEN
    RETURN;
  END IF;

  v_effective_is_internal := p_is_internal;
  IF NOT qvm_new_apps.is_internal_user() THEN
    v_effective_is_internal := false;
  END IF;

  RETURN QUERY
  SELECT n.note_id::bigint, n.note_description, n.note_attachment, n.created_at, u.user_name, n.user_id, n.is_internal
  FROM qvm_new_apps.notes n
  LEFT JOIN qvm_new_apps.user_data u ON u.user_id = n.user_id
  WHERE n.note_type = p_note_type
    AND n.type_id = p_type_id
    AND (v_effective_is_internal IS NULL OR n.is_internal = v_effective_is_internal)
    AND COALESCE(n.is_deleted, false) = false
  ORDER BY n.created_at DESC;
END;
$function$;

REVOKE ALL ON FUNCTION qvm_new_apps.fetch_notes(text, bigint, boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION qvm_new_apps.fetch_notes(text, bigint, boolean) TO authenticated;
REVOKE ALL ON FUNCTION public.fetch_notes(text, bigint, boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fetch_notes(text, bigint, boolean) TO authenticated;

-- upsert_note_inline: replace the blanket "internal users only" rejection with the shared
-- ownership check (internal callers still always pass), and widen note_type to the full set
-- actually used by the Orders dashboard (confirmed_items/confirmed_orders) — previously any note
-- attempt there hit 'Invalid note_type', a pre-existing bug independent of this fix.
CREATE OR REPLACE FUNCTION public.upsert_note_inline(
  p_note_type text,
  p_type_id integer,
  p_note_description text,
  p_note_id integer DEFAULT NULL,
  p_is_internal boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid uuid;
  v_is_internal boolean;
  v_new_note_id int;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF p_note_type NOT IN ('quotations', 'quotation_items', 'confirmed_items', 'confirmed_orders') THEN
    RAISE EXCEPTION 'Invalid note_type. Must be quotations, quotation_items, confirmed_items, or confirmed_orders';
  END IF;

  IF NOT qvm_new_apps.can_access_note_record(p_note_type, p_type_id) THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  IF p_note_description IS NULL OR trim(p_note_description) = '' THEN
    RAISE EXCEPTION 'Note description cannot be empty';
  END IF;

  v_is_internal := COALESCE(p_is_internal, false) AND qvm_new_apps.is_internal_user();

  IF p_note_id IS NOT NULL THEN
    UPDATE notes
    SET note_description = p_note_description, updated_at = now()
    WHERE note_id = p_note_id AND user_id = v_uid;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Note % not found or you do not have permission to edit it', p_note_id;
    END IF;

    RETURN jsonb_build_object('status', 'success', 'message', 'Note updated', 'note_id', p_note_id);
  ELSE
    INSERT INTO notes (note_type, type_id, note_description, user_id, is_internal, created_at)
    VALUES (p_note_type, p_type_id, p_note_description, v_uid, v_is_internal, now())
    RETURNING note_id INTO v_new_note_id;

    RETURN jsonb_build_object('status', 'success', 'message', 'Note created', 'note_id', v_new_note_id);
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.upsert_note_inline(text, integer, text, integer, boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.upsert_note_inline(text, integer, text, integer, boolean) TO authenticated;

-- delete_note_inline: restores (and strengthens) the check that was silently dropped when this
-- function was rewritten for soft-delete in 20260401151342_qpd416_... — that version had NO auth
-- check at all. Internal staff can delete any note; anyone else only their own, and only if they
-- still have access to the underlying record.
CREATE OR REPLACE FUNCTION public.delete_note_inline(
  p_note_id integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_note qvm_new_apps.notes;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT * INTO v_note FROM qvm_new_apps.notes WHERE note_id = p_note_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','error','message','Note not found','note_id', p_note_id);
  END IF;

  IF NOT (
    qvm_new_apps.is_internal_user()
    OR (v_note.user_id = v_uid AND qvm_new_apps.can_access_note_record(v_note.note_type, v_note.type_id))
  ) THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  UPDATE qvm_new_apps.notes
  SET is_deleted = true,
      deleted_at = now(),
      deleted_by = v_uid,
      is_internal = true
  WHERE note_id = p_note_id;

  RETURN jsonb_build_object('status','success','message','Note soft-deleted','note_id', p_note_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_note_inline(integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.delete_note_inline(integer) TO authenticated;

-- create_quotation_note: a third, separate note-writing path (used by RFQ creation, called from
-- qvm_new_apps.create_quotation_with_items) found to be anon-executable and trusting a raw,
-- caller-supplied p_user_id with no check it matches the caller at all — anyone could forge a note
-- as any user. Switched to always use auth.uid() (the internal create_quotation_with_items caller
-- already passes its own authenticated service_advisor id here, so this is behavior-preserving for
-- that path) and added the same ownership check as everything else above.
CREATE OR REPLACE FUNCTION public.create_quotation_note(p_type_id integer, p_note text, p_user_id uuid)
 RETURNS qvm_new_apps.notes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_note qvm_new_apps.notes;
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF NOT qvm_new_apps.can_access_note_record('quotations', p_type_id) THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  INSERT INTO qvm_new_apps.notes (
    type_id, note_type, note_description, user_id, created_at
  ) VALUES (
    p_type_id, 'quotations', p_note, v_uid, now()
  )
  RETURNING * INTO v_note;

  RETURN v_note;
END;
$function$;

REVOKE ALL ON FUNCTION public.create_quotation_note(integer, text, uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.create_quotation_note(integer, text, uuid) TO authenticated;
