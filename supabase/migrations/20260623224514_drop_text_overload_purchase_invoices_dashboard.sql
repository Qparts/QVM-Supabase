-- Synced from QVM/test branch applied migration history (version 20260623224514, name: drop_text_overload_purchase_invoices_dashboard)

DROP FUNCTION IF EXISTS public.get_purchase_invoices_dashboard(text, boolean, text, boolean, boolean, text, integer[], integer[], integer, integer);
;
