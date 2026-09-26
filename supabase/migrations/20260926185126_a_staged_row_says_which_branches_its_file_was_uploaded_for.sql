-- A staged row says which branches its file was uploaded for.
--
-- The upload asks which branches a price list applies to and stores the answer on the batch —
-- `branch_scope` and `branch_ids`. Nothing downstream showed it, so the rows-from-every-file
-- table listed a part four times with no way to tell what made the copies different, and the
-- prices table listed three identical lines for the same reason.
--
-- The branches belong to the file, not to the row, so they are read from the batch and repeated
-- onto each of its rows. That is a small amount of duplication in the payload and the
-- alternative is a second request per file just to label a column.
--
-- Names, not ids. «121, 133, 122» is not an answer anybody can act on.
do $do$
declare
  v_def  text := pg_get_functiondef('qvm_new_apps.upload_rows_across_files(text,text,text,integer,integer)'::regprocedure);
  v_old  text := '               ''batch_id'', r.batch_id, ''file_name'', r.file_name,';
  v_new  text := '               ''batch_id'', r.batch_id, ''file_name'', r.file_name,
               -- Which sites this file was uploaded against. ''all'' is a real answer and is
               -- not the same as «nobody chose» — an empty list on a specific scope is.
               ''branch_scope'', r.branch_scope,
               ''branches'', r.branches,';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'upload_rows_across_files: batch_id line found % times', v_hits;
  end if;
  v_def := replace(v_def, v_old, v_new);

  -- carried down from the batch, beside the file name it already reads
  v_old := '                 b.file_name, b.created_at as file_created_at';
  v_new := '                 b.file_name, b.created_at as file_created_at,
                 b.branch_scope,
                 -- `client_branches` is keyed by customer_id, not list_data_id.
                 (select coalesce(jsonb_agg(jsonb_build_object(
                           ''id'', cb.customer_id, ''name'', cb.branch_name)
                         order by cb.branch_name), ''[]''::jsonb)
                    from qvm_new_apps.client_branches cb
                   where cb.customer_id = any(coalesce(b.branch_ids, ''{}''::integer[]))) as branches';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'upload_rows_across_files: batch select found % times', v_hits;
  end if;

  execute replace(v_def, v_old, v_new);
end
$do$;
