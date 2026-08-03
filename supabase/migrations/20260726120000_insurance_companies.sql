-- QNEW-86: new internal-only "Insurance Companies" management module. Each insurance company
-- record belongs to one client (qvm_new_apps.list_data, list_id = 1 - the same "clients" list
-- already used by get_clients()/client_branches).
CREATE TABLE qvm_new_apps.insurance_companies (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  client_id integer NOT NULL REFERENCES qvm_new_apps.list_data(list_data_id),
  name text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX insurance_companies_client_id_idx ON qvm_new_apps.insurance_companies (client_id);

-- Optional link from a quotation to the insurance company covering the repair.
ALTER TABLE qvm_new_apps.quotations
  ADD COLUMN IF NOT EXISTS insurance_company_id bigint NULL
    REFERENCES qvm_new_apps.insurance_companies(id);

ALTER TABLE qvm_new_apps.insurance_companies ENABLE ROW LEVEL SECURITY;

CREATE POLICY insurance_companies_select_internal ON qvm_new_apps.insurance_companies
  FOR SELECT
  USING (qvm_new_apps.is_internal_user());

-- No INSERT/UPDATE/DELETE policies for anon/authenticated: all writes go through the
-- SECURITY DEFINER RPCs below, which check qvm_new_apps.is_internal_user() themselves.

CREATE OR REPLACE FUNCTION qvm_new_apps.list_insurance_companies()
RETURNS TABLE (
  id bigint,
  client_id integer,
  client_name text,
  name text,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  RETURN QUERY
  SELECT ic.id, ic.client_id, ld.list_data AS client_name, ic.name, ic.created_at, ic.updated_at
  FROM qvm_new_apps.insurance_companies ic
  LEFT JOIN qvm_new_apps.list_data ld ON ld.list_data_id = ic.client_id
  ORDER BY ic.name ASC;
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.create_insurance_company(
  p_client_id integer,
  p_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_id bigint;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Name is required');
  END IF;
  IF p_client_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Client is required');
  END IF;

  INSERT INTO qvm_new_apps.insurance_companies (client_id, name)
  VALUES (p_client_id, btrim(p_name))
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('status', 'success', 'id', v_id);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.update_insurance_company(
  p_id bigint,
  p_client_id integer,
  p_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;
  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Name is required');
  END IF;
  IF p_client_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Client is required');
  END IF;

  UPDATE qvm_new_apps.insurance_companies
  SET client_id = p_client_id, name = btrim(p_name), updated_at = now()
  WHERE id = p_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Insurance company not found');
  END IF;

  RETURN jsonb_build_object('status', 'success');
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.delete_insurance_company(
  p_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_in_use boolean;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM qvm_new_apps.quotations WHERE insurance_company_id = p_id
  ) INTO v_in_use;

  IF v_in_use THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'This insurance company is used by existing quotations and cannot be deleted');
  END IF;

  DELETE FROM qvm_new_apps.insurance_companies WHERE id = p_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'error', 'message', 'Insurance company not found');
  END IF;

  RETURN jsonb_build_object('status', 'success');
END;
$function$;

REVOKE ALL ON FUNCTION qvm_new_apps.list_insurance_companies() FROM public, anon;
GRANT EXECUTE ON FUNCTION qvm_new_apps.list_insurance_companies() TO authenticated;

REVOKE ALL ON FUNCTION qvm_new_apps.create_insurance_company(integer, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION qvm_new_apps.create_insurance_company(integer, text) TO authenticated;

REVOKE ALL ON FUNCTION qvm_new_apps.update_insurance_company(bigint, integer, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION qvm_new_apps.update_insurance_company(bigint, integer, text) TO authenticated;

REVOKE ALL ON FUNCTION qvm_new_apps.delete_insurance_company(bigint) FROM public, anon;
GRANT EXECUTE ON FUNCTION qvm_new_apps.delete_insurance_company(bigint) TO authenticated;
