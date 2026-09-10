-- The length of a cleaned part number is itself a verdict.
--
-- Reading the file that is loaded right now makes the case better than any argument. Every single
-- row whose key came out longer than fifteen characters is two part numbers that arrived in one
-- cell — «54618-3JA0C+54668-3JA0C», «44327-30030 + 90430-16017», «F2GZ3A130A - F2GZ3A130B». The
-- cleaner stripped the separator and published 546183JA0C546683JA0C as though it were a part.
-- Nothing will ever match it. It is not a row with a problem, it is an invented part, and inventing
-- parts is worse than dropping rows.
--
-- Between eleven and fifteen sits a different animal: NGC8105005ADUS, 019CHA-1502106, 13780M68P01-Q
-- are real numbers that are simply not clean yet. They must not publish and must not be thrown
-- away — they wait, and get cleaned in a later pass outside this screen.
--
-- Three to ten is an ordinary part number. Clean it and let it through.
--
-- Two edges the rule as stated does not name, decided here and worth knowing:
--   • exactly fifteen is held, not rejected — «over 15» starts at sixteen;
--   • under three characters is rejected, since nothing that short identifies a part.

-- ① The rule, in one place, so the gate and any later backfill cannot drift apart.
create or replace function qvm_new_apps.part_number_verdict(p_key text)
returns jsonb
language sql
immutable
set search_path to 'qvm_new_apps', 'public'
as $$
  select case
    when p_key is null or length(p_key) < 3
      then jsonb_build_object('state', 'rejected',
             'reason', 'رقم القطعة أقصر من ٣ خانات بعد التنظيف')
    when length(p_key) <= 10
      then jsonb_build_object('state', 'ready', 'reason', null)
    when length(p_key) <= 15
      then jsonb_build_object('state', 'held',
             'reason', 'رقم القطعة ' || length(p_key)
                       || ' خانة بعد التنظيف — موقوف لتنظيف في مرحلة تالية')
    else jsonb_build_object('state', 'rejected',
           'reason', 'رقم القطعة ' || length(p_key)
                     || ' خانة بعد التنظيف — أطول من ١٥، غالبًا رقمان في خانة واحدة')
  end;
$$;

revoke all on function qvm_new_apps.part_number_verdict(text) from public;

-- ② The state itself. «held» is deliberately not «disabled»: disabled means the team owes this row
-- a code rule and can fix it here, held means the row leaves this screen untouched and comes back
-- cleaned. Same colour on a badge, completely different piece of work.
alter table qvm_new_apps.upload_rows drop constraint upload_rows_state_check;
alter table qvm_new_apps.upload_rows add constraint upload_rows_state_check
  check (state = any (array['ready'::text, 'held'::text, 'disabled'::text,
                            'rejected'::text, 'duplicate'::text]));

alter table qvm_new_apps.upload_batches
  add column if not exists rows_held integer not null default 0;

-- ③ The gate, inside the cleaner, so it applies on staging and on every re-check without anybody
-- pressing anything.
do $patch$
declare
  v_def text := pg_get_functiondef(
    'qvm_new_apps.upload_clean_row(jsonb,text,text,bigint)'::regprocedure);
  v_new text;
