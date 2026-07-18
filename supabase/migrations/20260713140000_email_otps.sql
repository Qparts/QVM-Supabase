-- Email OTP verification for registration. One active code per email (upsert on resend).
-- Only the SHA-256 hash of the code is stored (salted with the email), never the plaintext.
-- Accessed exclusively by the `email-otp` edge function via the service role — RLS is enabled
-- with no policies so anon/authenticated clients cannot read or write it.

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
-- No policies: the service role (edge function) bypasses RLS; everyone else is denied.

REVOKE ALL ON qvm_new_apps.email_otps FROM anon, authenticated;
GRANT ALL ON qvm_new_apps.email_otps TO service_role;
