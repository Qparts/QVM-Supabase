-- Synced from QVM/test branch applied migration history (version 20260713170823, name: email_otps)
CREATE TABLE IF NOT EXISTS qvm_new_apps.email_otps (
  email        text PRIMARY KEY,
  code_hash    text NOT NULL,
  expires_at   timestamptz NOT NULL,
  attempts     integer NOT NULL DEFAULT 0,
  last_sent_at timestamptz NOT NULL DEFAULT now(),
  verified     boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE qvm_new_apps.email_otps ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON qvm_new_apps.email_otps FROM anon, authenticated;;
