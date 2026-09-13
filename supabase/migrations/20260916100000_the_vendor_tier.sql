-- Companies → vendors → vendor branches → addresses.
--
-- The same four levels the client side has, built the same way and for the same reason: a vendor is
-- a real thing with branches in real places, and both were free text or nothing at all. What
-- exists today is a flat `vendors` table and a `vendor_branches` table whose city is a string and
-- whose address is one line of text.
--
-- Nothing is re-keyed. vendors.vendor_id and vendor_branches.vendor_branch_id are referenced by
-- quotations, costs, purchase orders and the whole vendor portal; they keep their ids and their
-- columns. What is added sits beside them:
--
--   * names in every language the platform speaks, in a descriptions table, seeded from the names
--     already there, so the switch to Arabic reaches vendors on the day a third language is added
--     rather than a migration later;
--   * a city that is a row rather than a spelling;
--   * a code, so a company can link a vendor it does not administer — the same invite-code shape
--     the workshops use;
--   * addresses, several per branch, one of them the default.
--
-- A vendor belongs to no company until someone links it, exactly as a workshop does. The existing
-- vendors therefore start unassigned and keep working: nothing reads vendor_companies yet except
-- the tree.

------------------------------------------------------------------------------ names

CREATE TABLE IF NOT EXISTS qvm_new_apps.vendors_descriptions (
  vendor_id   integer NOT NULL REFERENCES qvm_new_apps.vendors(vendor_id) ON DELETE CASCADE,
  language_id integer NOT NULL REFERENCES qvm_new_apps.languages(language_id),
  name        text    NOT NULL CHECK (btrim(name) <> ''),
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid, updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (vendor_id, language_id)
);

