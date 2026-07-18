-- Synced from QVM/test branch applied migration history (version 20260625030309, name: create_part_dictionary_tables)

CREATE TABLE IF NOT EXISTS qvm_new_apps.part_dictionary (
  main_part_code TEXT PRIMARY KEY,
  name_ar        TEXT NOT NULL,
  name_en        TEXT NOT NULL,
  category_ar    TEXT,
  category_en    TEXT,
  status         TEXT NOT NULL DEFAULT 'active',
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS qvm_new_apps.part_synonyms (
  synonym_code   TEXT PRIMARY KEY,
  synonym_text   TEXT NOT NULL,
  main_part_code TEXT NOT NULL REFERENCES qvm_new_apps.part_dictionary(main_part_code),
  source         TEXT,
  status         TEXT NOT NULL DEFAULT 'active',
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_part_synonyms_main_part_code ON qvm_new_apps.part_synonyms(main_part_code);

CREATE TABLE IF NOT EXISTS qvm_new_apps.unrecognized_part_names (
  id            BIGSERIAL PRIMARY KEY,
  entered_text  TEXT NOT NULL,
  request_id    TEXT,
  user_id       UUID,
  status        TEXT NOT NULL DEFAULT 'pending_review',
  review_note   TEXT,
  resolved_main_part_code TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  reviewed_at   TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_unrecognized_status ON qvm_new_apps.unrecognized_part_names(status);
;
