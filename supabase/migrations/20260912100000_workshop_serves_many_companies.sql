-- A workshop serves several companies, and the quotation says which one it is for.
--
-- The tier was built one-company-per-workshop, and that is not how these businesses work: a
-- collision centre repairs cars for a fleet operator, an insurer and a leasing company out of the
-- same building, with the same people and the same bays. What changes hands per job is the company
-- being billed, not the site doing the work.
--
-- So the branch belongs to the WORKSHOP — it is a physical place — and the company is chosen when
-- the order is raised. Which means the company can no longer be read off the branch, and the
-- quotation has to carry it. That is the whole change, and everything below follows from it.

------------------------------------------------------------------------------ the link

CREATE TABLE IF NOT EXISTS qvm_new_apps.workshop_companies (
  workshop_id bigint  NOT NULL REFERENCES qvm_new_apps.client_workshops(workshop_id) ON DELETE CASCADE,
  company_id  integer NOT NULL REFERENCES qvm_new_apps.client_companies(company_id),
  -- One company is marked primary. Not a business rule — a fallback: client_branches.list_data_id
  -- is read by 62 functions that have no idea a branch can serve several companies, and they need
  -- SOME company to group by until they are moved onto the quotation's.
  is_primary  boolean NOT NULL DEFAULT false,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workshop_id, company_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_workshop_single_primary
  ON qvm_new_apps.workshop_companies (workshop_id) WHERE is_primary;
CREATE INDEX IF NOT EXISTS idx_workshop_companies_company
  ON qvm_new_apps.workshop_companies (company_id);

INSERT INTO qvm_new_apps.workshop_companies (workshop_id, company_id, is_primary)
SELECT w.workshop_id, w.company_id, true
FROM qvm_new_apps.client_workshops w
WHERE w.company_id IS NOT NULL
ON CONFLICT (workshop_id, company_id) DO NOTHING;

------------------------------------------------------------------------------ the keys that cannot hold
--
-- (workshop_id, list_data_id) → (workshop_id, company_id) said "a branch's company is its
-- workshop's company". With several companies per workshop that sentence has no meaning, so the
-- constraint goes. client_branches.list_data_id survives as the PRIMARY company, which is what the
-- existing dashboards will keep grouping by.

ALTER TABLE qvm_new_apps.client_branches
  DROP CONSTRAINT IF EXISTS client_branches_workshop_company_fk;

ALTER TABLE qvm_new_apps.client_workshops_descriptions
  DROP CONSTRAINT IF EXISTS client_workshops_descriptions_workshop_id_company_id_fkey;
DROP INDEX IF EXISTS qvm_new_apps.uq_workshop_name_per_company_language;

-- The name was held unique within a company; a workshop that serves three companies would have had
-- to be unique in all three, which is a rule about nothing. Per workshop per language is the PK
-- already, so this index is only for lookup.
CREATE INDEX IF NOT EXISTS idx_workshop_name_per_language
  ON qvm_new_apps.client_workshops_descriptions (language_id, lower(name));

ALTER TABLE qvm_new_apps.client_workshops_descriptions
  ALTER COLUMN company_id DROP NOT NULL;

COMMENT ON COLUMN qvm_new_apps.client_workshops.company_id IS
  'The workshop''s PRIMARY company, mirrored from workshop_companies. The full set lives there; '
  'this is what client_branches.list_data_id follows so the older dashboards keep grouping.';

------------------------------------------------------------------------------ the quotation's company

ALTER TABLE qvm_new_apps.quotations
  ADD COLUMN IF NOT EXISTS company_id integer REFERENCES qvm_new_apps.client_companies(company_id);
CREATE INDEX IF NOT EXISTS idx_quotations_company ON qvm_new_apps.quotations (company_id);

COMMENT ON COLUMN qvm_new_apps.quotations.company_id IS
  'The company this order is for, chosen when it is raised. Authoritative — a branch can serve '
  'several companies, so the branch no longer answers this question.';

-- Every order raised so far was raised when a branch had exactly one company, so its branch still
-- tells the truth about it. This is the one moment that is true, which is why the backfill happens
-- here rather than being left for later.
UPDATE qvm_new_apps.quotations q
SET company_id = sub.company_id
FROM (
  SELECT qi.quotation_id, min(cb.list_data_id) AS company_id
  FROM qvm_new_apps.quotation_items qi
  JOIN qvm_new_apps.client_branches cb ON cb.customer_id = qi.customer_id
  WHERE cb.list_data_id IS NOT NULL
  GROUP BY qi.quotation_id
) sub
WHERE q.quotation_id = sub.quotation_id AND q.company_id IS NULL;
