-- pg_net (the `net` schema, used by webhook-dispatching triggers such as
-- trg_push_vendor_item_on_accept / the sheet-sync triggers via net.http_post) was present on
-- test but missing on dev — the earlier dev bootstrap via pg_dump only covered the public and
-- qvm_new_apps schemas, not extensions. Installing it here so dev matches test.
CREATE EXTENSION IF NOT EXISTS pg_net;

-- Same gap, lower stakes: these two are pure dev-tooling extensions (Supabase Studio's index
-- advisor), unused by any application code, but adding for full extension parity with test.
CREATE EXTENSION IF NOT EXISTS hypopg;
CREATE EXTENSION IF NOT EXISTS index_advisor;
