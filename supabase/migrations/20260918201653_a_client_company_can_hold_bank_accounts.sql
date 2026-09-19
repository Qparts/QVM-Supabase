-- A client company can hold bank accounts, so recording their payment can name one.
--
-- Someone recording a customer's transfer has to match it against a bank statement, and the only
-- thing that matches is the account it came from. Nothing in the schema held that: `banks` existed
-- on vendor_branches and nowhere else, so the client side of the same job was done from memory or
-- from a WhatsApp message.
--
-- Same column name and same shape as the vendor one — {bank_name, bank_account_name, bank_iban} —
-- because it is the same fact about a different party, and a second spelling of it would mean two
-- readers to write and two to keep in step.
--
-- On the company rather than the branch. A vendor's accounts sit on the branch because each branch
-- invoices separately; a client company pays as one entity, and putting the accounts on every
-- branch would ask someone to answer the same question five times and then reconcile the answers.
alter table qvm_new_apps.client_companies
  add column if not exists banks jsonb not null default '[]'::jsonb;

comment on column qvm_new_apps.client_companies.banks is
  'Bank accounts the company pays from: [{bank_name, bank_account_name, bank_iban}]. Same shape as '
  'vendor_branches.banks — it is the same fact about a different party.';

-- The editor writes the whole list, and the argument is nullable so that callers which do not
-- know about accounts leave them alone instead of clearing them.
--
-- The existing 5-argument signature is dropped: a sixth parameter with a default would leave the
-- old function standing beside the new one, and a PostgREST call naming its arguments becomes
-- ambiguous between them rather than simply reaching the wrong one.
drop function if exists qvm_new_apps.admin_upsert_company(integer, jsonb, text, text, boolean);

create or replace function qvm_new_apps.admin_upsert_company(
  p_company_id integer default null,
  p_names      jsonb default null,
  p_cr_number  text default null,
  p_vat_number text default null,
  p_is_active  boolean default true,
  -- Null means «not editing the accounts». An empty array means «this company has none», which is
  -- a different statement and is allowed to clear them.
  p_banks      jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
DECLARE
  v_uid uuid := auth.uid();
  v_id integer;
  v_default_name text;
  v_banks jsonb;
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(v_uid) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: Qparts Admin only');
  END IF;
  PERFORM qvm_new_apps.assert_names_valid(p_names);

  -- An account with no IBAN is not an account. Dropped rather than refused: the editor lets a
  -- blank row exist while it is being filled in, and failing the whole save over one would lose
  -- the rest of the form.
  v_banks := CASE WHEN p_banks IS NULL THEN NULL ELSE (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'bank_name',         btrim(COALESCE(b->>'bank_name', '')),
             'bank_account_name', btrim(COALESCE(b->>'bank_account_name', '')),
             'bank_iban',         btrim(b->>'bank_iban'))), '[]'::jsonb)
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_banks) = 'array' THEN p_banks ELSE '[]'::jsonb END) b
     WHERE btrim(COALESCE(b->>'bank_iban', '')) <> '') END;

  v_default_name := (SELECT btrim(n->>'name') FROM jsonb_array_elements(p_names) n
                      WHERE (n->>'language_id')::int = qvm_new_apps.default_language_id() LIMIT 1);

  IF p_company_id IS NULL THEN
    -- list_data first: it owns the number, and the company takes the same one so that both halves
    -- of the platform — the 62 functions still reading list 1, and everything built on
    -- client_companies — mean the same company by the same id.
    INSERT INTO qvm_new_apps.list_data (list_id, list_data)
    VALUES (1, v_default_name)
    RETURNING list_data_id INTO v_id;

    INSERT INTO qvm_new_apps.client_companies (company_id, cr_number, vat_number, is_active, banks, created_by, updated_by)
    VALUES (v_id, p_cr_number, p_vat_number, COALESCE(p_is_active, true), COALESCE(v_banks, '[]'::jsonb), v_uid, v_uid);

    PERFORM setval(pg_get_serial_sequence('qvm_new_apps.client_companies', 'company_id'),
                   GREATEST(v_id, (SELECT COALESCE(max(company_id), 1) FROM qvm_new_apps.client_companies)));
  ELSE
    UPDATE qvm_new_apps.client_companies
    SET cr_number = p_cr_number, vat_number = p_vat_number,
        is_active = COALESCE(p_is_active, is_active),
        banks = COALESCE(v_banks, banks),
        updated_by = v_uid, updated_at = now()
    WHERE company_id = p_company_id
    RETURNING company_id INTO v_id;
    IF v_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'Company not found');
    END IF;

    -- Keep the mirror telling the truth. Without this a rename shows here and nowhere else.
    UPDATE qvm_new_apps.list_data
    SET list_data = v_default_name, updated_at = now()
    WHERE list_data_id = v_id AND list_id = 1 AND list_data IS DISTINCT FROM v_default_name;
  END IF;

  INSERT INTO qvm_new_apps.client_companies_descriptions (company_id, language_id, name, created_by, updated_by)
  SELECT v_id, (n->>'language_id')::int, btrim(n->>'name'), v_uid, v_uid
  FROM jsonb_array_elements(p_names) n
  WHERE btrim(COALESCE(n->>'name', '')) <> ''
  ON CONFLICT (company_id, language_id) DO UPDATE
    SET name = EXCLUDED.name, updated_by = EXCLUDED.updated_by, updated_at = now();

  -- A language cleared in the editor is removed rather than left behind as a stale translation.
  DELETE FROM qvm_new_apps.client_companies_descriptions d
   WHERE d.company_id = v_id
     AND d.language_id <> qvm_new_apps.default_language_id()
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_names) n
                      WHERE (n->>'language_id')::int = d.language_id
                        AND btrim(COALESCE(n->>'name', '')) <> '');

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('company_id', v_id));
END $function$;

