-- Placeholder for a migration that was applied directly on QVM/dev on 2026-09-27 and recorded as
-- version 20260927115357 (in_a_purchases_file_the_supplier_is_the_source_and_the_city_is_the_branch) without a file in this repository.
--
-- The runner refuses to continue while the database records a version the repository does not
-- have ("Remote migration versions not found in local migrations directory"), which held back
-- every migration after it. Empty on purpose: the statements that ran are not in the repository,
-- so whoever applied them should replace this body before the branch is promoted, or test and
-- main will never receive the change.
SELECT 1;
