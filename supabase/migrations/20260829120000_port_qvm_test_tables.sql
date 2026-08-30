-- Ports 32 tables from QVM/test that didn't exist on QVM/dev: WhatsApp bridge/inbox (wa_*),
-- upload/bulk-import pipeline (upload_*), pricing policy engine (pricing_*), Extract-PN v2
-- part matching (part_aliases/part_name_dictionary/part_offers/part_purchase_history,
-- quotation_item_alt_pns/quotation_item_extraction_events), email integration (email_accounts)
-- and a few standalone tables (agency_price_reference, group_import_requests,
-- inventory_stock, stock_auction_items). Extracted verbatim from QVM/test's live catalog
-- (pg_attribute/pg_constraint/pg_indexes) and applied to QVM/dev only — QVM/test untouched.

-- ===== upload_templates =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."upload_templates" (
  "template_key" text NOT NULL,
  "label_en" text NOT NULL,
  "label_ar" text NOT NULL,
  "blurb_en" text NOT NULL,
  "blurb_ar" text NOT NULL,
  "columns" jsonb DEFAULT '[]'::jsonb NOT NULL,
  "needs_branch" boolean DEFAULT false NOT NULL,
  "needs_vendor" boolean DEFAULT false NOT NULL,
  "is_active" boolean DEFAULT true NOT NULL,
  "sort_order" integer DEFAULT 0 NOT NULL,
  "allowed_for_vendor" boolean DEFAULT false NOT NULL,
  CONSTRAINT "upload_templates_pkey" PRIMARY KEY (template_key)
);
ALTER TABLE qvm_new_apps."upload_templates" ENABLE ROW LEVEL SECURITY;

-- ===== upload_batches =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."upload_batches" (
  "batch_id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "template_key" text NOT NULL,
  "file_name" text NOT NULL,
  "file_path" text,
  "source_kind" text DEFAULT 'vendor'::text NOT NULL,
  "source_id" bigint,
  "source_label" text,
  "branch_scope" text DEFAULT 'all'::text NOT NULL,
  "branch_ids" bigint[] DEFAULT '{}'::bigint[] NOT NULL,
  "status" text DEFAULT 'draft'::text NOT NULL,
  "rows_total" integer DEFAULT 0 NOT NULL,
  "rows_ready" integer DEFAULT 0 NOT NULL,
  "rows_disabled" integer DEFAULT 0 NOT NULL,
  "rows_rejected" integer DEFAULT 0 NOT NULL,
  "rows_duplicate" integer DEFAULT 0 NOT NULL,
  "uploaded_by" uuid,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "published_at" timestamp with time zone,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "upload_batches_source_kind_check" CHECK ((source_kind = ANY (ARRAY['vendor'::text, 'agency'::text, 'internal'::text]))),
  CONSTRAINT "upload_batches_branch_scope_check" CHECK ((branch_scope = ANY (ARRAY['all'::text, 'specific'::text]))),
  CONSTRAINT "upload_batches_status_check" CHECK ((status = ANY (ARRAY['draft'::text, 'preview'::text, 'published'::text, 'failed'::text, 'rolled_back'::text]))),
  CONSTRAINT "upload_batches_template_key_fkey" FOREIGN KEY (template_key) REFERENCES qvm_new_apps.upload_templates(template_key),
  CONSTRAINT "upload_batches_pkey" PRIMARY KEY (batch_id)
);
CREATE INDEX IF NOT EXISTS upload_batches_recent ON qvm_new_apps.upload_batches USING btree (created_at DESC);
ALTER TABLE qvm_new_apps."upload_batches" ENABLE ROW LEVEL SECURITY;

-- ===== agency_price_reference =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."agency_price_reference" (
  "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "source_part_number" text NOT NULL,
  "clean_part_number" text NOT NULL,
  "source_name" text,
  "clean_name" text,
  "brand" text,
  "agency_price" numeric NOT NULL,
  "effective_from" date,
  "source_label" text DEFAULT 'agency'::text NOT NULL,
  "batch_id" bigint,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "agency_price_reference_batch_id_fkey" FOREIGN KEY (batch_id) REFERENCES qvm_new_apps.upload_batches(batch_id) ON DELETE SET NULL,
  CONSTRAINT "agency_price_reference_pkey" PRIMARY KEY (id)
);
CREATE UNIQUE INDEX IF NOT EXISTS agency_price_reference_part_source ON qvm_new_apps.agency_price_reference USING btree (clean_part_number, lower(source_label));
CREATE INDEX IF NOT EXISTS agency_price_reference_by_batch ON qvm_new_apps.agency_price_reference USING btree (batch_id);
ALTER TABLE qvm_new_apps."agency_price_reference" ENABLE ROW LEVEL SECURITY;

