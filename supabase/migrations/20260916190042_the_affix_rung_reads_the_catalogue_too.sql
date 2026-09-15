-- part_name_approx looked for a stripped supplier affix in part_name_dictionary alone.
--
-- That dictionary is derived from quotation history, so a part the catalogue knows by name and
-- nobody has ever quoted was invisible to the rung built to find exactly such parts. The sample
-- file that exposed this had «12372-0T370-Q» in it: strip the supplier's -Q and the base number
-- is in parts_catalog under «كرسي مكينة أيسر» — and the lookup returned nothing, because it was
-- reading the one table that did not have it. Twenty-one rows of that file sat held for want of
-- a one-letter suffix.
--
-- One union, no new logic: the same affix test, now also against the catalogue's own names. The
-- answer is still marked a guess, because a suffix nobody has explained is still a guess.
--
-- Known limit, stated rather than discovered later: this rung cannot use an index — it asks
-- whether a stored number is a prefix or suffix of the incoming one — so it scans. It scanned
-- before this change too; the set it scans is now roughly twice as large. At catalogue sizes in
-- the hundreds of thousands this wants a proper affix index, not a wider scan.
do $do$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.part_name_approx(text)'::regprocedure);
  v_old text := '  select d.name, d.clean_part_number as matched, ''affix'' as via
    into v_hit
    from qvm_new_apps.part_name_dictionary d
   where length(d.clean_part_number) >= 5';
  v_new text := '  select k.name, k.clean_part_number as matched, ''affix'' as via
    into v_hit
    from (
      -- Both places a name can live: the quotation-derived dictionary, and the catalogue, which
      -- is the one that actually holds curated names for parts nobody has quoted yet.
      select d.clean_part_number, d.name from qvm_new_apps.part_name_dictionary d
      union all
      select c.clean_part_number, c.clean_name_ar from qvm_new_apps.parts_catalog c
       where c.clean_name_ar is not null
    ) k(clean_part_number, name)
   where length(k.clean_part_number) >= 5';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'part_name_approx: expected the affix rung exactly once, found %', v_hits;
  end if;
  v_def := replace(v_def, v_old, v_new);
  -- The rest of the rung still names d; it now reads from k.
  v_def := replace(v_def, 'and length(p_clean_pn) - length(d.clean_part_number) between 1 and 4',
                          'and length(p_clean_pn) - length(k.clean_part_number) between 1 and 4');
  v_def := replace(v_def, '(p_clean_pn like ''%'' || d.clean_part_number or p_clean_pn like d.clean_part_number || ''%'')',
                          '(p_clean_pn like ''%'' || k.clean_part_number or p_clean_pn like k.clean_part_number || ''%'')');
  v_def := replace(v_def, 'replace(replace(p_clean_pn, d.clean_part_number, ''''), '' '', '''')',
                          'replace(replace(p_clean_pn, k.clean_part_number, ''''), '' '', '''')');
  v_def := replace(v_def, 'order by length(d.clean_part_number) desc',
                          'order by length(k.clean_part_number) desc');
  execute v_def;
end
$do$;