-- The app reaches this through the public wrapper, not the schema-qualified one, so the argument
-- has to be carried through both. Dropped and recreated for the same reason as the inner one.
drop function if exists public.admin_upsert_company(integer, jsonb, text, text, boolean);

create or replace function public.admin_upsert_company(
  p_company_id integer default null,
  p_names      jsonb default null,
  p_cr_number  text default null,
  p_vat_number text default null,
  p_is_active  boolean default true,
  p_banks      jsonb default null)
returns jsonb
language sql
security definer
set search_path to ''
as $function$
  SELECT qvm_new_apps.admin_upsert_company(p_company_id, p_names, p_cr_number, p_vat_number, p_is_active, p_banks);
$function$;

grant execute on function public.admin_upsert_company(integer, jsonb, text, text, boolean, jsonb)
  to authenticated, service_role;

-- Reading them back for the payment screen.
--
-- Deliberately narrow: it answers «which accounts does this company pay from» and nothing else, so
-- it can be reachable by the people who record payments without handing them the company record.
-- Scoped the same way the statement is — Qparts operations reads any company, a company's own
-- people read their own — because the two screens sit next to each other and a different answer
-- from each would be a bug waiting to be found by a customer.
create or replace function qvm_new_apps.client_company_banks(p_company_id integer)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
declare
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_rows jsonb;
begin
  if not v_team and not exists (
    select 1 from qvm_new_apps.user_companies uc
     where uc.user_id = auth.uid() and uc.company_id = p_company_id
  ) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'bank_name', b->>'bank_name',
           'bank_account_name', b->>'bank_account_name',
           'bank_iban', b->>'bank_iban')), '[]'::jsonb)
    into v_rows
    from qvm_new_apps.client_companies c
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(c.banks) = 'array' then c.banks else '[]'::jsonb end) b
   where c.company_id = p_company_id
     and nullif(b->>'bank_iban', '') is not null;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('banks', coalesce(v_rows, '[]'::jsonb)));
end
$$;

revoke all on function qvm_new_apps.client_company_banks(integer) from public;
grant execute on function qvm_new_apps.client_company_banks(integer)
  to authenticated, service_role;
grant execute on function qvm_new_apps.admin_upsert_company(integer, jsonb, text, text, boolean, jsonb)
  to authenticated, service_role;
