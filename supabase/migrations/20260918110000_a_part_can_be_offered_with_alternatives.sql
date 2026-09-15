-- A vendor can offer alternatives to the part that was asked for.
--
-- Until now a quotation_vendor_items row carried a single free-text alternative_part_number and
-- nothing else about it: no price, no quantity, no delivery, no brand, no origin, no photo, and no
-- say in whether the workshop got to see it. That is one alternative per part, unpriced — which is
-- not an offer, it is a note. The pricing screen is being rebuilt around alternatives being real
-- offers, so they need a table of their own.
--
-- Three things arrive together here because the new alternative row needs all of them: the two
-- commercial grades, the origin-country list, and the table itself.

-- ── 1. Brand classes: تجاري splits into first and second grade ─────────────────────────────────
--
-- list_data holds these in English and the app translates them (i18n.ts: 'Commercial' → 'تجاري'),
-- so the split happens in English here and picks up its Arabic on the way out.
--
-- The existing row is RENAMED rather than retired and replaced. Every quotation item already
-- classified as Commercial points at this list_data_id; a new id would leave all of them on a grade
-- that no longer appears in the picker, and nothing in the data says which of the two they meant.
-- Renaming says the true thing: what used to be called "commercial" is first grade.
UPDATE qvm_new_apps.list_data ld
   SET list_data = 'Commercial Grade 1'
  FROM qvm_new_apps.lists l
 WHERE l.list_id = ld.list_id
   AND l.list_name = 'brand_class'
   AND lower(btrim(ld.list_data)) = 'commercial';

INSERT INTO qvm_new_apps.list_data (list_id, list_data)
SELECT l.list_id, 'Commercial Grade 2'
  FROM qvm_new_apps.lists l
 WHERE l.list_name = 'brand_class'
   AND NOT EXISTS (
     SELECT 1 FROM qvm_new_apps.list_data ld
      WHERE ld.list_id = l.list_id
        AND lower(btrim(ld.list_data)) = 'commercial grade 2');

-- ── 2. Origin countries ───────────────────────────────────────────────────────────────────────
--
-- Deliberately a table and not another list_data list. list_data is a flat (list, text) store with
-- no room for a code, and an origin country is looked up by ISO code far more often than by name —
-- it is also the one field here that a customs form, an invoice or an import record will want to
-- agree with. The rows are seeded separately, from the list the team supplies.
CREATE TABLE IF NOT EXISTS qvm_new_apps.origin_countries (
  origin_country_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code              text        NOT NULL,          -- ISO 3166-1 alpha-2
  name_en           text        NOT NULL,
  name_ar           text        NOT NULL,
  sort_order        integer     NOT NULL DEFAULT 0,
  is_active         boolean     NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_origin_countries_code
  ON qvm_new_apps.origin_countries (upper(code));

-- ── 3. The alternatives themselves ────────────────────────────────────────────────────────────
--
-- Hangs off cost_id, not quotation_item_id: an alternative is something a *particular vendor* is
-- offering on *their* line. Two vendors offering different alternatives to the same part must not
-- see each other's, and the existing per-vendor scoping all keys off cost_id.
CREATE TABLE IF NOT EXISTS qvm_new_apps.quotation_vendor_item_alternatives (
  alternative_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cost_id            bigint  NOT NULL
                       REFERENCES qvm_new_apps.quotation_vendor_items (cost_id) ON DELETE CASCADE,
  part_number        text    NOT NULL,
  brand_class        bigint  REFERENCES qvm_new_apps.list_data (list_data_id),
  brand_id           bigint  REFERENCES qvm_new_apps.list_data (list_data_id),
  origin_country_id  bigint  REFERENCES qvm_new_apps.origin_countries (origin_country_id),
  unit_price         numeric(12,2),
  available_quantity integer,
  delivery_days      integer,
  note               text,
  -- [{ "url": ..., "path": ..., "name": ... }] in the existing public `attachments` bucket, the
  -- same one the quotation's own files use. A jsonb array rather than a child table because the
  -- photos are only ever read as a set with the row they belong to, and are never queried across.
  photos             jsonb   NOT NULL DEFAULT '[]'::jsonb,
  -- يظهر للورشة. Defaults to hidden: an alternative the vendor is still filling in must not reach
  -- the workshop until they say so.
  visible_to_workshop boolean NOT NULL DEFAULT false,
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         uuid,
  updated_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_qvi_alternatives_cost
  ON qvm_new_apps.quotation_vendor_item_alternatives (cost_id);

-- ── 4. The offered part gains a brand and an origin ───────────────────────────────────────────
--
-- available_brand_class already says which grade the vendor is supplying; the new grid puts grade,
-- brand and origin in one column, and the other two had nowhere to live.
ALTER TABLE qvm_new_apps.quotation_vendor_items
  ADD COLUMN IF NOT EXISTS available_brand_id bigint REFERENCES qvm_new_apps.list_data (list_data_id),
  ADD COLUMN IF NOT EXISTS origin_country_id  bigint REFERENCES qvm_new_apps.origin_countries (origin_country_id);

-- Grants: reads go through SECURITY DEFINER functions, so these are for the service role (edge
-- functions query PostgREST as themselves) and for the reference list, which is a public fact about
-- the platform rather than anyone's data.
GRANT ALL ON qvm_new_apps.origin_countries,
             qvm_new_apps.quotation_vendor_item_alternatives TO service_role;
GRANT SELECT ON qvm_new_apps.origin_countries TO authenticated;