-- ===== email_accounts =====
CREATE SEQUENCE IF NOT EXISTS qvm_new_apps.email_accounts_account_id_seq;
CREATE TABLE IF NOT EXISTS qvm_new_apps."email_accounts" (
  "account_id" bigint DEFAULT nextval('qvm_new_apps.email_accounts_account_id_seq'::regclass) NOT NULL,
  "user_id" uuid NOT NULL,
  "email_address" text NOT NULL,
  "secret_id" uuid NOT NULL,
  "display_name" text,
  "imap_host" text DEFAULT 'imap.gmail.com'::text NOT NULL,
  "imap_port" integer DEFAULT 993 NOT NULL,
  "smtp_host" text DEFAULT 'smtp.gmail.com'::text NOT NULL,
  "smtp_port" integer DEFAULT 465 NOT NULL,
  "status" text DEFAULT 'connecting'::text NOT NULL,
  "last_error" text,
  "last_uid" bigint,
  "uid_validity" bigint,
  "last_synced_at" timestamp with time zone,
  "vendors_only" boolean DEFAULT false NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "email_accounts_status_check" CHECK ((status = ANY (ARRAY['connecting'::text, 'connected'::text, 'error'::text, 'disconnected'::text]))),
  CONSTRAINT "email_accounts_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE,
  CONSTRAINT "email_accounts_pkey" PRIMARY KEY (account_id),
  CONSTRAINT "email_accounts_email_address_key" UNIQUE (email_address)
);
ALTER SEQUENCE qvm_new_apps.email_accounts_account_id_seq OWNED BY qvm_new_apps."email_accounts"."account_id";
ALTER TABLE qvm_new_apps."email_accounts" ENABLE ROW LEVEL SECURITY;

-- ===== group_import_requests =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."group_import_requests" (
  "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "source_part_number" text NOT NULL,
  "clean_part_number" text NOT NULL,
  "source_name" text,
  "clean_name" text,
  "qty" integer NOT NULL,
  "target_price" numeric,
  "origin_country" text,
  "payment_terms" text,
  "arrival_weeks" integer,
  "batch_id" bigint,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "group_import_requests_batch_id_fkey" FOREIGN KEY (batch_id) REFERENCES qvm_new_apps.upload_batches(batch_id) ON DELETE SET NULL,
  CONSTRAINT "group_import_requests_pkey" PRIMARY KEY (id)
);
CREATE INDEX IF NOT EXISTS group_import_requests_by_batch ON qvm_new_apps.group_import_requests USING btree (batch_id);
ALTER TABLE qvm_new_apps."group_import_requests" ENABLE ROW LEVEL SECURITY;

-- ===== inventory_stock =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."inventory_stock" (
  "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "vendor_id" integer,
  "vendor_branch_id" bigint,
  "source_part_number" text NOT NULL,
  "clean_part_number" text NOT NULL,
  "source_name" text,
  "clean_name" text,
  "brand" text,
  "part_class" text,
  "country_of_origin" text,
  "quantity" integer,
  "is_available" boolean DEFAULT true NOT NULL,
  "wholesale_price" numeric,
  "retail_price" numeric,
  "before_discount_price" numeric,
  "claimed_agency_price" numeric,
  "claimed_agency_price_after_discount" numeric,
  "dealer_agency_discount_pct" numeric,
  "batch_id" bigint,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "inventory_stock_batch_id_fkey" FOREIGN KEY (batch_id) REFERENCES qvm_new_apps.upload_batches(batch_id) ON DELETE SET NULL,
  CONSTRAINT "inventory_stock_pkey" PRIMARY KEY (id)
);
CREATE UNIQUE INDEX IF NOT EXISTS inventory_stock_natural_key ON qvm_new_apps.inventory_stock USING btree (COALESCE(vendor_id, '-1'::integer), COALESCE(vendor_branch_id, ('-1'::integer)::bigint), clean_part_number);
CREATE INDEX IF NOT EXISTS inventory_stock_by_batch ON qvm_new_apps.inventory_stock USING btree (batch_id);
ALTER TABLE qvm_new_apps."inventory_stock" ENABLE ROW LEVEL SECURITY;

-- ===== part_aliases =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."part_aliases" (
  "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "clean_part_number" text NOT NULL,
  "clean_alias" text NOT NULL,
  "source_part_number" text,
  "source_alias" text,
  "brand" text,
  "note" text,
  "batch_id" bigint,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "part_aliases_not_self" CHECK ((clean_part_number <> clean_alias)),
  CONSTRAINT "part_aliases_batch_id_fkey" FOREIGN KEY (batch_id) REFERENCES qvm_new_apps.upload_batches(batch_id) ON DELETE SET NULL,
  CONSTRAINT "part_aliases_pkey" PRIMARY KEY (id)
);
CREATE UNIQUE INDEX IF NOT EXISTS part_aliases_pair ON qvm_new_apps.part_aliases USING btree (clean_part_number, clean_alias);
CREATE INDEX IF NOT EXISTS part_aliases_by_batch ON qvm_new_apps.part_aliases USING btree (batch_id);
ALTER TABLE qvm_new_apps."part_aliases" ENABLE ROW LEVEL SECURITY;

-- ===== part_name_dictionary =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."part_name_dictionary" (
  "clean_part_number" text NOT NULL,
  "name" text NOT NULL,
  "source" text NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "part_name_dictionary_pkey" PRIMARY KEY (clean_part_number)
);
GRANT SELECT ON qvm_new_apps."part_name_dictionary" TO authenticated;

