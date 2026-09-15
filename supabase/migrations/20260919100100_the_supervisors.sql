-- المشرفون: a company's approval ladder, and the requests that climb it.
--
-- A company admin says how many levels of supervisor the company has and who sits at each. A
-- pricing decision that needs signing off becomes a request against that ladder, and every level
-- has to approve it — except that approval from the TOP level settles it on its own, which is the
-- rule the team asked for: the most senior supervisor does not wait for the ones below.
--
-- Generic in the one place it is cheap to be: a request names a subject_type and a subject_id
-- rather than a quotation_id. The first subject is 'pricing', but the ladder is the company's, not
-- the pricing page's, and the next thing that needs signing off should not need a second table.

CREATE TABLE IF NOT EXISTS qvm_new_apps.approval_levels (
  approval_level_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id        integer NOT NULL,
  level_no          integer NOT NULL CHECK (level_no >= 1),
  user_id           uuid    NOT NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, level_no)
);

CREATE TABLE IF NOT EXISTS qvm_new_apps.approval_requests (
  approval_request_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id   integer NOT NULL,
  subject_type text    NOT NULL,
  subject_id   bigint  NOT NULL,
  reason       text,
  -- What was true when the request was raised: the price chosen, the price it beat, the gap. Kept
  -- as a snapshot because a supervisor approving tomorrow is approving what they were shown today,
  -- and the underlying figures move.
  payload      jsonb   NOT NULL DEFAULT '{}'::jsonb,
  status       text    NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  requested_by uuid,
  created_at   timestamptz NOT NULL DEFAULT now(),
  resolved_at  timestamptz
);

CREATE INDEX IF NOT EXISTS ix_approval_requests_subject
  ON qvm_new_apps.approval_requests (subject_type, subject_id);
CREATE INDEX IF NOT EXISTS ix_approval_requests_open
  ON qvm_new_apps.approval_requests (company_id, status);

CREATE TABLE IF NOT EXISTS qvm_new_apps.approval_decisions (
  approval_decision_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  approval_request_id  bigint NOT NULL
                         REFERENCES qvm_new_apps.approval_requests (approval_request_id) ON DELETE CASCADE,
  level_no             integer NOT NULL,
  user_id              uuid,
  decision             text    NOT NULL CHECK (decision IN ('approved', 'rejected')),
  note                 text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  -- One decision per level per request: a supervisor answers once, and a second answer from the
  -- same level would make "have all levels approved" unanswerable.
  UNIQUE (approval_request_id, level_no)
);

GRANT ALL ON qvm_new_apps.approval_levels, qvm_new_apps.approval_requests,
             qvm_new_apps.approval_decisions TO service_role;

-- ── Configuring the ladder ────────────────────────────────────────────────────────────────────
--
-- Replaces the whole ladder rather than editing it a rung at a time, because that is how the screen
-- works: the admin picks a number of levels and a person for each, and saves. Levels are
-- renumbered 1..n from the order given, so deleting the middle rung of three leaves 1 and 2 rather
-- than 1 and 3 — a gap would make "the top level" ambiguous.
CREATE OR REPLACE FUNCTION qvm_new_apps.set_company_approval_levels(p_company_id integer, p_levels jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.can_admin_company(p_company_id) THEN
    RAISE EXCEPTION 'Not allowed to set the approval levels for this company';
  END IF;

  DELETE FROM qvm_new_apps.approval_levels WHERE company_id = p_company_id;

  INSERT INTO qvm_new_apps.approval_levels (company_id, level_no, user_id)
  SELECT p_company_id, ord::integer, (x->>'user_id')::uuid
    FROM jsonb_array_elements(COALESCE(p_levels, '[]'::jsonb)) WITH ORDINALITY AS e(x, ord)
   WHERE COALESCE(btrim(x->>'user_id'), '') <> '';

  RETURN jsonb_build_object('status', 'success',
                            'levels', (SELECT count(*) FROM qvm_new_apps.approval_levels
                                        WHERE company_id = p_company_id));
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.list_company_approval_levels(p_company_id integer)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT CASE WHEN qvm_new_apps.can_admin_company(p_company_id) OR qvm_new_apps.is_qparts_team()
    THEN COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'level_no',  al.level_no,
               'user_id',   al.user_id,
               'user_name', ud.user_name,
               'user_email', ud.email) ORDER BY al.level_no)
        FROM qvm_new_apps.approval_levels al
        LEFT JOIN qvm_new_apps.user_data ud ON ud.user_id = al.user_id
       WHERE al.company_id = p_company_id), '[]'::jsonb)
    ELSE '[]'::jsonb END;
