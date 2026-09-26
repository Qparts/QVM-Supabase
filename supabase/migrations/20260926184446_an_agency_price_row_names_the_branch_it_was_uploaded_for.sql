-- An agency price row names the branch it was actually uploaded for.
--
-- Uploading one price list against three branches writes three rows — one per branch, which is
-- correct: the same part can be priced differently per site, and that is the whole reason the
-- upload asks which branches. The screen then drew three rows identical in every visible column,
-- so it read as the same line pasted three times and the first question was «why is my file
-- duplicating».
--
-- It was not duplicating. The branch was simply never shown, because both agency reads join
-- `vendor_branches` on `a.vendor_branch_id` — and the upload fills `client_branch_id`. That
-- column is null on every one of these rows, so `branch` came back null every time.
--
-- Two different branch columns on one table is the kind of thing that only hurts at the join.
-- `vendor_branch_id` is the supplier's own depot; `client_branch_id` is the customer site the
-- price applies to. Both are real, and the agency reader wanted the second.
--
-- The stock block further down opens identically and genuinely means the depot; it is told apart
-- by the `'city'` it also carries. The first attempt at this patch matched both, and the
-- assertion stopped it rather than quietly editing the wrong one.
--
-- `client_branches` is keyed by `customer_id`, not by `list_data_id` — the same trap that once
-- collapsed three branches onto one row elsewhere in this codebase.
do $do$
declare
  v_def  text := pg_get_functiondef('qvm_new_apps.uploaded_records_get(text,text,text,integer,integer,integer)'::regprocedure);
  v_old  text;
  v_new  text;
  v_hits integer;
begin
  -- 1) the catalogue tree's agency children
  v_old := '                                ''branch'', vb.branch_name,';
  v_new := '                                -- The customer site this price was uploaded for, not the
                                -- supplier depot. Falls back to the depot for rows written the
                                -- other way round.
                                ''branch'', coalesce(cbr.branch_name, vb.branch_name),';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'uploaded_records_get: tree branch line found % times', v_hits;
  end if;
  v_def := replace(v_def, v_old, v_new);

  v_old := '                         left join qvm_new_apps.vendor_branches vb
                                on vb.vendor_branch_id = a.vendor_branch_id';
  v_new := '                         left join qvm_new_apps.vendor_branches vb
                                on vb.vendor_branch_id = a.vendor_branch_id
                         left join qvm_new_apps.client_branches cbr
                                on cbr.customer_id = a.client_branch_id';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'uploaded_records_get: tree join found % times', v_hits;
  end if;
  v_def := replace(v_def, v_old, v_new);

  -- 2) the agency tab. Ends at the comma — the stock line continues with ''city''.
  v_old := '                     ''vendor'', v.vendor_name, ''branch'', vb.branch_name,
';
  v_new := '                     ''vendor'', v.vendor_name,
                     ''branch'', coalesce(cbr.branch_name, vb.branch_name),
                     -- Carried beside the name so two branches sharing one can still be told
                     -- apart, and so the screen has something stable to group by.
                     ''client_branch_id'', a.client_branch_id,
';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'uploaded_records_get: tab branch line found % times', v_hits;
  end if;
  v_def := replace(v_def, v_old, v_new);

  v_old := '              left join qvm_new_apps.vendor_branches vb on vb.vendor_branch_id = a.vendor_branch_id';
  v_new := '              left join qvm_new_apps.vendor_branches vb on vb.vendor_branch_id = a.vendor_branch_id
              left join qvm_new_apps.client_branches cbr on cbr.customer_id = a.client_branch_id';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'uploaded_records_get: tab join found % times', v_hits;
  end if;

  execute replace(v_def, v_old, v_new);
end
$do$;
