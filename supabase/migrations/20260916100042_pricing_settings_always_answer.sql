-- The pricing policies page is a white screen, and the reason is a table with no rows in it.
--
--   Uncaught TypeError: Cannot read properties of null (reading 'source_validity_days')
--       at ExtraLayerSection (ExtraLayerSection.tsx:63)
--
-- pricing_settings is a singleton — one row, id 1, holding broker mode, the layer-2 cap, the
-- source validity window and the wholesale floor. Every column has a sensible default. What it
-- has never had is the row itself, and pricing_policies_get reads it with `where s.id = 1`, so on
-- a database where nobody has saved yet it returns settings: null and the screen dies on the
-- first field it touches.
--
-- It is a deadlock, not just a crash: the row is created by saving layer 2, and the save button
-- is on the page that cannot render. Nothing a person does in the UI can ever get out of it.
--
-- Fixed on both sides, because either alone leaves the trap armed:
--   ① the row exists from now on;
--   ② the reader answers with defaults even if it does not, so an empty table can never again
--      turn into a blank page. A settings object is not optional to the screen, so the server
--      should never hand it a null.

insert into qvm_new_apps.pricing_settings (id) values (1)
on conflict (id) do nothing;

do $patch$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.pricing_policies_get()'::regprocedure);
  v_new text;
begin
  v_new := replace(v_def,
    $old$    'settings', (select to_jsonb(s) from qvm_new_apps.pricing_settings s where s.id = 1),$old$,
    $new$    -- coalesce, not a bare select: the screen treats settings as always present, and the
    -- one time it was not it white-screened on the first property read. The fallback mirrors the
    -- column defaults, so an empty table reads exactly like a freshly seeded one.
    'settings', coalesce(
      (select to_jsonb(s) from qvm_new_apps.pricing_settings s where s.id = 1),
      jsonb_build_object(
        'id', 1, 'broker_mode', true, 'modifier_cap_percent', 15,
        'source_validity_days', 90, 'floor_on_wholesale', true,
        'updated_by', null, 'updated_at', now())),$new$);
  if v_new = v_def then
    raise exception 'pricing_policies_get: the settings block was not found';
  end if;
  execute v_new;
end
$patch$;
