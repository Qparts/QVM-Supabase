-- Companies → vendors & workshops → customers → customer branches → addresses.
--
-- The third tree, and the one that reaches the end of the chain: the person or organisation the
-- work is actually for. A workshop repairs their car; a vendor sells them the part.
--
-- The name. qvm_new_apps.customers is taken — it is the company master from the customers module,
-- keyed one-to-one to a row in list 1, and it means "a company we invoice". What this table holds
-- is the workshop's or the vendor's own customer, which is a different thing at a different level,
-- so it is end_customers. Two tables called customers would be a bug waiting for whoever reads the
-- code next.
--
-- A customer belongs to a workshop or to a vendor, and to more than one of either: the same person
-- takes their car to a workshop and buys a tyre from a vendor, and both should find them. That is
-- what end_customer_owners holds, and why linking by code works here the way it does everywhere
-- else.
--
-- Four kinds, and the kind decides the shape of the rest. An individual has a name and nothing
-- else; an insurance customer IS a row in insurance_companies, so it carries a reference instead of
-- a typed name; a company may have a tax number; a government entity may not. The checks below say
-- so rather than leaving four half-filled shapes in one table.

CREATE TABLE IF NOT EXISTS qvm_new_apps.end_customers (
  end_customer_id bigserial PRIMARY KEY,
  customer_kind   text NOT NULL CHECK (customer_kind IN ('individual', 'insurance', 'company', 'government')),
  -- Typed for three of the four kinds. An insurance customer's name lives in insurance_companies,
  -- because it is the same organisation the rest of the platform already knows.
  name            text,
  insurance_company_id bigint REFERENCES qvm_new_apps.insurance_companies(id),
  -- Companies only. A tax number on an individual is a data-entry mistake, not a fact.
  tax_number      text,
  contact_person  text,
  phone           text,
  email           text,
  customer_code   text,
  is_active       boolean NOT NULL DEFAULT true,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid, updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT end_customers_named CHECK (
    (customer_kind = 'insurance' AND insurance_company_id IS NOT NULL)
    OR (customer_kind <> 'insurance' AND btrim(COALESCE(name, '')) <> '')
  ),
  CONSTRAINT end_customers_tax_is_for_companies CHECK (
    tax_number IS NULL OR customer_kind = 'company'
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_end_customers_code
  ON qvm_new_apps.end_customers (customer_code) WHERE customer_code IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_end_customers_kind ON qvm_new_apps.end_customers (customer_kind);

-- The same invite code the other two trees use, third letter different so a code says what it
-- opens: WS- a workshop, VN- a vendor, CU- a customer.
CREATE OR REPLACE FUNCTION qvm_new_apps.generate_customer_code()
RETURNS text LANGUAGE plpgsql VOLATILE
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code text; v_try int := 0;
BEGIN
  LOOP
    v_code := 'CU-';
    FOR i IN 1..6 LOOP
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    END LOOP;
    EXIT WHEN NOT EXISTS (SELECT 1 FROM qvm_new_apps.end_customers WHERE customer_code = v_code);
    v_try := v_try + 1;
    IF v_try > 50 THEN RAISE EXCEPTION 'Could not find a free customer code'; END IF;
  END LOOP;
  RETURN v_code;
END $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.customer_gets_a_code()
RETURNS trigger LANGUAGE plpgsql SET search_path TO 'qvm_new_apps', 'public' AS $$
BEGIN
  IF NEW.customer_code IS NULL THEN NEW.customer_code := qvm_new_apps.generate_customer_code(); END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_customer_gets_a_code ON qvm_new_apps.end_customers;
CREATE TRIGGER trg_customer_gets_a_code
  BEFORE INSERT ON qvm_new_apps.end_customers
  FOR EACH ROW EXECUTE FUNCTION qvm_new_apps.customer_gets_a_code();

------------------------------------------------------------------------------ who they belong to

CREATE TABLE IF NOT EXISTS qvm_new_apps.end_customer_owners (
  owner_id        bigserial PRIMARY KEY,
  end_customer_id bigint  NOT NULL REFERENCES qvm_new_apps.end_customers(end_customer_id) ON DELETE CASCADE,
  workshop_id     bigint  REFERENCES qvm_new_apps.client_workshops(workshop_id) ON DELETE CASCADE,
  vendor_id       integer REFERENCES qvm_new_apps.vendors(vendor_id) ON DELETE CASCADE,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(),
  -- One or the other, never both and never neither. A row that names both would be two claims
  -- wearing one id.
  CONSTRAINT end_customer_owner_is_one_thing CHECK (
    (workshop_id IS NOT NULL AND vendor_id IS NULL)
    OR (workshop_id IS NULL AND vendor_id IS NOT NULL)
  )
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_end_customer_workshop
  ON qvm_new_apps.end_customer_owners (end_customer_id, workshop_id) WHERE workshop_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_end_customer_vendor
  ON qvm_new_apps.end_customer_owners (end_customer_id, vendor_id) WHERE vendor_id IS NOT NULL;

------------------------------------------------------------------------------ branches

CREATE TABLE IF NOT EXISTS qvm_new_apps.end_customer_branches (
  end_customer_branch_id bigserial PRIMARY KEY,
  end_customer_id bigint NOT NULL REFERENCES qvm_new_apps.end_customers(end_customer_id) ON DELETE CASCADE,
  branch_name text NOT NULL,
  city_id     integer REFERENCES qvm_new_apps.cities(city_id),
  is_active   boolean NOT NULL DEFAULT true,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid, updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_end_customer_branches_customer
  ON qvm_new_apps.end_customer_branches (end_customer_id);

CREATE TABLE IF NOT EXISTS qvm_new_apps.end_customer_branches_descriptions (
  end_customer_branch_id bigint  NOT NULL REFERENCES qvm_new_apps.end_customer_branches(end_customer_branch_id) ON DELETE CASCADE,
  language_id            integer NOT NULL REFERENCES qvm_new_apps.languages(language_id),
  name                   text    NOT NULL CHECK (btrim(name) <> ''),
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid, updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (end_customer_branch_id, language_id)
);

------------------------------------------------------------------------------ addresses

CREATE TABLE IF NOT EXISTS qvm_new_apps.end_customer_addresses (
  address_id       bigserial PRIMARY KEY,
  end_customer_branch_id bigint NOT NULL
    REFERENCES qvm_new_apps.end_customer_branches(end_customer_branch_id) ON DELETE CASCADE,
  label            text,
  address_line     text,
  street           text,
  building_number  text,
  secondary_number text,
  short_address    text,
  city_id          integer REFERENCES qvm_new_apps.cities(city_id),
  district_id      integer REFERENCES qvm_new_apps.districts(district_id),
  region_id        integer REFERENCES qvm_new_apps.regions(region_id),
  postal_code      text,
  city             text,
  geo_lat          numeric(10,7),
  geo_lng          numeric(10,7),
  contact_name     text,
  contact_phone    text,
  -- Where the car is collected from, and where the work is delivered back to. Often the same
  -- address, which is why both default to true rather than making somebody choose.
  is_pickup        boolean NOT NULL DEFAULT true,
  is_delivery      boolean NOT NULL DEFAULT true,
  is_default       boolean NOT NULL DEFAULT false,
  is_active        boolean NOT NULL DEFAULT true,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid, updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT end_customer_addresses_short_address_shape
    CHECK (short_address IS NULL OR short_address ~ '^[A-Za-z]{4}[0-9]{4}$')
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_end_customer_address_one_default
  ON qvm_new_apps.end_customer_addresses (end_customer_branch_id) WHERE is_default AND is_active;

------------------------------------------------------------------------------ their own users

-- Two roles, minted the way every role here is: by name, because the id differs per environment.
INSERT INTO qvm_new_apps.list_data (list_id, list_data)
SELECT 16, v.name
FROM (VALUES ('Customer'), ('Customer Admin')) AS v(name)
WHERE NOT EXISTS (
  SELECT 1 FROM qvm_new_apps.list_data ld
   WHERE ld.list_id = 16 AND lower(btrim(ld.list_data)) = lower(v.name));

CREATE OR REPLACE FUNCTION qvm_new_apps.customer_role_id(p_admin boolean DEFAULT false)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT ld.list_data_id FROM qvm_new_apps.list_data ld
   WHERE ld.list_id = 16
     AND lower(btrim(ld.list_data)) = CASE WHEN p_admin THEN 'customer admin' ELSE 'customer' END
   LIMIT 1;
$$;

CREATE TABLE IF NOT EXISTS qvm_new_apps.end_customer_users (
  user_id         uuid   NOT NULL,
  end_customer_id bigint NOT NULL REFERENCES qvm_new_apps.end_customers(end_customer_id) ON DELETE CASCADE,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, end_customer_id)
);

------------------------------------------------------------------------------ resolved views

CREATE OR REPLACE VIEW qvm_new_apps.v_end_customers AS
SELECT c.end_customer_id, c.customer_kind, c.customer_code, c.tax_number,
       c.contact_person, c.phone, c.email, c.is_active, c.created_at,
       -- An insurance customer is named by the list it comes from; everyone else by what was typed.
       COALESCE(ic.name, c.name) AS name,
       c.insurance_company_id,
       (SELECT count(*) FROM qvm_new_apps.end_customer_branches b
         WHERE b.end_customer_id = c.end_customer_id) AS branch_count,
       (SELECT count(*) FROM qvm_new_apps.end_customer_users u
         WHERE u.end_customer_id = c.end_customer_id) AS user_count
FROM qvm_new_apps.end_customers c
LEFT JOIN qvm_new_apps.insurance_companies ic ON ic.id = c.insurance_company_id;

CREATE OR REPLACE VIEW qvm_new_apps.v_end_customer_branches AS
SELECT b.end_customer_branch_id, b.end_customer_id, b.city_id, b.is_active,
       COALESCE(d.name, b.branch_name) AS name, d.language_id AS name_language_id,
       (SELECT count(*) FROM qvm_new_apps.end_customer_addresses a
         WHERE a.end_customer_branch_id = b.end_customer_branch_id AND a.is_active) AS address_count
FROM qvm_new_apps.end_customer_branches b
LEFT JOIN LATERAL (
  SELECT d.* FROM qvm_new_apps.end_customer_branches_descriptions d
   WHERE d.end_customer_branch_id = b.end_customer_branch_id
   ORDER BY (d.language_id = qvm_new_apps.current_language_id()) DESC,
            (d.language_id = qvm_new_apps.default_language_id()) DESC,
            d.language_id
   LIMIT 1
) d ON true;

GRANT SELECT ON qvm_new_apps.v_end_customers, qvm_new_apps.v_end_customer_branches TO authenticated;
GRANT ALL ON qvm_new_apps.end_customers, qvm_new_apps.end_customer_owners,
             qvm_new_apps.end_customer_branches, qvm_new_apps.end_customer_branches_descriptions,
             qvm_new_apps.end_customer_addresses, qvm_new_apps.end_customer_users TO service_role;
GRANT USAGE, SELECT ON SEQUENCE qvm_new_apps.end_customers_end_customer_id_seq,
                                qvm_new_apps.end_customer_owners_owner_id_seq,
                                qvm_new_apps.end_customer_branches_end_customer_branch_id_seq,
                                qvm_new_apps.end_customer_addresses_address_id_seq TO service_role;
