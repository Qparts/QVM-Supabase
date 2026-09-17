-- A vendor can upload an agency price list and could not see one.
--
-- uploaded_records_get returns an empty page to any non-team caller asking for anything other
-- than stock — so a vendor who uploaded a price list watched it vanish. The upload wizard offers
-- them the agency template, the rows are written under their vendor id and their branch, and the
-- one screen that would show them what they had sent said there was nothing there.
--
-- What changes is only who may READ, and only their own rows: the agency branch gains the same
-- vendor filter the stock branch has always had. A vendor still cannot see another vendor\'s
-- prices, and still cannot see past purchases — that is the workshop\'s buying history, not
-- theirs, and it is not a gap.
--
-- The counter moves with the listing on purpose. A tab that advertises twenty rows and opens on
-- one is worse than a tab that says one, because the first reading a person takes from it is
-- that the page is broken.
do $do$
declare
  v_def text := pg_get_functiondef(
    'qvm_new_apps.uploaded_records_get(text,text,text,integer,integer,integer)'::regprocedure);
  v_hits integer;

  -- 1 · the blanket refusal becomes a narrower one
  v_gate_old text := '  if not v_team and p_kind <> ''stock'' then';
  v_gate_new text := '  -- A vendor reads their own stock and their own agency prices, and nothing else.
  if not v_team and p_kind not in (''stock'', ''agency'') then';

  -- 2 · the agency listing is filtered the way the stock listing already is
  v_where_old text := '         where (v_q is null or a.clean_part_number ilike ''%''||v_q||''%''';
  v_where_new text := '         where (v_team or a.vendor_id = v_vendor)
           and (v_q is null or a.clean_part_number ilike ''%''||v_q||''%''';

  -- 3 · and so is the tab counter
  v_count_old text := '      ''agency'',    case when v_team then (select count(*) from qvm_new_apps.agency_price_reference) else 0 end,';
  v_count_new text := '      ''agency'',    (select count(*) from qvm_new_apps.agency_price_reference a
                      where v_team or a.vendor_id = v_vendor),';
begin
  v_hits := (length(v_def) - length(replace(v_def, v_gate_old, ''))) / greatest(length(v_gate_old), 1);
  if v_hits <> 1 then raise exception 'the vendor gate is not where this expects it (% hits)', v_hits; end if;
  v_def := replace(v_def, v_gate_old, v_gate_new);

  v_hits := (length(v_def) - length(replace(v_def, v_where_old, ''))) / greatest(length(v_where_old), 1);
  if v_hits <> 1 then raise exception 'the agency filter is not where this expects it (% hits)', v_hits; end if;
  v_def := replace(v_def, v_where_old, v_where_new);

  v_hits := (length(v_def) - length(replace(v_def, v_count_old, ''))) / greatest(length(v_count_old), 1);
  if v_hits <> 1 then raise exception 'the agency counter is not where this expects it (% hits)', v_hits; end if;
  v_def := replace(v_def, v_count_old, v_count_new);

  execute v_def;
end
$do$;