begin
  v_new := replace(v_def,
$old$  v_unknown := v_probe ~ '^[A-Za-z]{1,4}[-_. ]'
            or v_probe ~ '[-_. ][A-Za-z]{1,4}$'
            or (v_rule.rule_id is null and v_probe ~ '^[A-Za-z]{1,4}[0-9]{4,}$');

  return jsonb_build_object(
    'state',  case when v_unknown then 'disabled' else 'ready' end,
    'reason', case when v_unknown
                   then 'أضِف قاعدة كود لهذه البادئة أو اللاحقة ثم اربطها لتفعيل الصنف'
                   else null end,$old$,
$new$  -- The prefix guess no longer decides the state, because it was holding back genuine parts.
  -- In the file loaded today it caught ACPZ 1012H, F4AZ-6701-A and RS-76 — all three are part
  -- numbers, not codes with something hidden behind them. A key cannot both be clean by its
  -- length and be waiting for a rule, and length is the answer the team actually asked for. The
  -- shapes are still collected, by upload_batch_unknown_codes, which now reads them off the file
  -- rather than off a state this no longer sets.
  v_unknown := false;

  return jsonb_build_object(
    'state',  qvm_new_apps.part_number_verdict(v_key)->>'state',
    'reason', qvm_new_apps.part_number_verdict(v_key)->>'reason',$new$);

  if v_new = v_def then
    raise exception 'upload_clean_row: the state block was not found — the patch would be silent';
  end if;
  execute v_new;
end
$patch$;

-- ④ A held row is not a duplicate of anything. It never publishes, so letting it claim a part
-- number would push the next honest row carrying that number into «duplicate» and hide the fact
-- that the held one still needs cleaning. Rejected rows have been excluded from this for the same
-- reason since the beginning; held joins them.
do $patch$
declare
  v_fn text;
  v_def text;
  v_new text;
begin
  foreach v_fn in array array[
    'qvm_new_apps.upload_batch_stage(text,text,jsonb,text,bigint,text,text,bigint[])',
    'qvm_new_apps.upload_batch_recompute_run(bigint,uuid)'
  ] loop
    v_def := pg_get_functiondef(v_fn::regprocedure);
    v_new := replace(v_def, $old$v_state <> 'rejected'$old$,
                            $new$v_state not in ('rejected', 'held')$new$);
    if v_new = v_def then
      raise exception '%: no duplicate guard found to widen', v_fn;
    end if;
    execute v_new;
  end loop;
end
$patch$;

-- ⑤ The batch counters. Every place that recounts the states has to count the new one too, or the
-- screen shows a total that does not add up and nobody can tell where the missing rows went.
do $patch$
declare
  v_fn text;
  v_def text;
  v_new text;
begin
  foreach v_fn in array array[
    'qvm_new_apps.upload_batch_stage(text,text,jsonb,text,bigint,text,text,bigint[])',
    'qvm_new_apps.upload_batch_recompute_run(bigint,uuid)',
    'qvm_new_apps.upload_row_update(bigint,jsonb)'
  ] loop
    v_def := pg_get_functiondef(v_fn::regprocedure);
    -- The batch is addressed by a different expression in each of the three, so the line is
    -- matched by shape and the expression carried through rather than spelled out per function.
    v_new := regexp_replace(
      v_def,
      '( *)rows_duplicate = \(select count\(\*\) from qvm_new_apps\.upload_rows where batch_id = ([a-z_.]+) and state = ''duplicate''\),',
      E'\\1rows_duplicate = (select count(*) from qvm_new_apps.upload_rows where batch_id = \\2 and state = ''duplicate''),\n\\1rows_held      = (select count(*) from qvm_new_apps.upload_rows where batch_id = \\2 and state = ''held''),',
      'g');
    if v_new = v_def then
      raise exception '%: no counter block found to extend', v_fn;
    end if;
    execute v_new;
  end loop;
end
$patch$;

-- ⑥ Editing a row by hand may set it to held — a person looking at 13780M68P01-Q can say «this one
-- waits» as easily as the gate can.
do $patch$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.upload_row_update(bigint,jsonb)'::regprocedure);
  v_new text;
begin
  v_new := replace(v_def,
    $old$if v_state not in ('ready', 'disabled', 'rejected', 'duplicate') then$old$,
    $new$if v_state not in ('ready', 'held', 'disabled', 'rejected', 'duplicate') then$new$);
  if v_new = v_def then
    raise exception 'upload_row_update: the state allow-list was not found';
  end if;
  execute v_new;
end
$patch$;

-- ⑦ The unknown-codes panel used to read the rows the cleaner had marked «disabled». Nothing is
-- marked that way any more, so left alone the panel would simply be empty for ever — silently,
-- which is the worst way for a feature to stop. It reads the shapes off the file instead.
do $patch$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.upload_batch_unknown_codes(bigint)'::regprocedure);
  v_new text;
begin
  v_new := replace(v_def,
$old$            and r.state = 'disabled'
            -- A row that already matched a rule is explained; only the unexplained ones are asked$old$,
$new$            -- Not filtered by state any more: the length gate decides that now, and a short
            -- part number with a letter prefix is ready, which would have emptied this panel of
            -- exactly the codes it exists to collect.
            -- A row that already matched a rule is explained; only the unexplained ones are asked$new$);
  if v_new = v_def then
    raise exception 'upload_batch_unknown_codes: the state filter was not found';
  end if;
  execute v_new;
end
$patch$;

-- ⑧ The readers. A count the screen never receives is a count the screen cannot show.
do $patch$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('qvm_new_apps.upload_page_get()'::regprocedure);
  v_new := replace(v_def,
    $old$               'rows_duplicate', b.rows_duplicate,$old$,
    $new$               'rows_duplicate', b.rows_duplicate, 'rows_held', b.rows_held,$new$);
  if v_new = v_def then raise exception 'upload_page_get: batch object not found'; end if;
  execute v_new;

  v_def := pg_get_functiondef(
    'qvm_new_apps.uploaded_data_get(text,text,text,integer,integer)'::regprocedure);
  v_new := replace(v_def,
    $old$               'rows_duplicate', b.rows_duplicate, 'uploaded_by_name', u.user_name,$old$,
    $new$               'rows_duplicate', b.rows_duplicate, 'rows_held', b.rows_held,
               'uploaded_by_name', u.user_name,$new$);
  if v_new = v_def then raise exception 'uploaded_data_get: batch object not found'; end if;
  v_def := v_new;
  v_new := replace(v_new,
    $old$        'awaiting_rule', coalesce(sum(rows_disabled), 0))$old$,
    $new$        'awaiting_rule', coalesce(sum(rows_disabled), 0),
        'held', coalesce(sum(rows_held), 0))$new$);
  if v_new = v_def then raise exception 'uploaded_data_get: page counters not found'; end if;
  execute v_new;

  v_def := pg_get_functiondef('qvm_new_apps.upload_batch_apply_columns(jsonb)'::regprocedure);
  v_new := replace(v_def,
    $old$    'rows_rejected', v_b.rows_rejected, 'rows_disabled', v_b.rows_disabled,$old$,
    $new$    'rows_rejected', v_b.rows_rejected, 'rows_disabled', v_b.rows_disabled,
    'rows_held', v_b.rows_held,$new$);
  if v_new = v_def then raise exception 'upload_batch_apply_columns: result object not found'; end if;
  execute v_new;

  v_def := pg_get_functiondef('qvm_new_apps.upload_batch_reprocess_run(bigint,uuid)'::regprocedure);
  v_new := replace(v_def,
    $old$      'rows_ready', v_b.rows_ready, 'rows_disabled', v_b.rows_disabled,$old$,
    $new$      'rows_ready', v_b.rows_ready, 'rows_disabled', v_b.rows_disabled,
      'rows_held', v_b.rows_held,$new$);
  if v_new = v_def then raise exception 'upload_batch_reprocess_run: result object not found'; end if;
  execute v_new;
