-- The client-side return reasons are reasons.
--
-- List 23 (return_reasons_client_side) carried three order statuses pasted in by mistake — «Ready
-- For Quotation», «Extract PN», «Sent To Vendor» — beside five real reasons. The three rows are
-- referenced by a handful of returns, so they are renamed into real reasons rather than deleted,
-- and three more reasons a workshop actually gives are added. The list after this:
--
--   Wrong Item Received · Wrong Part Number · Damaged in Transit · Not as Described ·
--   Wrong Quantity · Defective Item · Pricing Issue · Delay · No Longer Needed ·
--   Duplicate Order · Other

set search_path to qvm_new_apps, public;

update qvm_new_apps.list_data set list_data = 'Wrong Item Received', updated_at = now()
 where list_id = 23 and list_data_id = 216 and list_data = 'Ready For Quotation';
update qvm_new_apps.list_data set list_data = 'Damaged in Transit', updated_at = now()
 where list_id = 23 and list_data_id = 217 and list_data = 'Extract PN';
update qvm_new_apps.list_data set list_data = 'Not as Described', updated_at = now()
 where list_id = 23 and list_data_id = 218 and list_data = 'Sent To Vendor';

insert into qvm_new_apps.list_data (list_id, list_data)
select 23, r.name
  from (values ('Wrong Part Number'), ('No Longer Needed'), ('Duplicate Order')) as r(name)
 where not exists (select 1 from qvm_new_apps.list_data ld where ld.list_id = 23 and ld.list_data = r.name);
