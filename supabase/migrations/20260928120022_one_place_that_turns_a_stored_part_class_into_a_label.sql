-- The seven classes, named once.
--
-- The report had its own four-way mapping, the records screen has another, and the upload
-- templates have a third. Three spellings of one list is how «Remanufactured» came to be reported
-- as «Commercial»: not a bug anybody wrote, just a list that was copied before it was finished.
--
-- Unknown is a real answer. Most catalogue rows have no class — it arrives from a file that states
-- one, and most files do not. Folding those into any of the seven would have the report assert
-- something about every one of them that nobody has said.

create or replace function qvm_new_apps.part_class_label(p_class text)
returns text
language sql
immutable
as $fn$
  select case lower(btrim(coalesce(p_class, '')))
           when 'genuine'         then 'Original'
           when 'أصلي'            then 'Original'
           when 'original'        then 'Original'
           when 'oem'             then 'OEM'
           when 'commercial'      then 'Commercial'
           when 'aftermarket'     then 'Commercial'
           when 'aftermarket_a'   then 'Aftermarket A'
           when 'aftermarket_b'   then 'Aftermarket B'
           when 'used'            then 'Used'
           when 'مستعمل'          then 'Used'
           when 'remanufactured'  then 'Remanufactured'
           when ''                then 'Unknown'
           -- A class that arrived spelled in a way nobody has taught this function is still a
           -- class somebody wrote down. Passing it through shows it; mapping it to Commercial
           -- would hide the fact that the cleanup has a gap.
           else btrim(p_class)
         end;
$fn$;