$function$;

-- ── Raising a request ─────────────────────────────────────────────────────────────────────────
--
-- Returns the existing open request when there is one rather than stacking a second: the pricing
-- page can call this every time the user tries to proceed, and two supervisors answering two
-- requests about the same decision is not an approval, it is a race.
CREATE OR REPLACE FUNCTION qvm_new_apps.create_approval_request(
  p_company_id integer, p_subject_type text, p_subject_id bigint,
  p_reason text DEFAULT NULL, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_id     bigint;
  v_levels integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

  SELECT count(*) INTO v_levels FROM qvm_new_apps.approval_levels WHERE company_id = p_company_id;
  IF v_levels = 0 THEN
    -- A company with no ladder has nobody to ask. Saying so beats creating a request that can never
    -- be answered and blocks the user forever.
    RETURN jsonb_build_object('status', 'no_levels',
                              'message', 'This company has no supervisors configured');
  END IF;

  SELECT ar.approval_request_id INTO v_id
    FROM qvm_new_apps.approval_requests ar
   WHERE ar.company_id = p_company_id
     AND ar.subject_type = p_subject_type
     AND ar.subject_id = p_subject_id
     AND ar.status = 'pending'
   ORDER BY ar.approval_request_id DESC
   LIMIT 1;

  IF v_id IS NULL THEN
    INSERT INTO qvm_new_apps.approval_requests
      (company_id, subject_type, subject_id, reason, payload, requested_by)
    VALUES (p_company_id, p_subject_type, p_subject_id, NULLIF(btrim(COALESCE(p_reason, '')), ''),
            COALESCE(p_payload, '{}'::jsonb), auth.uid())
    RETURNING approval_request_id INTO v_id;

    -- Every supervisor on the ladder is told, not only the first: the rule is that all of them
    -- answer, and the top one can settle it alone, so there is no "next in line" to notify.
    -- notification_reads is what puts a notification in someone's bell; the notifications row on
    -- its own is the message, not the delivery.
    WITH sent AS (
      INSERT INTO qvm_new_apps.notifications (title, body, data, target_type, target_user_id, created_by)
      SELECT 'طلب موافقة على تسعير',
             COALESCE(NULLIF(btrim(COALESCE(p_reason, '')), ''), 'بانتظار موافقتك'),
             jsonb_build_object('approval_request_id', v_id, 'subject_type', p_subject_type,
                                'subject_id', p_subject_id),
             'user', al.user_id, auth.uid()
        FROM qvm_new_apps.approval_levels al
       WHERE al.company_id = p_company_id
      RETURNING id, target_user_id
    )
    INSERT INTO qvm_new_apps.notification_reads (notification_id, user_id)
    SELECT sent.id, sent.target_user_id FROM sent WHERE sent.target_user_id IS NOT NULL;
  END IF;

  RETURN jsonb_build_object('status', 'success', 'approval_request_id', v_id, 'levels', v_levels);
END;
$function$;

-- ── Answering one ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION qvm_new_apps.decide_approval_request(
  p_approval_request_id bigint, p_decision text, p_note text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_company   integer;
  v_status    text;
  v_level     integer;
  v_top       integer;
  v_levels    integer;
  v_approved  integer;
  v_final     text;
BEGIN
  IF p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'A decision is either approved or rejected';
  END IF;

  SELECT ar.company_id, ar.status INTO v_company, v_status
    FROM qvm_new_apps.approval_requests ar
   WHERE ar.approval_request_id = p_approval_request_id;

  IF v_company IS NULL THEN RAISE EXCEPTION 'No such approval request'; END IF;
  IF v_status <> 'pending' THEN
    RETURN jsonb_build_object('status', 'already_resolved', 'request_status', v_status);
  END IF;

  SELECT al.level_no INTO v_level
    FROM qvm_new_apps.approval_levels al
   WHERE al.company_id = v_company AND al.user_id = auth.uid();

  IF v_level IS NULL THEN
    RAISE EXCEPTION 'You are not a supervisor for this company';
  END IF;

  INSERT INTO qvm_new_apps.approval_decisions (approval_request_id, level_no, user_id, decision, note)
  VALUES (p_approval_request_id, v_level, auth.uid(), p_decision,
          NULLIF(btrim(COALESCE(p_note, '')), ''))
  ON CONFLICT (approval_request_id, level_no) DO UPDATE
    SET decision = EXCLUDED.decision, note = EXCLUDED.note,
        user_id = EXCLUDED.user_id, created_at = now();

  SELECT max(level_no), count(*) INTO v_top, v_levels
    FROM qvm_new_apps.approval_levels WHERE company_id = v_company;

  SELECT count(*) INTO v_approved
    FROM qvm_new_apps.approval_decisions ad
   WHERE ad.approval_request_id = p_approval_request_id AND ad.decision = 'approved';

  v_final := CASE
    -- One rejection is enough: there is nothing for the rest of the ladder to add.
    WHEN p_decision = 'rejected' THEN 'rejected'
    -- The top supervisor settles it alone. Below the top, every level has to have said yes.
    WHEN v_level = v_top THEN 'approved'
    WHEN v_approved >= v_levels THEN 'approved'
    ELSE 'pending'
  END;

  IF v_final <> 'pending' THEN
    UPDATE qvm_new_apps.approval_requests
       SET status = v_final, resolved_at = now()
     WHERE approval_request_id = p_approval_request_id;

    WITH sent AS (
      INSERT INTO qvm_new_apps.notifications (title, body, data, target_type, target_user_id, created_by)
      SELECT CASE WHEN v_final = 'approved' THEN 'تمت الموافقة على التسعير' ELSE 'تم رفض التسعير' END,
             COALESCE(NULLIF(btrim(COALESCE(p_note, '')), ''), ''),
             jsonb_build_object('approval_request_id', p_approval_request_id, 'result', v_final),
             'user', ar.requested_by, auth.uid()
        FROM qvm_new_apps.approval_requests ar
       WHERE ar.approval_request_id = p_approval_request_id AND ar.requested_by IS NOT NULL
      RETURNING id, target_user_id
    )
    INSERT INTO qvm_new_apps.notification_reads (notification_id, user_id)
    SELECT sent.id, sent.target_user_id FROM sent WHERE sent.target_user_id IS NOT NULL;
  END IF;

  RETURN jsonb_build_object('status', 'success', 'my_level', v_level, 'top_level', v_top,
                            'approved_levels', v_approved, 'request_status', v_final);
END;
$function$;

-- ── Reading ───────────────────────────────────────────────────────────────────────────────────

-- What one subject's approval looks like right now — what the pricing page asks before it lets the
-- user proceed. Readable by anyone who can see the order; it says nothing a supervisor's name and a
-- yes/no does not.
CREATE OR REPLACE FUNCTION qvm_new_apps.get_approval_state(p_subject_type text, p_subject_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT COALESCE((
    SELECT jsonb_build_object(
             'approval_request_id', ar.approval_request_id,
             'status',   ar.status,
             'reason',   ar.reason,
             'payload',  ar.payload,
             'created_at', ar.created_at,
             'levels', COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                        'level_no',  al.level_no,
                        'user_id',   al.user_id,
                        'user_name', ud.user_name,
                        'decision',  ad.decision,
                        'note',      ad.note,
                        'decided_at', ad.created_at) ORDER BY al.level_no)
                 FROM qvm_new_apps.approval_levels al
                 LEFT JOIN qvm_new_apps.user_data ud ON ud.user_id = al.user_id
                 LEFT JOIN qvm_new_apps.approval_decisions ad
                        ON ad.approval_request_id = ar.approval_request_id
                       AND ad.level_no = al.level_no
                WHERE al.company_id = ar.company_id), '[]'::jsonb),
             'i_am_supervisor', EXISTS (
               SELECT 1 FROM qvm_new_apps.approval_levels al2
                WHERE al2.company_id = ar.company_id AND al2.user_id = auth.uid()))
      FROM qvm_new_apps.approval_requests ar
     WHERE ar.subject_type = p_subject_type AND ar.subject_id = p_subject_id
     ORDER BY ar.approval_request_id DESC
     LIMIT 1), jsonb_build_object('status', 'none'));
