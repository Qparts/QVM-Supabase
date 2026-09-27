-- Placeholder for a migration that was applied directly on QVM/dev on 2026-09-26 and recorded as
-- version 20260926192529 (a_branch_says_which_of_the_three_levels_it_is) without a file in this repository.
--
-- The runner refuses to continue while the database records a version the repository does not
-- have, which held back every migration after it. This file only closes that gap on dev. It is
-- empty on purpose: the statements that ran are not in the repository, so whoever applied them
-- should replace this body with them before the branch is promoted, or test and main will never
-- receive the change.
SELECT 1;
