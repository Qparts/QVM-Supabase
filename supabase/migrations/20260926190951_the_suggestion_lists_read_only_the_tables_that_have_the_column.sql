-- Placeholder for a migration that was applied directly on QVM/dev on 2026-09-26 and recorded as
-- version 20260926190951 (the_suggestion_lists_read_only_the_tables_that_have_the_column) without a file in this repository.
--
-- The runner refuses to continue while the database records a version the repository does not
-- have ("Remote migration versions not found in local migrations directory"), which held back
-- every migration after it. Empty on purpose: the statements that ran are not in the repository,
-- so whoever applied them should replace this body before the branch is promoted, or test and
-- main will never receive the change.
SELECT 1;
