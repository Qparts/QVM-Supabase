-- Reading what people actually type, before anything is asked of them.
--
-- A supplier file is written by a person in a hurry, so «١٬٢٣٤٫٥٠» and «1,234.50» and
-- «1.234,50 ر.س» are all the same price, and «قمة النظائر لقطع الغيار» and
-- «قمه النظائر  لقطع الغيار» are the same company. None of those were equal to each other
-- anywhere in the upload path: part_purchase_history.supplier_name is free text, and the
-- duplicate check in upload_batch_write_rows compares that text exactly. So one letter turns a
-- supplier into two, splits their price history between them, and quietly falsifies the vendor
-- comparison the Past Purchases screen exists to produce.
--
-- These functions are the shared answer to «are these the same thing». Matching uses them, the
-- mapping step uses them, and the duplicate checks use them — one definition, so the screen and
-- the writer cannot come to different conclusions.
--
-- Every case below is covered by a test run against the live table; the ones that read oddly are
-- the ones that were wrong first.

create extension if not exists pg_trgm;

/**
 * Arabic-Indic and Eastern Arabic digits to ASCII.
 *
 * ٠١٢٣ and ۰۱۲۳ are digits to everyone reading the file and are not digits at all to `::numeric`.
 */
create or replace function qvm_new_apps.norm_digits(p text)
returns text
language sql
immutable
set search_path to ''
as $function$
  select translate(coalesce(p, ''),
                   '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹',
                   '01234567890123456789');
$function$;

/**
 * A name reduced to what makes it the same name.
 *
 * Case, spacing and the Arabic letters people type interchangeably are removed, along with
 * tatweel, harakat and punctuation. The result is never shown to anybody: it exists to be
 * compared. On the real vendor list, true pairs score 1.000 and unrelated companies score
 * below 0.07 — which is what makes a confident threshold possible at all.
 */
create or replace function qvm_new_apps.norm_text(p text)
returns text
language sql
immutable
set search_path to ''
as $function$
  select nullif(btrim(regexp_replace(
    translate(
      regexp_replace(
        lower(qvm_new_apps.norm_digits(coalesce(p, ''))),
        '[ـً-ْٓ-ٰٟ]', '', 'g'),
      -- Eight letters in, eight out. The target was one character short at first, which
      -- silently shifted every mapping after it: ٱ became ه, ة became ي, and ئ was deleted —
      -- so the «قمة/قمه» pair this exists to reconcile still came out as two companies.
      'أإآٱةىؤئ',
      'ااااهيوي'),
    '[^a-z0-9؀-ۿ]+', ' ', 'g')), '');
$function$;

/**
 * A number, however it was written.
 *
 * Handles Arabic digits and the Arabic decimal/thousands marks, currency words and symbols,
 * every kind of invisible space, and accounting negatives in parentheses.
 *
 * The separator problem has no perfect answer — «1,234» is a thousand in one convention and
 * 1.234 in another — so the rule is stated once here rather than guessed at each call site:
 * when both separators appear, the LAST one is the decimal point; when only one appears, it is
 * grouping only if exactly three digits follow it. That reads 1,234 as 1234 and 1,23 as 1.23.
 */
create or replace function qvm_new_apps.norm_number(p text)
returns numeric
language plpgsql
immutable
set search_path to ''
as $function$
declare s text; v_neg boolean := false; v_last_comma int; v_last_dot int;
begin
  s := qvm_new_apps.norm_digits(coalesce(p, ''));
  if btrim(s) = '' then return null; end if;
  s := replace(replace(s, '٫', '.'), '٬', ',');
  -- Every space a spreadsheet can hide in a cell, listed one by one. Written with a hyphen
  -- between two of them it became a range spanning the digits themselves and erased the whole
  -- number — which the handler at the bottom then reported as «no price».
  s := regexp_replace(s, '[\s             ​  　﻿]', '', 'g');
  if s ~ '^\(.*\)$' then v_neg := true; end if;
  if s ~ '-' then v_neg := true; end if;
  s := regexp_replace(s, '[^0-9.,]', '', 'g');
  -- «230.44 ر.س» leaves a trailing dot behind once the currency letters are gone, and a value
  -- with two dots in it cannot be cast. A separator at either end never carried meaning.
  s := btrim(s, '.,');
  if s = '' then return null; end if;

  v_last_comma := length(s) - coalesce(nullif(position(',' in reverse(s)), 0), 0);
  v_last_dot   := length(s) - coalesce(nullif(position('.' in reverse(s)), 0), 0);

  if position(',' in s) > 0 and position('.' in s) > 0 then
    if v_last_comma > v_last_dot then s := replace(replace(s, '.', ''), ',', '.');
    else s := replace(s, ',', ''); end if;
  elsif position(',' in s) > 0 then
    if s ~ '^\d+(,\d{3})+$' then s := replace(s, ',', '');
    else s := replace(s, ',', '.'); end if;
  elsif position('.' in s) > 0 then
    if s ~ '^\d+(\.\d{3})+$' then s := replace(s, '.', ''); end if;
  end if;

  if s !~ '^\d*\.?\d*$' or s in ('', '.') then return null; end if;
  return case when v_neg then -s::numeric else s::numeric end;
exception when others then
  return null;
end
$function$;

/**
 * A date, however it was written — including as the number a spreadsheet stores underneath.
 *
 * Excel keeps dates as days since 1899-12-30, so a column formatted as text arrives as «45678»
 * and casting it raises rather than returning the date everybody can see on screen.
 */
create or replace function qvm_new_apps.norm_date(p text)
returns date
language plpgsql
immutable
set search_path to ''
as $function$
declare s text; a int; b int; c int; m text[];
begin
  s := btrim(qvm_new_apps.norm_digits(coalesce(p, '')));
  if s = '' then return null; end if;

  if s ~ '^\d{5}(\.\d+)?$' then
    return (date '1899-12-30' + (floor(s::numeric))::integer);
  end if;

  if s ~ '^\d{4}-\d{1,2}-\d{1,2}' then
    return substring(s from '^\d{4}-\d{1,2}-\d{1,2}')::date;
  end if;

  m := regexp_match(s, '^(\d{1,4})[/.\-](\d{1,2})[/.\-](\d{2,4})');
  if m is null then
    begin return s::date; exception when others then return null; end;
  end if;

  a := m[1]::int; b := m[2]::int; c := m[3]::int;

  -- Year first: the last number is the day and can never be a shortened year. Deciding this
  -- before widening a 2-digit year is the point — 2025/03/15 was read as year 2015 and then
  -- thrown away as an impossible date.
  if a > 31 then return make_date(a, b, c); end if;

  if c < 100 then c := 2000 + c; end if;
  -- Day first, which is how it is written here. Above 12 it could not be a month anyway.
  return make_date(c, b, a);
exception when others then
  return null;
end
$function$;