-- ===== part_offers =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."part_offers" (
  "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "vendor_id" integer,
  "vendor_branch_id" bigint,
  "source_part_number" text NOT NULL,
  "clean_part_number" text NOT NULL,
  "offer_price" numeric NOT NULL,
  "starts_on" date NOT NULL,
  "ends_on" date NOT NULL,
  "qty_limit" integer,
  "batch_id" bigint,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "part_offers_window" CHECK ((ends_on >= starts_on)),
  CONSTRAINT "part_offers_batch_id_fkey" FOREIGN KEY (batch_id) REFERENCES qvm_new_apps.upload_batches(batch_id) ON DELETE SET NULL,
  CONSTRAINT "part_offers_pkey" PRIMARY KEY (id)
);
CREATE INDEX IF NOT EXISTS part_offers_live ON qvm_new_apps.part_offers USING btree (clean_part_number, starts_on, ends_on);
CREATE INDEX IF NOT EXISTS part_offers_by_batch ON qvm_new_apps.part_offers USING btree (batch_id);
ALTER TABLE qvm_new_apps."part_offers" ENABLE ROW LEVEL SECURITY;

-- ===== part_purchase_history =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."part_purchase_history" (
  "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "source_part_number" text NOT NULL,
  "clean_part_number" text NOT NULL,
  "cost" double precision,
  "cost_on" date,
  "source_cost_date" text,
  "supplier_name" text,
  "brand" text,
  "brand_class" text,
  "origin" text DEFAULT 'external_excel'::text NOT NULL,
  "batch_id" bigint,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "part_purchase_history_origin_check" CHECK ((origin = ANY (ARRAY['external_excel'::text, 'internal_erp'::text, 'quoted_not_purchased'::text]))),
  CONSTRAINT "part_purchase_history_pkey" PRIMARY KEY (id)
);
CREATE INDEX IF NOT EXISTS part_purchase_history_by_clean_pn ON qvm_new_apps.part_purchase_history USING btree (clean_part_number);
CREATE INDEX IF NOT EXISTS part_purchase_history_by_date ON qvm_new_apps.part_purchase_history USING btree (cost_on DESC);
CREATE INDEX IF NOT EXISTS part_purchase_history_by_supplier ON qvm_new_apps.part_purchase_history USING btree (supplier_name);
CREATE INDEX IF NOT EXISTS part_purchase_history_by_batch ON qvm_new_apps.part_purchase_history USING btree (batch_id);
ALTER TABLE qvm_new_apps."part_purchase_history" ENABLE ROW LEVEL SECURITY;

-- ===== pricing_modifiers =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."pricing_modifiers" (
  "modifier_key" text NOT NULL,
  "label_en" text NOT NULL,
  "label_ar" text NOT NULL,
  "percent" numeric DEFAULT 0 NOT NULL,
  "is_enabled" boolean DEFAULT false NOT NULL,
  "sort_order" integer DEFAULT 0 NOT NULL,
  "updated_by" uuid,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "pricing_modifiers_pkey" PRIMARY KEY (modifier_key)
);
ALTER TABLE qvm_new_apps."pricing_modifiers" ENABLE ROW LEVEL SECURITY;

-- ===== pricing_policies =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."pricing_policies" (
  "policy_id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "name" text NOT NULL,
  "audience" text DEFAULT 'companies'::text NOT NULL,
  "used_for" text DEFAULT 'quoted'::text NOT NULL,
  "is_contractual" boolean DEFAULT false NOT NULL,
  "is_active" boolean DEFAULT true NOT NULL,
  "sort_order" integer DEFAULT 0 NOT NULL,
  "created_by" uuid,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "pricing_policies_used_for_check" CHECK ((used_for = ANY (ARRAY['quoted'::text, 'sale'::text]))),
  CONSTRAINT "pricing_policies_audience_check" CHECK ((audience = ANY (ARRAY['insurance'::text, 'companies'::text, 'individuals'::text, 'internal_branch'::text]))),
  CONSTRAINT "pricing_policies_pkey" PRIMARY KEY (policy_id)
);
ALTER TABLE qvm_new_apps."pricing_policies" ENABLE ROW LEVEL SECURITY;

