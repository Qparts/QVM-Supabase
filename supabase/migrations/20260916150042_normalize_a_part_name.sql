-- Normalising a part NAME, the way normalize_part_number already normalises a number.
--
-- The system could tell that «04465-06090» and «0446506090» are one number, and could not tell
-- that «فلتر الهواء» and «فلتر هوا» are one name. So every spelling a supplier invented became a
-- new thing, and the dictionary could only ever be consulted by number — «what is X called»
-- worked, «do we already say this» did not.
--
-- What it collapses, and why each one is safe on a part name:
--   · tashkeel and tatweel      — decoration; never distinguishes two parts
--   · أ إ آ ٱ → ا               — the hamza is the single most common spelling variance
--   · ة → ه, ى → ي, ؤ ئ → و ي   — the same word, typed by two people
--   · the definite article      — «الفرامل» and «فرامل» are one word
--   · Arabic-Indic digits       — reuses norm_digits, so numbers inside a name behave as they
--                                 do inside a part number
--   · punctuation and case      — «Front Oil Seal / Crankshaft Seal» and «front oil seal»
--
-- What it deliberately does NOT collapse: position words. أمامي, خلفي, يمين, يسار stay, because
-- they are the difference between the right part arriving and the wrong one.
--
-- IMMUTABLE on purpose: it has to be usable in a generated column and in an index.
create or replace function qvm_new_apps.normalize_part_name(p_value text)
returns text
language sql
immutable
set search_path to 'qvm_new_apps', 'pg_catalog'
as $$
  select nullif(
    btrim(
      regexp_replace(
        -- 5 · the definite article, only where a real word is left behind. Stripping it from a
        --     two-letter word would turn a word into a fragment, so three characters must remain.
        regexp_replace(
          -- 4 · anything that is not a letter, a digit or a space becomes a space
          regexp_replace(
            -- 3 · letter forms that are the same letter typed differently
            translate(
              -- 2 · marks that carry no meaning in a name
              regexp_replace(
                -- 1 · Arabic-Indic digits, exactly as a part number treats them
                lower(qvm_new_apps.norm_digits(coalesce(p_value, ''))),
                -- U+064B–U+065F are combining marks only; U+0670 the superscript alef; U+0640
                -- the tatweel. A wider range than this silently swallows the alphabet itself —
                -- the first draft of this line returned an empty string for every Arabic name.
                '[ً-ٰٟـ]', '', 'g'),
              'أإآٱةىؤئ',
              'ااااهيوي'),
            '[^[:alnum:]؀-ۿ ]', ' ', 'g'),
          '(^|\s)ال(?=[؀-ۿ]{3,})', '\1', 'g'),
        -- 6 · one space between words, whatever arrived
        '\s+', ' ', 'g')),
    '');
$$;

comment on function qvm_new_apps.normalize_part_name(text) is
  'The comparison form of a part name. Two names are the same wording when their normalised '
  'forms are equal. Position words (أمامي/خلفي/يمين/يسار) survive on purpose.';

grant execute on function qvm_new_apps.normalize_part_name(text) to authenticated, service_role;
