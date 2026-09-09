-- One row per column of the file, not one per alias that happens to share its name.
--
-- Seeding an alias for every template key gave «description» two of them: one pointing at
-- name_ar, and one pointing at a column literally called `description` on a different template.
-- The plain join then listed the file's Description column twice, each row offering a different
-- meaning and each with its own dropdown — so the screen asked the same question twice and
-- whichever answer was saved last silently won.
--
-- The alias lookup now picks a single row, and only considers aliases pointing at a column this
-- template actually has: an alias for a field that does not exist here cannot be the answer.

do $mig$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.upload_batch_columns(bigint)'::regprocedure);
  v_old text := '    left join qvm_new_apps.upload_column_aliases a
           on a.norm_alias = qvm_new_apps.norm_text(s.header)';
  v_new text := '    -- One row, chosen here rather than left to the join. Seeding an alias for every
    -- template key made «description» an alias twice over — once for name_ar and once for a
    -- column of that name on another template — and a plain join then listed the file''s
    -- Description column twice, each offering a different meaning.
    left join lateral (
      select al.target_key
        from qvm_new_apps.upload_column_aliases al
       where al.norm_alias = qvm_new_apps.norm_text(s.header)
         -- An alias pointing at a column this template does not have means nothing here.
         and exists (select 1 from qvm_new_apps.upload_templates t2,
                          lateral jsonb_array_elements(t2.columns) c2
                      where t2.template_key = v_b.template_key and c2->>''key'' = al.target_key)
       order by (al.target_key = qvm_new_apps.norm_text(s.header)) desc, al.target_key
       limit 1
    ) a on true';
begin
  if position('One row, chosen here' in v_def) > 0 then return; end if;
  if position(v_old in v_def) = 0 then raise exception 'alias join not matched'; end if;
  execute replace(v_def, v_old, v_new);
end
$mig$;