-- ===== pricing_policy_customers =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."pricing_policy_customers" (
  "policy_id" bigint NOT NULL,
  "customer_id" bigint NOT NULL,
  "used_for" text NOT NULL,
  CONSTRAINT "pricing_policy_customers_policy_id_fkey" FOREIGN KEY (policy_id) REFERENCES qvm_new_apps.pricing_policies(policy_id) ON DELETE CASCADE,
  CONSTRAINT "pricing_policy_customers_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES qvm_new_apps.customers(customer_id) ON DELETE CASCADE,
  CONSTRAINT "pricing_policy_customers_pkey" PRIMARY KEY (policy_id, customer_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS pricing_policy_one_per_customer_purpose ON qvm_new_apps.pricing_policy_customers USING btree (customer_id, used_for);
ALTER TABLE qvm_new_apps."pricing_policy_customers" ENABLE ROW LEVEL SECURITY;

-- ===== pricing_policy_log =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."pricing_policy_log" (
  "log_id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "policy_id" bigint,
  "entity" text NOT NULL,
  "entity_id" text,
  "action" text NOT NULL,
  "before" jsonb,
  "after" jsonb,
  "changed_by" uuid,
  "changed_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "pricing_policy_log_pkey" PRIMARY KEY (log_id)
);
CREATE INDEX IF NOT EXISTS pricing_policy_log_by_policy ON qvm_new_apps.pricing_policy_log USING btree (policy_id, changed_at DESC);
ALTER TABLE qvm_new_apps."pricing_policy_log" ENABLE ROW LEVEL SECURITY;

-- ===== pricing_price_sources =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."pricing_price_sources" (
  "source_key" text NOT NULL,
  "label_en" text NOT NULL,
  "label_ar" text NOT NULL,
  "origin" text NOT NULL,
  "validity_days" integer DEFAULT 90 NOT NULL,
  "is_active" boolean DEFAULT true NOT NULL,
  "approved_for_policy" boolean DEFAULT false NOT NULL,
  "sort_order" integer DEFAULT 0 NOT NULL,
  "updated_by" uuid,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "pricing_price_sources_origin_check" CHECK ((origin = ANY (ARRAY['mine'::text, 'platform'::text]))),
  CONSTRAINT "pricing_price_sources_pkey" PRIMARY KEY (source_key)
);
ALTER TABLE qvm_new_apps."pricing_price_sources" ENABLE ROW LEVEL SECURITY;

-- ===== pricing_policy_rules =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."pricing_policy_rules" (
  "rule_id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "policy_id" bigint NOT NULL,
  "position" integer DEFAULT 1 NOT NULL,
  "is_general" boolean DEFAULT false NOT NULL,
  "brand_class" integer,
  "part_category" integer,
  "cost_range_id" integer,
  "branch_id" integer,
  "source_key" text,
  "adjust_value" numeric DEFAULT 0 NOT NULL,
  "adjust_unit" text DEFAULT 'percent'::text NOT NULL,
  "auto_fetch" boolean DEFAULT true NOT NULL,
  "auto_send" boolean DEFAULT false NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "pricing_policy_rules_adjust_unit_check" CHECK ((adjust_unit = ANY (ARRAY['percent'::text, 'sar'::text]))),
  CONSTRAINT "pricing_policy_rules_source_key_fkey" FOREIGN KEY (source_key) REFERENCES qvm_new_apps.pricing_price_sources(source_key),
  CONSTRAINT "pricing_policy_rules_policy_id_fkey" FOREIGN KEY (policy_id) REFERENCES qvm_new_apps.pricing_policies(policy_id) ON DELETE CASCADE,
  CONSTRAINT "pricing_policy_rules_cost_range_id_fkey" FOREIGN KEY (cost_range_id) REFERENCES qvm_new_apps.cost_categories(cost_range_id),
  CONSTRAINT "pricing_policy_rules_pkey" PRIMARY KEY (rule_id)
);
CREATE INDEX IF NOT EXISTS pricing_policy_rules_by_policy ON qvm_new_apps.pricing_policy_rules USING btree (policy_id, "position");
CREATE UNIQUE INDEX IF NOT EXISTS pricing_policy_one_general_rule ON qvm_new_apps.pricing_policy_rules USING btree (policy_id) WHERE is_general;
ALTER TABLE qvm_new_apps."pricing_policy_rules" ENABLE ROW LEVEL SECURITY;

-- ===== pricing_route_modifiers =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."pricing_route_modifiers" (
  "route_id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "vendor_branch_id" bigint,
  "to_region_id" integer,
  "percent" numeric DEFAULT 0 NOT NULL,
  "is_enabled" boolean DEFAULT true NOT NULL,
  "is_locked" boolean DEFAULT false NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "pricing_route_modifiers_vendor_branch_id_fkey" FOREIGN KEY (vendor_branch_id) REFERENCES qvm_new_apps.vendor_branches(vendor_branch_id) ON DELETE CASCADE,
  CONSTRAINT "pricing_route_modifiers_pkey" PRIMARY KEY (route_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS pricing_route_one_per_pair ON qvm_new_apps.pricing_route_modifiers USING btree (COALESCE(vendor_branch_id, ('-1'::integer)::bigint), COALESCE(to_region_id, '-1'::integer));
CREATE UNIQUE INDEX IF NOT EXISTS pricing_route_one_baseline ON qvm_new_apps.pricing_route_modifiers USING btree ((true)) WHERE is_locked;
ALTER TABLE qvm_new_apps."pricing_route_modifiers" ENABLE ROW LEVEL SECURITY;

-- ===== pricing_settings =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."pricing_settings" (
  "id" integer DEFAULT 1 NOT NULL,
  "broker_mode" boolean DEFAULT true NOT NULL,
  "modifier_cap_percent" numeric DEFAULT 15 NOT NULL,
  "source_validity_days" integer DEFAULT 90 NOT NULL,
  "floor_on_wholesale" boolean DEFAULT true NOT NULL,
  "updated_by" uuid,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "pricing_settings_id_check" CHECK ((id = 1)),
  CONSTRAINT "pricing_settings_pkey" PRIMARY KEY (id)
);
ALTER TABLE qvm_new_apps."pricing_settings" ENABLE ROW LEVEL SECURITY;

-- ===== quotation_item_alt_pns =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."quotation_item_alt_pns" (
  "alt_pn_id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "quotation_item_id" integer NOT NULL,
  "alt_part_number" text NOT NULL,
  "created_by" uuid,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "quotation_item_alt_pns_quotation_item_id_fkey" FOREIGN KEY (quotation_item_id) REFERENCES qvm_new_apps.quotation_items(quotation_item_id) ON DELETE CASCADE,
  CONSTRAINT "quotation_item_alt_pns_pkey" PRIMARY KEY (alt_pn_id),
  CONSTRAINT "quotation_item_alt_pns_unique" UNIQUE (quotation_item_id, alt_part_number)
);
CREATE INDEX IF NOT EXISTS quotation_item_alt_pns_item_idx ON qvm_new_apps.quotation_item_alt_pns USING btree (quotation_item_id);
GRANT DELETE, INSERT, SELECT, UPDATE ON qvm_new_apps."quotation_item_alt_pns" TO authenticated;
GRANT DELETE, INSERT, SELECT, UPDATE ON qvm_new_apps."quotation_item_alt_pns" TO service_role;

-- ===== quotation_item_extraction_events =====
CREATE SEQUENCE IF NOT EXISTS qvm_new_apps.quotation_item_extraction_events_event_id_seq;
CREATE TABLE IF NOT EXISTS qvm_new_apps."quotation_item_extraction_events" (
  "event_id" bigint DEFAULT nextval('qvm_new_apps.quotation_item_extraction_events_event_id_seq'::regclass) NOT NULL,
  "quotation_item_id" integer NOT NULL,
  "quotation_id" integer,
  "event_type" text NOT NULL,
  "old_value" text,
  "new_value" text,
  "actor" uuid,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "quotation_item_extraction_events_event_type_check" CHECK ((event_type = ANY (ARRAY['pn_draft'::text, 'pn_saved'::text, 'pn_cleared'::text, 'pn_reopened'::text, 'description_amended'::text, 'unclear_raised'::text, 'unclear_resolved'::text, 'item_added'::text, 'item_removed'::text, 'alt_added'::text, 'alt_removed'::text]))),
  CONSTRAINT "quotation_item_extraction_events_pkey" PRIMARY KEY (event_id)
);
ALTER SEQUENCE qvm_new_apps.quotation_item_extraction_events_event_id_seq OWNED BY qvm_new_apps."quotation_item_extraction_events"."event_id";
CREATE INDEX IF NOT EXISTS quotation_item_extraction_events_item_idx ON qvm_new_apps.quotation_item_extraction_events USING btree (quotation_item_id, created_at DESC);
CREATE INDEX IF NOT EXISTS quotation_item_extraction_events_order_idx ON qvm_new_apps.quotation_item_extraction_events USING btree (quotation_id, created_at DESC);
GRANT SELECT ON qvm_new_apps."quotation_item_extraction_events" TO authenticated;
GRANT DELETE, INSERT, SELECT, UPDATE ON qvm_new_apps."quotation_item_extraction_events" TO service_role;

-- ===== stock_auction_items =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."stock_auction_items" (
  "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "vendor_id" integer,
  "vendor_branch_id" bigint,
  "source_part_number" text NOT NULL,
  "clean_part_number" text NOT NULL,
  "source_name" text,
  "clean_name" text,
  "qty" integer NOT NULL,
  "part_class" text,
  "reserve_price" numeric,
  "closes_on" date,
  "batch_id" bigint,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "stock_auction_items_batch_id_fkey" FOREIGN KEY (batch_id) REFERENCES qvm_new_apps.upload_batches(batch_id) ON DELETE SET NULL,
  CONSTRAINT "stock_auction_items_pkey" PRIMARY KEY (id)
);
CREATE INDEX IF NOT EXISTS stock_auction_items_by_batch ON qvm_new_apps.stock_auction_items USING btree (batch_id);
ALTER TABLE qvm_new_apps."stock_auction_items" ENABLE ROW LEVEL SECURITY;

-- ===== upload_batch_log =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."upload_batch_log" (
  "log_id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "batch_id" bigint,
  "action" text NOT NULL,
  "detail" jsonb,
  "changed_by" uuid,
  "changed_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "upload_batch_log_pkey" PRIMARY KEY (log_id)
);
ALTER TABLE qvm_new_apps."upload_batch_log" ENABLE ROW LEVEL SECURITY;

-- ===== upload_code_rules =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."upload_code_rules" (
  "rule_id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "source_kind" text DEFAULT 'vendor'::text NOT NULL,
  "source_id" bigint,
  "source_label" text,
  "code" text NOT NULL,
  "position" text NOT NULL,
  "treatment" text DEFAULT 'strip'::text NOT NULL,
  "brand" text,
  "part_class" text NOT NULL,
  "country_of_origin" text,
  "created_by" uuid,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "upload_code_rules_source_kind_check" CHECK ((source_kind = ANY (ARRAY['vendor'::text, 'agency'::text, 'internal'::text]))),
  CONSTRAINT "upload_code_rules_position_check" CHECK (("position" = ANY (ARRAY['prefix'::text, 'suffix'::text]))),
  CONSTRAINT "upload_code_rules_origin_only_for_non_original" CHECK (((part_class IS DISTINCT FROM 'original'::text) OR (country_of_origin IS NULL))),
  CONSTRAINT "upload_code_rules_treatment_check" CHECK ((treatment = ANY (ARRAY['strip'::text, 'keep'::text]))),
  CONSTRAINT "upload_code_rules_pkey" PRIMARY KEY (rule_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS upload_code_rules_unique_per_source ON qvm_new_apps.upload_code_rules USING btree (source_kind, COALESCE(source_id, ('-1'::integer)::bigint), upper(code), "position");
ALTER TABLE qvm_new_apps."upload_code_rules" ENABLE ROW LEVEL SECURITY;

-- ===== upload_delete_requests =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."upload_delete_requests" (
  "request_id" bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
  "batch_id" bigint NOT NULL,
  "status" text DEFAULT 'pending'::text NOT NULL,
  "reason" text,
  "requested_by" uuid,
  "requested_at" timestamp with time zone DEFAULT now() NOT NULL,
  "decided_by" uuid,
  "decided_at" timestamp with time zone,
  "decision_note" text,
  "rows_removed" integer,
  CONSTRAINT "upload_delete_requests_status_check" CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'rejected'::text]))),
  CONSTRAINT "upload_delete_requests_batch_id_fkey" FOREIGN KEY (batch_id) REFERENCES qvm_new_apps.upload_batches(batch_id) ON DELETE CASCADE,
  CONSTRAINT "upload_delete_requests_pkey" PRIMARY KEY (request_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS upload_delete_requests_one_open_idx ON qvm_new_apps.upload_delete_requests USING btree (batch_id) WHERE (status = 'pending'::text);
ALTER TABLE qvm_new_apps."upload_delete_requests" ENABLE ROW LEVEL SECURITY;

-- ===== upload_jobs =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."upload_jobs" (
  "job_id" bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
  "batch_id" bigint NOT NULL,
  "kind" text DEFAULT 'reprocess'::text NOT NULL,
  "status" text DEFAULT 'queued'::text NOT NULL,
  "requested_by" uuid,
  "requested_at" timestamp with time zone DEFAULT now() NOT NULL,
  "started_at" timestamp with time zone,
  "finished_at" timestamp with time zone,
  "attempts" integer DEFAULT 0 NOT NULL,
  "result" jsonb,
  "error" text,
  CONSTRAINT "upload_jobs_kind_check" CHECK ((kind = 'reprocess'::text)),
  CONSTRAINT "upload_jobs_status_check" CHECK ((status = ANY (ARRAY['queued'::text, 'running'::text, 'done'::text, 'failed'::text]))),
  CONSTRAINT "upload_jobs_batch_id_fkey" FOREIGN KEY (batch_id) REFERENCES qvm_new_apps.upload_batches(batch_id) ON DELETE CASCADE,
  CONSTRAINT "upload_jobs_pkey" PRIMARY KEY (job_id)
);
CREATE INDEX IF NOT EXISTS upload_jobs_pending_idx ON qvm_new_apps.upload_jobs USING btree (status, requested_at) WHERE (status = ANY (ARRAY['queued'::text, 'running'::text]));
CREATE UNIQUE INDEX IF NOT EXISTS upload_jobs_one_live_per_batch_idx ON qvm_new_apps.upload_jobs USING btree (batch_id) WHERE (status = ANY (ARRAY['queued'::text, 'running'::text]));
ALTER TABLE qvm_new_apps."upload_jobs" ENABLE ROW LEVEL SECURITY;

-- ===== upload_rows =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."upload_rows" (
  "row_id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
  "batch_id" bigint NOT NULL,
  "row_number" integer NOT NULL,
  "raw" jsonb NOT NULL,
  "source_part_number" text,
  "clean_part_number" text,
  "source_name" text,
  "clean_name" text,
  "matched_rule_id" bigint,
  "brand" text,
  "part_class" text,
  "country_of_origin" text,
  "state" text DEFAULT 'ready'::text NOT NULL,
  "reason" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "display_part_number" text,
  "edited_at" timestamp with time zone,
  "edited_by" uuid,
  CONSTRAINT "upload_rows_state_check" CHECK ((state = ANY (ARRAY['ready'::text, 'disabled'::text, 'rejected'::text, 'duplicate'::text]))),
  CONSTRAINT "upload_rows_batch_id_fkey" FOREIGN KEY (batch_id) REFERENCES qvm_new_apps.upload_batches(batch_id) ON DELETE CASCADE,
  CONSTRAINT "upload_rows_pkey" PRIMARY KEY (row_id)
);
CREATE INDEX IF NOT EXISTS upload_rows_by_batch ON qvm_new_apps.upload_rows USING btree (batch_id, row_number);
CREATE INDEX IF NOT EXISTS upload_rows_by_state ON qvm_new_apps.upload_rows USING btree (batch_id, state);
ALTER TABLE qvm_new_apps."upload_rows" ENABLE ROW LEVEL SECURITY;

-- ===== wa_contacts =====
CREATE SEQUENCE IF NOT EXISTS qvm_new_apps.wa_contacts_wa_contact_id_seq;
CREATE TABLE IF NOT EXISTS qvm_new_apps."wa_contacts" (
  "wa_contact_id" bigint DEFAULT nextval('qvm_new_apps.wa_contacts_wa_contact_id_seq'::regclass) NOT NULL,
  "phone_e164" text,
  "wa_jid" text,
  "vendor_id" integer,
  "vendor_branch_id" bigint,
  "display_name" text,
  "linked_by" uuid,
  "linked_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "phone_nsn" text,
  "avatar_path" text,
  "avatar_id" text,
  "avatar_checked_at" timestamp with time zone,
  "wa_push_name" text,
  "chat_type" text DEFAULT 'individual'::text NOT NULL,
  "email" text,
  "email_account_id" bigint,
  CONSTRAINT "wa_contacts_email_account_id_fkey" FOREIGN KEY (email_account_id) REFERENCES qvm_new_apps.email_accounts(account_id) ON DELETE CASCADE,
  CONSTRAINT "wa_contacts_pkey" PRIMARY KEY (wa_contact_id),
  CONSTRAINT "wa_contacts_phone_e164_key" UNIQUE (phone_e164),
  CONSTRAINT "wa_contacts_wa_jid_key" UNIQUE (wa_jid)
);
ALTER SEQUENCE qvm_new_apps.wa_contacts_wa_contact_id_seq OWNED BY qvm_new_apps."wa_contacts"."wa_contact_id";
CREATE UNIQUE INDEX IF NOT EXISTS wa_contacts_email_per_account ON qvm_new_apps.wa_contacts USING btree (lower(email), email_account_id) WHERE (email IS NOT NULL);
CREATE INDEX IF NOT EXISTS wa_contacts_vendor ON qvm_new_apps.wa_contacts USING btree (vendor_id);
CREATE INDEX IF NOT EXISTS wa_contacts_nsn ON qvm_new_apps.wa_contacts USING btree (phone_nsn);
ALTER TABLE qvm_new_apps."wa_contacts" ENABLE ROW LEVEL SECURITY;
GRANT INSERT, SELECT, UPDATE ON qvm_new_apps."wa_contacts" TO service_role;

-- ===== wa_device_state =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."wa_device_state" (
  "id" smallint DEFAULT 1 NOT NULL,
  "device_id" text,
  "state" text DEFAULT 'disconnected'::text NOT NULL,
  "jid" text,
  "phone" text,
  "qr_png" text,
  "qr_expires_at" timestamp with time zone,
  "pair_requested_at" timestamp with time zone,
  "connected_at" timestamp with time zone,
  "last_seen_at" timestamp with time zone,
  "last_error" text,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "wa_device_state_id_check" CHECK ((id = 1)),
  CONSTRAINT "wa_device_state_pkey" PRIMARY KEY (id)
);
ALTER TABLE qvm_new_apps."wa_device_state" ENABLE ROW LEVEL SECURITY;
GRANT INSERT, SELECT, UPDATE ON qvm_new_apps."wa_device_state" TO service_role;

-- ===== wa_threads =====
CREATE SEQUENCE IF NOT EXISTS qvm_new_apps.wa_threads_thread_id_seq;
CREATE TABLE IF NOT EXISTS qvm_new_apps."wa_threads" (
  "thread_id" bigint DEFAULT nextval('qvm_new_apps.wa_threads_thread_id_seq'::regclass) NOT NULL,
  "wa_contact_id" bigint NOT NULL,
  "quotation_id" integer,
  "assigned_to" uuid,
  "status" text DEFAULT 'open'::text NOT NULL,
  "unread_count" integer DEFAULT 0 NOT NULL,
  "last_message_at" timestamp with time zone,
  "last_message_preview" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "last_inbound_at" timestamp with time zone,
  "typing_until" timestamp with time zone,
  "deleted_at" timestamp with time zone,
  "deleted_by" uuid,
  "channel" text DEFAULT 'whatsapp'::text NOT NULL,
  "email_account_id" bigint,
  "subject" text,
  "email_conversation_key" text,
  CONSTRAINT "wa_threads_channel_check" CHECK ((channel = ANY (ARRAY['whatsapp'::text, 'email'::text]))),
  CONSTRAINT "wa_threads_email_account_id_fkey" FOREIGN KEY (email_account_id) REFERENCES qvm_new_apps.email_accounts(account_id) ON DELETE CASCADE,
  CONSTRAINT "wa_threads_wa_contact_id_fkey" FOREIGN KEY (wa_contact_id) REFERENCES qvm_new_apps.wa_contacts(wa_contact_id) ON DELETE CASCADE,
  CONSTRAINT "wa_threads_pkey" PRIMARY KEY (thread_id)
);
ALTER SEQUENCE qvm_new_apps.wa_threads_thread_id_seq OWNED BY qvm_new_apps."wa_threads"."thread_id";
CREATE INDEX IF NOT EXISTS wa_threads_channel_idx ON qvm_new_apps.wa_threads USING btree (channel, last_message_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS wa_threads_whatsapp_one_per_contact ON qvm_new_apps.wa_threads USING btree (wa_contact_id) WHERE (channel = 'whatsapp'::text);
CREATE INDEX IF NOT EXISTS wa_threads_last_msg ON qvm_new_apps.wa_threads USING btree (last_message_at DESC NULLS LAST);
CREATE UNIQUE INDEX IF NOT EXISTS wa_threads_email_one_per_conversation ON qvm_new_apps.wa_threads USING btree (wa_contact_id, email_conversation_key) WHERE (channel = 'email'::text);
ALTER TABLE qvm_new_apps."wa_threads" ENABLE ROW LEVEL SECURITY;
GRANT INSERT, SELECT, UPDATE ON qvm_new_apps."wa_threads" TO service_role;

-- ===== wa_messages =====
CREATE SEQUENCE IF NOT EXISTS qvm_new_apps.wa_messages_message_id_seq;
CREATE TABLE IF NOT EXISTS qvm_new_apps."wa_messages" (
  "message_id" bigint DEFAULT nextval('qvm_new_apps.wa_messages_message_id_seq'::regclass) NOT NULL,
  "thread_id" bigint NOT NULL,
  "wa_message_id" text,
  "direction" text NOT NULL,
  "body" text,
  "media_url" text,
  "media_mime" text,
  "sender_jid" text,
  "sent_by" uuid,
  "is_internal_note" boolean DEFAULT false NOT NULL,
  "wa_timestamp" timestamp with time zone DEFAULT now() NOT NULL,
  "delivery_status" text,
  "raw" jsonb,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "failed_reason" text,
  "media_kind" text,
  "media_name" text,
  "sender_name" text,
  "is_system" boolean DEFAULT false NOT NULL,
  "deleted_at" timestamp with time zone,
  "deleted_by" uuid,
  "revoked_on_whatsapp" boolean DEFAULT false NOT NULL,
  "reply_to_message_id" bigint,
  "reply_to_wa_id" text,
  "email_headers" jsonb,
  "email_html_path" text,
  CONSTRAINT "wa_messages_direction_check" CHECK ((direction = ANY (ARRAY['in'::text, 'out'::text]))),
  CONSTRAINT "wa_messages_thread_id_fkey" FOREIGN KEY (thread_id) REFERENCES qvm_new_apps.wa_threads(thread_id) ON DELETE CASCADE,
  CONSTRAINT "wa_messages_pkey" PRIMARY KEY (message_id)
);
ALTER SEQUENCE qvm_new_apps.wa_messages_message_id_seq OWNED BY qvm_new_apps."wa_messages"."message_id";
CREATE UNIQUE INDEX IF NOT EXISTS wa_messages_waid_uniq ON qvm_new_apps.wa_messages USING btree (wa_message_id) WHERE (wa_message_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS wa_messages_thread_time ON qvm_new_apps.wa_messages USING btree (thread_id, wa_timestamp DESC);
CREATE INDEX IF NOT EXISTS wa_messages_reply_to ON qvm_new_apps.wa_messages USING btree (reply_to_message_id);
ALTER TABLE qvm_new_apps."wa_messages" ENABLE ROW LEVEL SECURITY;
GRANT INSERT, SELECT, UPDATE ON qvm_new_apps."wa_messages" TO service_role;

-- ===== wa_outbox =====
CREATE SEQUENCE IF NOT EXISTS qvm_new_apps.wa_outbox_outbox_id_seq;
CREATE TABLE IF NOT EXISTS qvm_new_apps."wa_outbox" (
  "outbox_id" bigint DEFAULT nextval('qvm_new_apps.wa_outbox_outbox_id_seq'::regclass) NOT NULL,
  "message_id" bigint NOT NULL,
  "thread_id" bigint NOT NULL,
  "to_phone" text,
  "body" text,
  "media_url" text,
  "media_mime" text,
  "status" text DEFAULT 'queued'::text NOT NULL,
  "attempts" integer DEFAULT 0 NOT NULL,
  "next_attempt_at" timestamp with time zone DEFAULT now() NOT NULL,
  "last_error" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "media_kind" text,
  "media_name" text,
  "kind" text DEFAULT 'send'::text NOT NULL,
  "target_wa_message_id" text,
  "reply_to_wa_id" text,
  "to_email" text,
  "channel" text DEFAULT 'whatsapp'::text NOT NULL,
  "subject" text,
  "email_account_id" bigint,
  CONSTRAINT "wa_outbox_channel_check" CHECK ((channel = ANY (ARRAY['whatsapp'::text, 'email'::text]))),
  CONSTRAINT "wa_outbox_addressable" CHECK ((((channel = 'whatsapp'::text) AND (to_phone IS NOT NULL)) OR ((channel = 'email'::text) AND (to_email IS NOT NULL) AND (email_account_id IS NOT NULL)))),
  CONSTRAINT "wa_outbox_thread_id_fkey" FOREIGN KEY (thread_id) REFERENCES qvm_new_apps.wa_threads(thread_id) ON DELETE CASCADE,
  CONSTRAINT "wa_outbox_email_account_id_fkey" FOREIGN KEY (email_account_id) REFERENCES qvm_new_apps.email_accounts(account_id) ON DELETE CASCADE,
  CONSTRAINT "wa_outbox_message_id_fkey" FOREIGN KEY (message_id) REFERENCES qvm_new_apps.wa_messages(message_id) ON DELETE CASCADE,
  CONSTRAINT "wa_outbox_pkey" PRIMARY KEY (outbox_id),
  CONSTRAINT "wa_outbox_message_id_key" UNIQUE (message_id)
);
ALTER SEQUENCE qvm_new_apps.wa_outbox_outbox_id_seq OWNED BY qvm_new_apps."wa_outbox"."outbox_id";
CREATE INDEX IF NOT EXISTS wa_outbox_pending ON qvm_new_apps.wa_outbox USING btree (next_attempt_at) WHERE (status = 'queued'::text);
CREATE INDEX IF NOT EXISTS wa_outbox_thread ON qvm_new_apps.wa_outbox USING btree (thread_id);
ALTER TABLE qvm_new_apps."wa_outbox" ENABLE ROW LEVEL SECURITY;
GRANT INSERT, SELECT, UPDATE ON qvm_new_apps."wa_outbox" TO service_role;

-- ===== wa_settings =====
CREATE TABLE IF NOT EXISTS qvm_new_apps."wa_settings" (
  "key" text NOT NULL,
  "value" text,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "wa_settings_pkey" PRIMARY KEY (key)
);
ALTER TABLE qvm_new_apps."wa_settings" ENABLE ROW LEVEL SECURITY;
GRANT INSERT, SELECT, UPDATE ON qvm_new_apps."wa_settings" TO service_role;
