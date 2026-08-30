-- QNEW-101: Decision-Required Notes with Tagged Recipients, Approve/Reject, Attachments.
-- Builds on the authorization fix in 20260812100000_notes_rpc_authorization.sql
-- (qvm_new_apps.can_access_note_record, is_internal_user).

ALTER TABLE qvm_new_apps.notes
  ADD COLUMN kind text NOT NULL DEFAULT 'comment' CHECK (kind IN ('comment', 'decision_required')),
  ADD COLUMN due_date date NULL,
  ADD COLUMN recipient_mode text NULL CHECK (recipient_mode IS NULL OR recipient_mode IN ('tagged', 'audience')),
  ADD COLUMN decision_cancelled_at timestamptz NULL,
  ADD COLUMN decision_cancelled_by uuid NULL;

-- One row per tagged recipient (pre-created at note creation time, status starts 'pending').
-- Audience-wide decisions (recipient_mode='audience') start with ZERO rows here — there's no fixed
-- list to enumerate without re-deriving the whole audience the way dispatch_notification_rules does,
-- so the first matching person to respond via respond_to_note_decision inserts their own row and
-- resolves it for everyone; a second response attempt is rejected as already-resolved.
CREATE TABLE qvm_new_apps.note_recipients (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  note_id integer NOT NULL REFERENCES qvm_new_apps.notes(note_id),
  user_id uuid NOT NULL REFERENCES qvm_new_apps.user_data(user_id),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  reason text NULL,
  responded_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (note_id, user_id)
);
CREATE INDEX idx_note_recipients_note_id ON qvm_new_apps.note_recipients (note_id);
CREATE INDEX idx_note_recipients_user_pending ON qvm_new_apps.note_recipients (user_id) WHERE status = 'pending';
-- No RLS, same convention as qvm_new_apps.notes itself — access control lives entirely in the RPC
-- layer via can_access_note_record, not table policies.

-- Resolves the "search @mention candidates" set for a given record — mirrors
-- can_access_note_record's exact ownership CASE/join logic (20260812100000_...sql) but returns a
-- SET of teammates instead of a boolean. Internal caller -> all internal staff (this schema has no
-- further internal sub-teaming, matches how internal access already works blanket everywhere else in
-- notes). Client company-admin (role 170) -> every client user under any branch of their own company.
-- Other client users -> only users sharing their exact branch. p_query filters by name/email for the
-- live-typing @ search; NULL/empty returns the full candidate set (also used by add_note to validate
-- tagged ids server-side).
CREATE FUNCTION qvm_new_apps.search_note_taggable_users(p_note_type text, p_type_id bigint, p_query text DEFAULT NULL)
 RETURNS TABLE(user_id uuid, user_name text, email text)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_caller_user_type integer;
  v_caller_user_role integer;
  v_caller_user_company integer;
  v_caller_user_branch integer;
  v_customer_id integer;
  v_record_company_id integer;
