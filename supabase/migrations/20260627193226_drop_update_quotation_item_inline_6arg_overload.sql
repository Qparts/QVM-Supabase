-- Synced from QVM/test branch applied migration history (version 20260627193226, name: drop_update_quotation_item_inline_6arg_overload)
DROP FUNCTION IF EXISTS public.update_quotation_item_inline(
  integer,
  text,
  text,
  text,
  integer,
  integer
);

-- Ensure the 5-argument version remains with the correct permissions
GRANT EXECUTE ON FUNCTION public.update_quotation_item_inline(integer, text, text, text, integer) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.update_quotation_item_inline(integer, text, text, text, integer) FROM public, anon;
;