end
$patch$;

-- ⑨ The rows already staged. Without this the rule would only reach files uploaded from now on,
-- and the batch sitting on screen — the one the change was asked for — would keep publishing its
-- twenty-character inventions until somebody happened to press re-check.
update qvm_new_apps.upload_rows r
   set state  = qvm_new_apps.part_number_verdict(r.clean_part_number)->>'state',
       reason = qvm_new_apps.part_number_verdict(r.clean_part_number)->>'reason'
 where r.clean_part_number is not null
   -- Duplicates keep their verdict: it was reached by looking at the other rows, which a
   -- row-at-a-time update cannot see. The next recompute re-decides them in file order, as always.
   and r.state <> 'duplicate'
   and r.state is distinct from qvm_new_apps.part_number_verdict(r.clean_part_number)->>'state';

update qvm_new_apps.upload_batches b set
  rows_ready     = (select count(*) from qvm_new_apps.upload_rows where batch_id = b.batch_id and state = 'ready'),
  rows_held      = (select count(*) from qvm_new_apps.upload_rows where batch_id = b.batch_id and state = 'held'),
  rows_disabled  = (select count(*) from qvm_new_apps.upload_rows where batch_id = b.batch_id and state = 'disabled'),
  rows_rejected  = (select count(*) from qvm_new_apps.upload_rows where batch_id = b.batch_id and state = 'rejected'),
  rows_duplicate = (select count(*) from qvm_new_apps.upload_rows where batch_id = b.batch_id and state = 'duplicate');