BEGIN
  IF v_uid IS NULL THEN RETURN; END IF;
  IF NOT qvm_new_apps.can_access_note_record(p_note_type, p_type_id) THEN RETURN; END IF;

  SELECT ud.user_type, ud.user_role, ud.user_company, ud.user_branch
  INTO v_caller_user_type, v_caller_user_role, v_caller_user_company, v_caller_user_branch
  FROM qvm_new_apps.user_data ud WHERE ud.user_id = v_uid;

  -- Resolve the record's own owning customer_id/company once, up front — needed both for the
  -- client-caller branch (unchanged) and now also for the internal-caller branch, so internal staff
  -- can tag the specific client company tied to THIS record, not client users in general.
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
      v_customer_id := NULL;
  END CASE;

  IF v_customer_id IS NOT NULL THEN
    SELECT cb.list_data_id INTO v_record_company_id
    FROM qvm_new_apps.client_branches cb WHERE cb.customer_id = v_customer_id;
  END IF;

  IF v_caller_user_type = 185 THEN
    RETURN QUERY
    SELECT u.user_id, u.user_name, u.email
    FROM qvm_new_apps.user_data u
    WHERE u.user_id <> v_uid
      AND (
        u.user_type = 185
        OR (
          u.user_type = 183 AND v_record_company_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM qvm_new_apps.client_branches cb
            WHERE cb.customer_id = u.user_branch AND cb.list_data_id = v_record_company_id
          )
        )
      )
      AND (p_query IS NULL OR btrim(p_query) = '' OR u.user_name ILIKE '%' || p_query || '%' OR u.email ILIKE '%' || p_query || '%')
    ORDER BY u.user_name;
    RETURN;
  END IF;

  IF v_caller_user_type IS DISTINCT FROM 183 THEN RETURN; END IF;
  IF v_customer_id IS NULL THEN RETURN; END IF;

  IF v_caller_user_role = 170 THEN
    RETURN QUERY
    SELECT u.user_id, u.user_name, u.email
    FROM qvm_new_apps.user_data u
    WHERE u.user_type = 183 AND u.user_id <> v_uid
      AND EXISTS (
        SELECT 1 FROM qvm_new_apps.client_branches cb
        WHERE cb.list_data_id = v_caller_user_company AND cb.customer_id = u.user_branch
      )
      AND (p_query IS NULL OR btrim(p_query) = '' OR u.user_name ILIKE '%' || p_query || '%' OR u.email ILIKE '%' || p_query || '%')
    ORDER BY u.user_name;
  ELSE
    RETURN QUERY
    SELECT u.user_id, u.user_name, u.email
    FROM qvm_new_apps.user_data u
    WHERE u.user_type = 183 AND u.user_id <> v_uid AND u.user_branch = v_caller_user_branch
      AND (p_query IS NULL OR btrim(p_query) = '' OR u.user_name ILIKE '%' || p_query || '%' OR u.email ILIKE '%' || p_query || '%')
    ORDER BY u.user_name;
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION qvm_new_apps.search_note_taggable_users(text, bigint, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION qvm_new_apps.search_note_taggable_users(text, bigint, text) TO authenticated;

-- supabase.rpc() with no .schema() call (the convention this frontend uses for every notes RPC)
-- hits the `public` schema by default — needs its own thin wrapper here, same as add_note/fetch_notes.
CREATE FUNCTION public.search_note_taggable_users(p_note_type text, p_type_id bigint, p_query text DEFAULT NULL)
 RETURNS TABLE(user_id uuid, user_name text, email text)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'qvm_new_apps'
AS $function$
  select * from qvm_new_apps.search_note_taggable_users(p_note_type, p_type_id, p_query);
$function$;

REVOKE ALL ON FUNCTION public.search_note_taggable_users(text, bigint, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.search_note_taggable_users(text, bigint, text) TO authenticated;

-- Internal helper: resolve the order-level quotations.quotation_id backing a note_type+type_id pair
-- — activity_log.record_id is documented (20260810100000_activity_log.sql) as "quotations.quotation_id
-- for 'order'", and the existing RFQs/Orders mark-viewed logic keys off that same quotation_id, so
-- note-decision activity must resolve to it too, not just reuse the note's own type_id.
CREATE FUNCTION qvm_new_apps.note_record_quotation_id(p_note_type text, p_type_id integer)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_quotation_id integer;
BEGIN
  CASE p_note_type
    WHEN 'quotation_items' THEN
      SELECT qi.quotation_id INTO v_quotation_id
      FROM qvm_new_apps.quotation_items qi WHERE qi.quotation_item_id = p_type_id;
    WHEN 'quotations' THEN
      v_quotation_id := p_type_id;
    WHEN 'confirmed_items' THEN
      SELECT co.quotation_id INTO v_quotation_id
      FROM qvm_new_apps.confirmed_items ci
      JOIN qvm_new_apps.confirmed_orders co ON co.confirmed_order_id = ci.confirmed_order_id
      WHERE ci.confirmed_item_id = p_type_id;
    WHEN 'confirmed_orders' THEN
      SELECT co.quotation_id INTO v_quotation_id
      FROM qvm_new_apps.confirmed_orders co WHERE co.confirmed_order_id = p_type_id;
    ELSE
      v_quotation_id := NULL;
  END CASE;
  RETURN v_quotation_id;
END;
$function$;

REVOKE ALL ON FUNCTION qvm_new_apps.note_record_quotation_id(text, integer) FROM public, anon, authenticated;

-- Internal helper: one activity_log row (feeding the existing QNEW-100 RFQs/Orders sidebar badges)
-- plus one push, for a single recipient. Used both when tagging (action='decision_requested') and
-- when a tagged/audience recipient responds (action='decision_responded', notifying the note's
-- creator back). nav_target/order_number match the click-to-entity routing convention from
-- 20260810140000_notification_click_routing.sql.
CREATE FUNCTION qvm_new_apps.notify_note_recipient(
  p_note_id integer, p_recipient_user_id uuid, p_note_type text, p_type_id integer,
  p_action text, p_summary text
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_quotation_id integer;
  v_order_number text;
  v_nav_target text;
BEGIN
  v_quotation_id := qvm_new_apps.note_record_quotation_id(p_note_type, p_type_id);
  v_nav_target := CASE WHEN p_note_type IN ('confirmed_items', 'confirmed_orders') THEN 'orders' ELSE 'rfqs' END;

  IF v_quotation_id IS NOT NULL THEN
    SELECT order_number INTO v_order_number FROM qvm_new_apps.quotations WHERE quotation_id = v_quotation_id;

    INSERT INTO qvm_new_apps.activity_log (
      record_type, record_id, quotation_item_id, source_table, owner_user_id, action, actor_user_id, summary, new_values
    ) VALUES (
      'order', v_quotation_id,
      CASE WHEN p_note_type = 'quotation_items' THEN p_type_id ELSE NULL END,
      p_note_type, p_recipient_user_id, p_action, auth.uid(), p_summary,
      jsonb_build_object('note_id', p_note_id)
    );
  END IF;

  PERFORM qvm_new_apps.dispatch_push_to_user(
    p_recipient_user_id, 'QVM', p_summary,
    jsonb_build_object('note_id', p_note_id, 'quotation_id', v_quotation_id, 'nav_target', v_nav_target, 'order_number', v_order_number)
  );
END;
$function$;

REVOKE ALL ON FUNCTION qvm_new_apps.notify_note_recipient(integer, uuid, text, integer, text, text) FROM public, anon, authenticated;

-- get_unseen_activity_summary's source_table bucketing (20260810100500_activity_log_rpcs.sql)
-- never covered 'quotations'/'confirmed_orders' — no note_type used either of those values before
-- this migration, but decision-required notes on those two types now will, so activity on them must
-- actually count toward the RFQs/Orders sidebar badges rather than silently vanishing from both.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_unseen_activity_summary()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT jsonb_build_object(
    'rfqs', COALESCE(sum(CASE WHEN a.source_table IN ('quotation_items', 'quotation_vendor_items', 'quotation_vendors', 'quotations') THEN 1 ELSE 0 END), 0),
    'orders', COALESCE(sum(CASE WHEN a.source_table IN ('confirmed_items', 'confirmed_orders') THEN 1 ELSE 0 END), 0)
  )
  FROM qvm_new_apps.activity_log a
  WHERE a.owner_user_id = auth.uid()
    AND a.actor_user_id IS DISTINCT FROM auth.uid()
    AND a.created_at > COALESCE(
      (SELECT rv.last_viewed_at FROM qvm_new_apps.record_views rv
       WHERE rv.user_id = auth.uid() AND rv.record_type = a.record_type AND rv.record_id = a.record_id),
      '-infinity'::timestamptz
    );
$function$;

-- add_note: extend with kind/due_date/recipient_mode/tagged_user_ids. Tagged mode validates every id
-- server-side against search_note_taggable_users (can't tag someone who couldn't otherwise see this
-- record) and rejects an empty tag list (ticket item 2c). Signature is changing (new trailing params),
-- so drop the old 5-arg version first rather than risk PostgREST overload ambiguity between two
-- callable signatures with all-named arguments (same reasoning as dispatch_notification_rules earlier
-- this session).
DROP FUNCTION IF EXISTS qvm_new_apps.add_note(text, integer, boolean, text, text);
DROP FUNCTION IF EXISTS public.add_note(text, integer, boolean, text, text);

CREATE FUNCTION qvm_new_apps.add_note(
  p_note_type text, p_type_id integer, p_is_internal boolean, p_note_description text,
  p_note_attachment text DEFAULT NULL::text,
  p_kind text DEFAULT 'comment',
  p_due_date date DEFAULT NULL,
  p_recipient_mode text DEFAULT NULL,
  p_tagged_user_ids uuid[] DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
    v_note_id INTEGER;
    v_user_id UUID := auth.uid();
    v_is_internal boolean;
    v_recipient_mode text;
    v_tagged_uid uuid;
    v_order_number text;
    result JSONB;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('status', false, 'message', 'Unauthorized: user_id is null', 'data', NULL);
    END IF;

    IF NOT qvm_new_apps.can_access_note_record(p_note_type, p_type_id) THEN
        RETURN jsonb_build_object('status', false, 'message', 'Access denied', 'data', NULL);
    END IF;

    IF p_kind NOT IN ('comment', 'decision_required') THEN
        RETURN jsonb_build_object('status', false, 'message', 'Invalid note kind', 'data', NULL);
    END IF;

    v_is_internal := COALESCE(p_is_internal, false) AND qvm_new_apps.is_internal_user();
    v_recipient_mode := NULL;

    IF p_kind = 'decision_required' THEN
      IF p_recipient_mode = 'tagged' THEN
        IF p_tagged_user_ids IS NULL OR array_length(p_tagged_user_ids, 1) IS NULL THEN
          RETURN jsonb_build_object('status', false, 'message', 'At least one recipient must be tagged', 'data', NULL);
        END IF;
        IF EXISTS (
          SELECT 1 FROM unnest(p_tagged_user_ids) AS tag(uid)
          WHERE NOT EXISTS (
            SELECT 1 FROM qvm_new_apps.search_note_taggable_users(p_note_type, p_type_id, NULL) t WHERE t.user_id = tag.uid
          )
        ) THEN
          RETURN jsonb_build_object('status', false, 'message', 'One or more tagged users are not valid recipients for this record', 'data', NULL);
        END IF;
        v_recipient_mode := 'tagged';
      ELSIF p_recipient_mode = 'audience' OR p_recipient_mode IS NULL THEN
        v_recipient_mode := 'audience';
      ELSE
        RETURN jsonb_build_object('status', false, 'message', 'Invalid recipient mode', 'data', NULL);
      END IF;
    END IF;

    INSERT INTO qvm_new_apps.notes (
        note_type, type_id, user_id, is_internal, note_description, note_attachment, created_at, updated_at,
        kind, due_date, recipient_mode
    )
    VALUES (
        p_note_type, p_type_id, v_user_id, v_is_internal, p_note_description, p_note_attachment, NOW(), NOW(),
        p_kind, p_due_date, v_recipient_mode
    )
    RETURNING note_id INTO v_note_id;

    IF p_kind = 'decision_required' AND v_recipient_mode = 'tagged' THEN
      SELECT order_number INTO v_order_number
      FROM qvm_new_apps.quotations WHERE quotation_id = qvm_new_apps.note_record_quotation_id(p_note_type, p_type_id);

      FOREACH v_tagged_uid IN ARRAY p_tagged_user_ids
      LOOP
        INSERT INTO qvm_new_apps.note_recipients (note_id, user_id, status)
        VALUES (v_note_id, v_tagged_uid, 'pending')
        ON CONFLICT (note_id, user_id) DO NOTHING;

        PERFORM qvm_new_apps.notify_note_recipient(
          v_note_id, v_tagged_uid, p_note_type, p_type_id, 'decision_requested',
          'You were tagged for a decision on order #' || COALESCE(v_order_number, p_type_id::text)
        );
      END LOOP;
    END IF;

    SELECT jsonb_build_object(
        'status', true,
        'message', 'Note added successfully',
        'data', jsonb_build_object(
            'note_id', v_note_id, 'note_type', p_note_type, 'type_id', p_type_id,
            'user_id', v_user_id, 'is_internal', v_is_internal,
            'note_description', p_note_description, 'note_attachment', p_note_attachment,
            'kind', p_kind, 'due_date', p_due_date, 'recipient_mode', v_recipient_mode
        )
    ) INTO result;

    RETURN result;
END;
$function$;

REVOKE ALL ON FUNCTION qvm_new_apps.add_note(text, integer, boolean, text, text, text, date, text, uuid[]) FROM public, anon;
GRANT EXECUTE ON FUNCTION qvm_new_apps.add_note(text, integer, boolean, text, text, text, date, text, uuid[]) TO authenticated;

CREATE FUNCTION public.add_note(
  p_note_type text, p_type_id integer, p_is_internal boolean, p_note_description text,
  p_note_attachment text DEFAULT NULL::text,
  p_kind text DEFAULT 'comment',
  p_due_date date DEFAULT NULL,
  p_recipient_mode text DEFAULT NULL,
  p_tagged_user_ids uuid[] DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN qvm_new_apps.add_note(p_note_type, p_type_id, p_is_internal, p_note_description, p_note_attachment, p_kind, p_due_date, p_recipient_mode, p_tagged_user_ids);
END;
$function$;

REVOKE ALL ON FUNCTION public.add_note(text, integer, boolean, text, text, text, date, text, uuid[]) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.add_note(text, integer, boolean, text, text, text, date, text, uuid[]) TO authenticated;

-- Tagged mode: caller must own a pending row for this note. Audience mode: caller must currently
-- have access to the record and match its is_internal audience, and no response may already exist
-- (first responder resolves it for everyone — see the note_recipients comment above). Either way,
-- notifies the note's creator back on success.
CREATE FUNCTION qvm_new_apps.respond_to_note_decision(p_note_id integer, p_status text, p_reason text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_note qvm_new_apps.notes;
  v_responder_name text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;
  IF p_status NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Invalid status';
  END IF;

  SELECT * INTO v_note FROM qvm_new_apps.notes WHERE note_id = p_note_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Note not found';
  END IF;
  IF v_note.kind IS DISTINCT FROM 'decision_required' THEN
    RAISE EXCEPTION 'Note is not a decision request';
  END IF;
  IF v_note.decision_cancelled_at IS NOT NULL THEN
    RAISE EXCEPTION 'This decision request was cancelled';
  END IF;

  IF v_note.recipient_mode = 'tagged' THEN
    UPDATE qvm_new_apps.note_recipients
    SET status = p_status, reason = p_reason, responded_at = now()
    WHERE note_id = p_note_id AND user_id = v_uid AND status = 'pending';

    IF NOT FOUND THEN
      RAISE EXCEPTION 'You are not a pending recipient of this decision request';
    END IF;
  ELSE
    IF EXISTS (SELECT 1 FROM qvm_new_apps.note_recipients WHERE note_id = p_note_id) THEN
      RAISE EXCEPTION 'This decision request has already been resolved';
    END IF;
    IF NOT qvm_new_apps.can_access_note_record(v_note.note_type, v_note.type_id) THEN
      RAISE EXCEPTION 'Access denied';
    END IF;
    IF v_note.is_internal AND NOT qvm_new_apps.is_internal_user() THEN
      RAISE EXCEPTION 'Access denied';
    END IF;

    INSERT INTO qvm_new_apps.note_recipients (note_id, user_id, status, reason, responded_at)
    VALUES (p_note_id, v_uid, p_status, p_reason, now());
  END IF;

  SELECT user_name INTO v_responder_name FROM qvm_new_apps.user_data WHERE user_id = v_uid;

  PERFORM qvm_new_apps.notify_note_recipient(
    p_note_id, v_note.user_id, v_note.note_type, v_note.type_id, 'decision_responded',
    COALESCE(v_responder_name, 'Someone') || ' ' || p_status || ' your request'
  );

  RETURN jsonb_build_object('status', 'success', 'message', 'Decision recorded', 'note_id', p_note_id, 'decision_status', p_status);
END;
$function$;

REVOKE ALL ON FUNCTION qvm_new_apps.respond_to_note_decision(integer, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION qvm_new_apps.respond_to_note_decision(integer, text, text) TO authenticated;

CREATE FUNCTION public.respond_to_note_decision(p_note_id integer, p_status text, p_reason text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'qvm_new_apps'
AS $function$
BEGIN
  RETURN qvm_new_apps.respond_to_note_decision(p_note_id, p_status, p_reason);
END;
$function$;

REVOKE ALL ON FUNCTION public.respond_to_note_decision(integer, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.respond_to_note_decision(integer, text, text) TO authenticated;

-- Only the note's own creator, only while nothing has been resolved yet.
CREATE FUNCTION qvm_new_apps.cancel_note_decision(p_note_id integer)
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
    RAISE EXCEPTION 'Note not found';
  END IF;
  IF v_note.user_id IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'Only the creator can cancel this request';
  END IF;
  IF v_note.kind IS DISTINCT FROM 'decision_required' THEN
    RAISE EXCEPTION 'Note is not a decision request';
  END IF;
  IF v_note.decision_cancelled_at IS NOT NULL THEN
    RAISE EXCEPTION 'Already cancelled';
  END IF;
  IF EXISTS (SELECT 1 FROM qvm_new_apps.note_recipients WHERE note_id = p_note_id AND status <> 'pending') THEN
    RAISE EXCEPTION 'This decision request has already been resolved and cannot be cancelled';
  END IF;

  UPDATE qvm_new_apps.notes SET decision_cancelled_at = now(), decision_cancelled_by = v_uid WHERE note_id = p_note_id;

  RETURN jsonb_build_object('status', 'success', 'message', 'Decision request cancelled', 'note_id', p_note_id);
END;
$function$;

REVOKE ALL ON FUNCTION qvm_new_apps.cancel_note_decision(integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION qvm_new_apps.cancel_note_decision(integer) TO authenticated;

CREATE FUNCTION public.cancel_note_decision(p_note_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'qvm_new_apps'
AS $function$
BEGIN
  RETURN qvm_new_apps.cancel_note_decision(p_note_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.cancel_note_decision(integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.cancel_note_decision(integer) TO authenticated;

-- fetch_notes: add kind/due_date/decision_cancelled_at/recipients. This changes the return type
-- (added columns), which CREATE OR REPLACE cannot do even with identical parameters — drop first.
DROP FUNCTION IF EXISTS qvm_new_apps.fetch_notes(text, bigint, boolean);
DROP FUNCTION IF EXISTS public.fetch_notes(text, bigint, boolean);

CREATE FUNCTION qvm_new_apps.fetch_notes(p_note_type text, p_type_id bigint, p_is_internal boolean DEFAULT NULL::boolean)
 RETURNS TABLE(
   note_id bigint, note_description text, note_attachment text, created_at timestamp with time zone,
   user_name text, user_id uuid, is_internal boolean,
   kind text, due_date date, decision_cancelled_at timestamp with time zone, recipients jsonb
 )
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
  SELECT
    n.note_id::bigint, n.note_description, n.note_attachment, n.created_at, u.user_name, n.user_id, n.is_internal,
    n.kind, n.due_date, n.decision_cancelled_at,
    COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'user_id', nr.user_id, 'user_name', ru.user_name, 'status', nr.status,
        'reason', nr.reason, 'responded_at', nr.responded_at
      ) ORDER BY nr.created_at)
      FROM qvm_new_apps.note_recipients nr
      LEFT JOIN qvm_new_apps.user_data ru ON ru.user_id = nr.user_id
      WHERE nr.note_id = n.note_id
    ), '[]'::jsonb) AS recipients
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

CREATE FUNCTION public.fetch_notes(p_note_type text, p_type_id bigint, p_is_internal boolean DEFAULT NULL::boolean)
 RETURNS TABLE(
   note_id bigint, note_description text, note_attachment text, created_at timestamp with time zone,
   user_name text, user_id uuid, is_internal boolean,
   kind text, due_date date, decision_cancelled_at timestamp with time zone, recipients jsonb
 )
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'qvm_new_apps'
AS $function$
  select * from qvm_new_apps.fetch_notes(p_note_type, p_type_id, p_is_internal);
$function$;

REVOKE ALL ON FUNCTION public.fetch_notes(text, bigint, boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fetch_notes(text, bigint, boolean) TO authenticated;
