-- Synced from QVM/test branch applied migration history (version 20260408061305, name: qpd445_add_date_for_weekday_helper)
BEGIN;

SET search_path TO qvm_new_apps, public;

CREATE OR REPLACE FUNCTION public._date_for_weekday(
  p_date date,
  p_target integer
) RETURNS date
LANGUAGE sql STABLE
AS $$
  SELECT (p_date + make_interval(days => (p_target - extract(dow from p_date))::int))::date;
$$;

CREATE OR REPLACE FUNCTION public._date_for_weekday(
  p_date date,
  p_target smallint
) RETURNS date
LANGUAGE sql STABLE
AS $$
  SELECT public._date_for_weekday(p_date, p_target::int);
$$;

COMMIT;;