-- The name each vendor already has becomes its name in the default language. Not in every language:
-- an Arabic column holding an English name is worse than no Arabic at all, because the fallback
-- chain can no longer tell that the translation is missing.
INSERT INTO qvm_new_apps.vendors_descriptions (vendor_id, language_id, name)
SELECT v.vendor_id, qvm_new_apps.default_language_id(), btrim(v.vendor_name)
FROM qvm_new_apps.vendors v
WHERE btrim(COALESCE(v.vendor_name, '')) <> ''
ON CONFLICT (vendor_id, language_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS qvm_new_apps.vendor_branches_descriptions (
  vendor_branch_id bigint  NOT NULL REFERENCES qvm_new_apps.vendor_branches(vendor_branch_id) ON DELETE CASCADE,
  language_id      integer NOT NULL REFERENCES qvm_new_apps.languages(language_id),
  name             text    NOT NULL CHECK (btrim(name) <> ''),
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid, updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (vendor_branch_id, language_id)
);

INSERT INTO qvm_new_apps.vendor_branches_descriptions (vendor_branch_id, language_id, name)
SELECT b.vendor_branch_id, qvm_new_apps.default_language_id(), btrim(b.branch_name)
FROM qvm_new_apps.vendor_branches b
WHERE btrim(COALESCE(b.branch_name, '')) <> ''
ON CONFLICT (vendor_branch_id, language_id) DO NOTHING;

------------------------------------------------------------------------------ city, and a code

ALTER TABLE qvm_new_apps.vendors
  ADD COLUMN IF NOT EXISTS city_id integer REFERENCES qvm_new_apps.cities(city_id),
  ADD COLUMN IF NOT EXISTS vendor_code text;

ALTER TABLE qvm_new_apps.vendor_branches
  ADD COLUMN IF NOT EXISTS city_id integer REFERENCES qvm_new_apps.cities(city_id);

-- Same alphabet as the workshop code, and the same reason: it is read off one screen and typed
-- into another, so O/0 and I/1 are left out.
CREATE OR REPLACE FUNCTION qvm_new_apps.generate_vendor_code()
RETURNS text LANGUAGE plpgsql VOLATILE
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code text;
  v_try int := 0;
BEGIN
  LOOP
    v_code := 'VN-';
    FOR i IN 1..6 LOOP
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    END LOOP;
    EXIT WHEN NOT EXISTS (SELECT 1 FROM qvm_new_apps.vendors WHERE vendor_code = v_code);
    v_try := v_try + 1;
    IF v_try > 50 THEN RAISE EXCEPTION 'Could not find a free vendor code'; END IF;
  END LOOP;
  RETURN v_code;
END $$;

UPDATE qvm_new_apps.vendors SET vendor_code = qvm_new_apps.generate_vendor_code()
 WHERE vendor_code IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_vendors_code
  ON qvm_new_apps.vendors (vendor_code) WHERE vendor_code IS NOT NULL;

CREATE OR REPLACE FUNCTION qvm_new_apps.vendor_gets_a_code()
RETURNS trigger LANGUAGE plpgsql SET search_path TO 'qvm_new_apps', 'public' AS $$
BEGIN
  IF NEW.vendor_code IS NULL THEN NEW.vendor_code := qvm_new_apps.generate_vendor_code(); END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_vendor_gets_a_code ON qvm_new_apps.vendors;
CREATE TRIGGER trg_vendor_gets_a_code
  BEFORE INSERT ON qvm_new_apps.vendors
  FOR EACH ROW EXECUTE FUNCTION qvm_new_apps.vendor_gets_a_code();

------------------------------------------------------------------------------ which companies a vendor serves

CREATE TABLE IF NOT EXISTS qvm_new_apps.vendor_companies (
  vendor_id  integer NOT NULL REFERENCES qvm_new_apps.vendors(vendor_id) ON DELETE CASCADE,
  company_id integer NOT NULL REFERENCES qvm_new_apps.client_companies(company_id) ON DELETE CASCADE,
  -- One is primary, for the same reason it is on the workshop side: the older screens group by a
  -- single company and need an answer until they are moved onto the order's.
  is_primary boolean NOT NULL DEFAULT false,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (vendor_id, company_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_vendor_single_primary
  ON qvm_new_apps.vendor_companies (vendor_id) WHERE is_primary;

------------------------------------------------------------------------------ addresses

CREATE TABLE IF NOT EXISTS qvm_new_apps.vendor_addresses (
  address_id       bigserial PRIMARY KEY,
  vendor_branch_id bigint NOT NULL REFERENCES qvm_new_apps.vendor_branches(vendor_branch_id) ON DELETE CASCADE,
  label            text,
  address_line     text,
  city_id          integer REFERENCES qvm_new_apps.cities(city_id),
  district_id      integer REFERENCES qvm_new_apps.districts(district_id),
  postal_code      text,
  -- Kept in step with city_id for the same reason the client side keeps its own: the screens that
  -- predate the cities table read a string.
  city             text,
  geo_lat          numeric(10,7),
  geo_lng          numeric(10,7),
  contact_name     text,
  contact_phone    text,
  -- A vendor's addresses divide differently from a client's. One warehouse sends parts, another
  -- takes returns, and the office does neither.
  ships_from       boolean NOT NULL DEFAULT true,
  accepts_returns  boolean NOT NULL DEFAULT true,
  is_default       boolean NOT NULL DEFAULT false,
  is_active        boolean NOT NULL DEFAULT true,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid, updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_vendor_address_one_default
  ON qvm_new_apps.vendor_addresses (vendor_branch_id) WHERE is_default AND is_active;
CREATE INDEX IF NOT EXISTS idx_vendor_addresses_branch
  ON qvm_new_apps.vendor_addresses (vendor_branch_id) WHERE is_active;

-- The one line of address each branch already has becomes its first address, so no vendor starts
-- with nothing where it previously had something.
INSERT INTO qvm_new_apps.vendor_addresses
  (vendor_branch_id, label, address_line, city, is_default)
SELECT b.vendor_branch_id, 'Branch address', btrim(b.address), b.city, true
FROM qvm_new_apps.vendor_branches b
WHERE btrim(COALESCE(b.address, '')) <> ''
  AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.vendor_addresses a
                   WHERE a.vendor_branch_id = b.vendor_branch_id);

------------------------------------------------------------------------------ resolved views

CREATE OR REPLACE VIEW qvm_new_apps.v_vendors AS
SELECT v.vendor_id, v.vendor_code, v.vendor_type, v.email, v.city_id,
       d.name, d.language_id AS name_language_id,
       (SELECT count(*) FROM qvm_new_apps.vendor_branches b WHERE b.vendor_id = v.vendor_id) AS branch_count
FROM qvm_new_apps.vendors v
LEFT JOIN LATERAL (
  SELECT d.* FROM qvm_new_apps.vendors_descriptions d
   WHERE d.vendor_id = v.vendor_id
   ORDER BY (d.language_id = qvm_new_apps.current_language_id()) DESC,
            (d.language_id = qvm_new_apps.default_language_id()) DESC,
            d.language_id
   LIMIT 1
) d ON true;

CREATE OR REPLACE VIEW qvm_new_apps.v_vendor_branches AS
SELECT b.vendor_branch_id, b.vendor_id, b.city_id, b.is_active,
       COALESCE(d.name, b.branch_name) AS name, d.language_id AS name_language_id,
       (SELECT count(*) FROM qvm_new_apps.vendor_addresses a
         WHERE a.vendor_branch_id = b.vendor_branch_id AND a.is_active) AS address_count
FROM qvm_new_apps.vendor_branches b
LEFT JOIN LATERAL (
  SELECT d.* FROM qvm_new_apps.vendor_branches_descriptions d
   WHERE d.vendor_branch_id = b.vendor_branch_id
   ORDER BY (d.language_id = qvm_new_apps.current_language_id()) DESC,
            (d.language_id = qvm_new_apps.default_language_id()) DESC,
            d.language_id
   LIMIT 1
) d ON true;

GRANT SELECT ON qvm_new_apps.v_vendors, qvm_new_apps.v_vendor_branches TO authenticated;
GRANT ALL ON qvm_new_apps.vendors_descriptions, qvm_new_apps.vendor_branches_descriptions,
             qvm_new_apps.vendor_companies, qvm_new_apps.vendor_addresses TO service_role;
GRANT USAGE, SELECT ON SEQUENCE qvm_new_apps.vendor_addresses_address_id_seq TO service_role;
