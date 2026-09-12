-- A workshop carries a code, and a company links itself with it.
--
-- A workshop can exist with no company, and a workshop already serving one can take on another —
-- but until now the only way to connect the two was through the client tree, from the workshop's
-- side, by somebody who administers that workshop. A Company Admin looking at their own company had
-- no way to say "this workshop works for us too": they cannot see workshops that are not theirs,
-- and quite rightly.
--
-- The code closes that without opening the tree. The workshop gives it out; the company enters it;
-- the link is made. It is deliberately an invite code rather than a lookup key — random, not
-- sequential, and there is no way to search by it, so holding one is the whole of the permission.
-- That is the same shape as a joining link, and it carries the same consequence worth stating
-- plainly: whoever has the code can attach their own company to that workshop without the workshop
-- approving it. If that turns out to be too loose, the place to add approval is here, and nothing
-- above this line has to change.
--
-- Linking provisions the same things assigning a company does — the numbering sequence for every
-- branch, and a primary company for a workshop that had none — because a link that leaves the first
-- RFQ failing is not a link.

ALTER TABLE qvm_new_apps.client_workshops
  ADD COLUMN IF NOT EXISTS workshop_code text;

-- Ambiguous characters left out on purpose: this gets read off a screen and typed into another.
CREATE OR REPLACE FUNCTION qvm_new_apps.generate_workshop_code()
RETURNS text LANGUAGE plpgsql VOLATILE
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code text;
  v_try int := 0;
BEGIN
  LOOP
    v_code := 'WS-';
    FOR i IN 1..6 LOOP
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    END LOOP;
    EXIT WHEN NOT EXISTS (SELECT 1 FROM qvm_new_apps.client_workshops WHERE workshop_code = v_code);
    v_try := v_try + 1;
    IF v_try > 50 THEN
      RAISE EXCEPTION 'Could not find a free workshop code';
    END IF;
  END LOOP;
  RETURN v_code;
END $$;

UPDATE qvm_new_apps.client_workshops
   SET workshop_code = qvm_new_apps.generate_workshop_code()
 WHERE workshop_code IS NULL;

ALTER TABLE qvm_new_apps.client_workshops
  ALTER COLUMN workshop_code SET DEFAULT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_client_workshops_code
  ON qvm_new_apps.client_workshops (workshop_code) WHERE workshop_code IS NOT NULL;

-- A workshop created from anywhere gets one, so no screen has to remember to.
CREATE OR REPLACE FUNCTION qvm_new_apps.workshop_gets_a_code()
RETURNS trigger LANGUAGE plpgsql
SET search_path TO 'qvm_new_apps', 'public' AS $$
BEGIN
  IF NEW.workshop_code IS NULL THEN
    NEW.workshop_code := qvm_new_apps.generate_workshop_code();
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_workshop_gets_a_code ON qvm_new_apps.client_workshops;
CREATE TRIGGER trg_workshop_gets_a_code
  BEFORE INSERT ON qvm_new_apps.client_workshops
  FOR EACH ROW EXECUTE FUNCTION qvm_new_apps.workshop_gets_a_code();

------------------------------------------------------------------------------ linking

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_link_workshop_by_code(
  p_company_id integer,
  p_code       text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_code text := upper(btrim(COALESCE(p_code, '')));
  v_workshop bigint;
  v_name text;
  v_primary integer;
  r record;
BEGIN
  -- The company must be the caller's. The workshop must not be — that is the point.
  IF NOT qvm_new_apps.can_admin_company(p_company_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this company is not yours to administer');
  END IF;

  -- Typed with the prefix or without it; a code is read aloud as often as copied.
  IF v_code <> '' AND position('WS-' IN v_code) <> 1 THEN
    v_code := 'WS-' || v_code;
  END IF;

  SELECT w.workshop_id INTO v_workshop
  FROM qvm_new_apps.client_workshops w
  WHERE w.workshop_code = v_code;

  IF v_workshop IS NULL THEN
    -- Deliberately the same message whether the code is malformed or simply not in use: the
    -- difference would turn this into a way to test codes.
    RETURN jsonb_build_object('success', false, 'error', 'No workshop has that code');
  END IF;

  SELECT vw.name INTO v_name FROM qvm_new_apps.v_client_workshops vw WHERE vw.workshop_id = v_workshop;

  IF EXISTS (SELECT 1 FROM qvm_new_apps.workshop_companies
              WHERE workshop_id = v_workshop AND company_id = p_company_id) THEN
    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
      'workshop_id', v_workshop, 'workshop_name', v_name, 'already_linked', true));
  END IF;

  INSERT INTO qvm_new_apps.workshop_companies (workshop_id, company_id, created_by)
  VALUES (v_workshop, p_company_id, v_uid);

  -- A workshop that had no company gets this one as its primary, which is what client_branches and
  -- the dashboards that still group by branch follow. One that already had a primary keeps it:
  -- joining a workshop does not take it over.
  SELECT wc.company_id INTO v_primary
  FROM qvm_new_apps.workshop_companies wc
  WHERE wc.workshop_id = v_workshop AND wc.is_primary;

  IF v_primary IS NULL THEN
    v_primary := p_company_id;
    UPDATE qvm_new_apps.workshop_companies
       SET is_primary = true
     WHERE workshop_id = v_workshop AND company_id = p_company_id;
    UPDATE qvm_new_apps.client_workshops
       SET company_id = v_primary, updated_by = v_uid, updated_at = now()
     WHERE workshop_id = v_workshop;
    UPDATE qvm_new_apps.client_branches
       SET list_data_id = v_primary, updated_at = now()
     WHERE workshop_id = v_workshop;
  END IF;

  -- Every branch needs a numbering sequence for the company now served, or the first RFQ fails on
  -- a link that otherwise looked successful.
  FOR r IN SELECT customer_id FROM qvm_new_apps.client_branches WHERE workshop_id = v_workshop
  LOOP
    PERFORM qvm_new_apps.provision_branch_for_quotations(r.customer_id);
  END LOOP;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'workshop_id', v_workshop, 'workshop_name', v_name, 'already_linked', false));
END $$;

CREATE OR REPLACE FUNCTION public.admin_link_workshop_by_code(p_company_id integer, p_code text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.admin_link_workshop_by_code(p_company_id, p_code) $$;

REVOKE ALL ON FUNCTION public.admin_link_workshop_by_code(integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_link_workshop_by_code(integer, text) TO authenticated;
