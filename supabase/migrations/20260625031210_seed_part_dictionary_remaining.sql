-- Synced from QVM/test branch applied migration history (version 20260625031210, name: seed_part_dictionary_remaining)

DO $$
DECLARE r RECORD;
BEGIN
  -- Insert remaining main parts (101-615) and all synonyms via the seed function
  -- This is handled by seed_part_dictionary_fn below
  NULL;
END $$;
;
