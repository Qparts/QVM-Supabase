-- Synced from QVM/test branch applied migration history (version 20260627232517, name: drop_overloaded_add_rfq_item_inline)
BEGIN;

DROP FUNCTION IF EXISTS public.add_rfq_item_inline(
  p_quotation_id integer,
  p_customer_id integer,
  p_part_number text,
  p_part_description text,
  p_quantity integer,
  p_brand_class integer,
  p_main_brand integer,
  p_model text,
  p_year text,
  p_part_photo text,
  p_initial_note text,
  p_is_internal_note boolean
);

COMMIT;
;