$function$;

-- The supervisor's own queue: open requests on a ladder they sit on, with their own answer (or the
-- absence of one) carried alongside.
CREATE OR REPLACE FUNCTION qvm_new_apps.list_my_approval_requests(p_status text DEFAULT 'pending')
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'approval_request_id', ar.approval_request_id,
             'company_id',   ar.company_id,
             'subject_type', ar.subject_type,
             'subject_id',   ar.subject_id,
             'reason',       ar.reason,
             'payload',      ar.payload,
             'status',       ar.status,
             'created_at',   ar.created_at,
             'my_level',     al.level_no,
             'my_decision',  ad.decision) ORDER BY ar.created_at DESC)
      FROM qvm_new_apps.approval_requests ar
      JOIN qvm_new_apps.approval_levels al
        ON al.company_id = ar.company_id AND al.user_id = auth.uid()
      LEFT JOIN qvm_new_apps.approval_decisions ad
             ON ad.approval_request_id = ar.approval_request_id AND ad.level_no = al.level_no
     WHERE p_status IS NULL OR p_status = '' OR ar.status = p_status), '[]'::jsonb);
$function$;

-- ── public wrappers ───────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.set_company_approval_levels(p_company_id integer, p_levels jsonb)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.set_company_approval_levels(p_company_id, p_levels); $$;

