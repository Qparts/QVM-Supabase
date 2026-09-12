-- Re-checking a file is the same class of bulk work as reading it.
--
-- upload_batch_apply_columns was given room to finish; upload_batch_recompute was not, and it is
-- the same eleven seconds on the same 7,722 rows. So «add a code rule and re-check» could never
-- succeed on a file of this size: the rule saved, the re-check timed out, and the screen reported
-- the failure of the second step as though the first had not worked either.
--
-- The default eight seconds is sized for a request that serves one screen. A file re-read is not
-- that, and enforcing it here only means the work is refused rather than done.
alter function qvm_new_apps.upload_batch_recompute(bigint) set statement_timeout to '180s';
alter function qvm_new_apps.upload_batch_reprocess(bigint) set statement_timeout to '180s';
