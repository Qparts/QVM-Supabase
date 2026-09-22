-- A plan says its three headline numbers in one line.
--
-- The sheet compares everything; the card underneath it has to say what the plan *is* in one
-- glance — «رقم واحد · 2 GB تخزين · 3,000 رسالة / شهر». That is not the table's label with the
-- value stuck to it: «الأرقام المتصلة: 1» is a cell, not a sentence.
--
-- So a metric may carry `hl`, the phrasing for that one line, per language, with {v} standing in
-- for the formatted value. Arabic counts in three forms and English in two, which is why this is a
-- small object and not a string: «رقم واحد», «3 أرقام», «11 رقم» are the same fact three ways, and
-- picking between them is the data's job, not a plural rule guessed in the page.
--
-- `one` is used for exactly 1, `few` for 3–10 (Arabic's plural of paucity), `other` for the rest.
-- A metric with no `hl` simply stays out of the line — three numbers is a summary, nine is the
-- table again.
update qvm_new_apps.integration_services
   set metrics = (
     select jsonb_agg(
       case m->>'key'
         when 'numbers' then m || '{"hl":{
           "ar":{"one":"رقم واحد","few":"{v} أرقام","other":"{v} رقم"},
           "en":{"one":"1 number","other":"{v} numbers"}}}'::jsonb
         when 'storage_gb' then m || '{"hl":{
           "ar":{"other":"{v} تخزين"},
           "en":{"other":"{v} storage"}}}'::jsonb
         when 'messages_month' then m || '{"hl":{
           "ar":{"other":"{v} رسالة / شهر"},
           "en":{"other":"{v} messages / month"}}}'::jsonb
         else m
       end
       order by ord)
     from jsonb_array_elements(metrics) with ordinality as e(m, ord))
 where service_key = 'whatsapp';

update qvm_new_apps.integration_services
   set metrics = (
     select jsonb_agg(
       case m->>'key'
         when 'mailboxes' then m || '{"hl":{
           "ar":{"one":"صندوق بريد واحد","few":"{v} صناديق بريد","other":"{v} صندوق بريد"},
           "en":{"one":"1 mailbox","other":"{v} mailboxes"}}}'::jsonb
         when 'storage_gb' then m || '{"hl":{
           "ar":{"other":"{v} تخزين"},
           "en":{"other":"{v} storage"}}}'::jsonb
         when 'messages_month' then m || '{"hl":{
           "ar":{"other":"{v} رسالة / شهر"},
           "en":{"other":"{v} messages / month"}}}'::jsonb
         else m
       end
       order by ord)
     from jsonb_array_elements(metrics) with ordinality as e(m, ord))
 where service_key = 'email';

update qvm_new_apps.integration_services
   set metrics = (
     select jsonb_agg(
       case m->>'key'
         when 'lookups_month' then m || '{"hl":{
           "ar":{"other":"{v} عملية / شهر"},
           "en":{"other":"{v} lookups / month"}}}'::jsonb
         else m
       end
       order by ord)
     from jsonb_array_elements(metrics) with ordinality as e(m, ord))
 where service_key = 'part_number';

update qvm_new_apps.integration_services
   set metrics = (
     select jsonb_agg(
       case m->>'key'
         when 'credit_month' then m || '{"hl":{
           "ar":{"other":"{v} رصيد / شهر"},
           "en":{"other":"{v} credit / month"}}}'::jsonb
         else m
       end
       order by ord)
     from jsonb_array_elements(metrics) with ordinality as e(m, ord))
 where service_key = 'ai';
