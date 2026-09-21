-- A service carries its logo the way it carries its price.
--
-- The cards drew two letters on a coloured square. That reads as a placeholder because it is one —
-- and the fix is not to hard-code seven <img> tags in the component, which would put the one thing
-- that changes most often (a brand refresh, a new service) back inside a rebuild.
--
-- logo_url is a path under /assets/integrations. Null keeps the lettered tile, so a service with
-- no artwork still draws something rather than a broken image.
alter table qvm_new_apps.integration_services
  add column if not exists logo_url text;

comment on column qvm_new_apps.integration_services.logo_url is
  'Path to the mark, served from /assets/integrations. Null falls back to the lettered tile — a '
  'service without artwork should still draw something.';

-- Filled in for the five that can be: WhatsApp's glyph is its own published mark, and the other
-- four are ours to draw.
--
-- Deliberately left null: Mrsool and SMSA. Those are other companies' trademarks and I do not
-- have their files; inventing something close would be worse than a letter, because a wrong logo
-- looks right. Dropping mrsool.svg and smsa.svg into the same folder and setting these two rows
-- is all that is needed — no code change, no deploy of the component.
update qvm_new_apps.integration_services set logo_url = '/assets/integrations/whatsapp.svg'
 where service_key = 'whatsapp';
update qvm_new_apps.integration_services set logo_url = '/assets/integrations/email.svg'
 where service_key = 'email';
update qvm_new_apps.integration_services set logo_url = '/assets/integrations/ai.svg'
 where service_key = 'ai';
update qvm_new_apps.integration_services set logo_url = '/assets/integrations/part-number.svg'
 where service_key = 'part_number';
update qvm_new_apps.integration_services set logo_url = '/assets/integrations/logisticsco.svg'
 where service_key = 'logisticsco';

-- WhatsApp's tile takes its own green rather than the generic one, since the mark now carries the
-- brand and a mismatched square around it is the kind of detail that makes a page look assembled.
update qvm_new_apps.integration_services set accent = '#25D366' where service_key = 'whatsapp';

-- And the read hands it to the page.
do $do$
declare
  v_def  text := pg_get_functiondef('qvm_new_apps.integrations_market(integer)'::regprocedure);
  v_old  text := '    ''badge'', s.badge, ''accent'', s.accent,';
  v_new  text := '    ''badge'', s.badge, ''accent'', s.accent, ''logo_url'', s.logo_url,';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'integrations_market: expected the badge line once, found %', v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$do$;