CREATE OR REPLACE FUNCTION public.list_company_approval_levels(p_company_id integer)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.list_company_approval_levels(p_company_id); $$;

CREATE OR REPLACE FUNCTION public.create_approval_request(p_company_id integer, p_subject_type text, p_subject_id bigint, p_reason text DEFAULT NULL, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.create_approval_request(p_company_id, p_subject_type, p_subject_id, p_reason, p_payload); $$;

CREATE OR REPLACE FUNCTION public.decide_approval_request(p_approval_request_id bigint, p_decision text, p_note text DEFAULT NULL)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.decide_approval_request(p_approval_request_id, p_decision, p_note); $$;

CREATE OR REPLACE FUNCTION public.get_approval_state(p_subject_type text, p_subject_id bigint)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.get_approval_state(p_subject_type, p_subject_id); $$;

CREATE OR REPLACE FUNCTION public.list_my_approval_requests(p_status text DEFAULT 'pending')
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.list_my_approval_requests(p_status); $$;

REVOKE ALL ON FUNCTION public.set_company_approval_levels(integer, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_company_approval_levels(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_approval_request(integer, text, bigint, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.decide_approval_request(bigint, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_approval_state(text, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_my_approval_requests(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.set_company_approval_levels(integer, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_company_approval_levels(integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_approval_request(integer, text, bigint, text, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.decide_approval_request(bigint, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_approval_state(text, bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_my_approval_requests(text) TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION qvm_new_apps.set_company_approval_levels(integer, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.list_company_approval_levels(integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.create_approval_request(integer, text, bigint, text, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.decide_approval_request(bigint, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.get_approval_state(text, bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.list_my_approval_requests(text) TO authenticated, service_role;
