-- vendor_branches.brands is supposed to hold list_data_id integers (list_id=4, car brands), but a
-- batch of rows were seeded with the brand's display name instead — some in English with
-- inconsistent casing/spelling ("isuzu", "CHERY PRO", "MAXIS"), most in Arabic ("تويوتا"). This
-- normalizes every such row to integer ids so brand-filter/matching logic (which compares against
-- list_data_id) works consistently. Resolution order per array element: already-numeric (or
-- numeric string) -> cast directly; exact case-insensitive match against list_data (list_id=4) ->
-- its id; otherwise a hardcoded alias for the known Arabic names / near-miss spellings found in
-- both QVM/dev and production (audited directly against live data before writing this). One
-- combined "Jeep Dodge Fiat Chrysler" entry expands to all 4 ids. One entry ("Tires and
-- Batteries") wasn't a car brand at all — a part-category value that ended up in the wrong column
-- — and is dropped from brands per explicit product decision, not moved anywhere.
DO $$
DECLARE
  vb RECORD;
  elem jsonb;
  raw_text text;
  matched_id integer;
  alias_ids integer[];
  new_ids integer[];
BEGIN
  FOR vb IN
    SELECT vendor_branch_id, brands
    FROM qvm_new_apps.vendor_branches
    WHERE EXISTS (
      SELECT 1 FROM jsonb_array_elements(brands) e WHERE jsonb_typeof(e) = 'string'
    )
  LOOP
    new_ids := ARRAY[]::integer[];

    FOR elem IN SELECT * FROM jsonb_array_elements(vb.brands)
    LOOP
      raw_text := trim(elem #>> '{}');

      IF raw_text ~ '^[0-9]+$' THEN
        new_ids := new_ids || raw_text::integer;
        CONTINUE;
      END IF;

      SELECT list_data_id INTO matched_id
      FROM qvm_new_apps.list_data
      WHERE list_id = 4 AND lower(list_data) = lower(raw_text)
      LIMIT 1;

      IF matched_id IS NOT NULL THEN
        new_ids := new_ids || matched_id;
        CONTINUE;
      END IF;

      alias_ids := CASE raw_text
        WHEN 'اطارات وبطاريات' THEN ARRAY[]::integer[]  -- Tires/Batteries — not a brand, dropped
        WHEN 'اودي' THEN ARRAY[36]                       -- AUDI
        WHEN 'بورش' THEN ARRAY[86]                       -- PORSCHE
        WHEN 'بيجو' THEN ARRAY[85]                       -- PEOGEUT
        WHEN 'تويوتا' THEN ARRAY[100]                    -- TOYOTA
        WHEN 'جاكوار' THEN ARRAY[66]                     -- JAGUAR
        WHEN 'جيب دودج فيات كليزار' THEN ARRAY[67,49,52,46] -- JEEP, DODGE, FIAT, CHRYSLER (source spelling: "كليزار")
        WHEN 'جيلي' THEN ARRAY[56]                       -- GEELY
        WHEN 'رنجروفر' THEN ARRAY[88]                    -- RANGE ROVER
        WHEN 'رينو الوعلان' THEN ARRAY[89]               -- RENAULT
        WHEN 'شاحناتVOLVO' THEN ARRAY[102]               -- VOLVO
        WHEN 'فولكس فاجن' THEN ARRAY[101]                -- VOLKSWAGEN
        WHEN 'كاديلاك' THEN ARRAY[42]                    -- CADILLAC
        WHEN 'كيا' THEN ARRAY[70]                        -- KIA
        WHEN 'ليكزيز' THEN ARRAY[74]                     -- LEXUS
        WHEN 'مازدة' THEN ARRAY[83]                      -- Mazda
        WHEN 'مرسيدس' THEN ARRAY[79]                     -- MERCEDES
        WHEN 'مستوبيشي' THEN ARRAY[82]                   -- MITSUBISHI
        WHEN 'نيسان' THEN ARRAY[84]                      -- Nissan
        WHEN 'هوندا' THEN ARRAY[61]                      -- HONDA
        WHEN 'هيونداي' THEN ARRAY[63]                    -- HYUNDAI
        WHEN 'CHERY PRO' THEN ARRAY[44]                  -- CHERY
        WHEN 'HOWO TRUCK' THEN ARRAY[259]                -- Sinotruk
        WHEN 'MAXIS' THEN ARRAY[77]                      -- MAXUS
        ELSE NULL
      END;

      IF alias_ids IS NOT NULL THEN
        new_ids := new_ids || alias_ids;
      ELSE
        RAISE WARNING 'vendor_branches.vendor_branch_id=% has unmapped brand string: %', vb.vendor_branch_id, raw_text;
      END IF;
    END LOOP;

    SELECT COALESCE(array_agg(DISTINCT x ORDER BY x), ARRAY[]::integer[]) INTO new_ids FROM unnest(new_ids) AS x;

    UPDATE qvm_new_apps.vendor_branches
    SET brands = to_jsonb(new_ids)
    WHERE vendor_branch_id = vb.vendor_branch_id;
  END LOOP;
END $$;
