-- STOC_INT public BSC address registration.
-- The browser creates a candidate address. PostgreSQL only validates, deduplicates
-- and stores the public address; no private key or mnemonic is persisted.

create or replace function private.is_evm_public_address(p_address text)
returns boolean
language sql
immutable
set search_path = public, pg_temp
as $$
  select trim(coalesce(p_address, '')) ~ '^0x[0-9A-Fa-f]{40}$';
$$;
revoke all on function private.is_evm_public_address(text)
from public, anon, authenticated;
create or replace function public.rpc_register_my_stoc_int_bsc_address(
  p_address text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_address text := trim(coalesce(p_address, ''));
  v_existing public.wallet_addresses%rowtype;
  v_conflicting_user_id uuid;
begin
  v_member := private.require_active_member();

  if not private.is_evm_public_address(v_address) then
    raise exception using errcode = 'P0001', message = 'INVALID_WALLET_ADDRESS';
  end if;

  -- One transaction per user and per candidate address. This protects against
  -- React remounts, double taps and concurrent WebView requests without adding
  -- an application log row for every ensure attempt.
  perform pg_advisory_xact_lock(
    hashtextextended('stoc-int-bsc-user:' || v_member.user_id::text, 0)
  );

  select * into v_existing
    from public.wallet_addresses wa
   where wa.user_id = v_member.user_id
     and wa.chain = 'bsc'
     and wa.asset_code = 'STOC_INT'
   limit 1;

  if found then
    if v_existing.status <> 'active' then
      update public.wallet_addresses
         set status = 'active', updated_at = now()
       where id = v_existing.id
       returning * into v_existing;
    end if;

    return jsonb_build_object(
      'address', v_existing.address,
      'chain', v_existing.chain,
      'assetCode', v_existing.asset_code,
      'created', false
    );
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('stoc-int-bsc-address:' || lower(v_address), 0)
  );

  select wa.user_id into v_conflicting_user_id
    from public.wallet_addresses wa
   where lower(wa.chain) = 'bsc'
     and lower(wa.address) = lower(v_address)
   limit 1;

  if v_conflicting_user_id is not null
     and v_conflicting_user_id <> v_member.user_id then
    raise exception using errcode = 'P0001', message = 'WALLET_ADDRESS_ALREADY_ASSIGNED';
  end if;

  insert into public.wallet_addresses (
    user_id,
    chain,
    asset_code,
    address,
    memo_tag,
    status
  ) values (
    v_member.user_id,
    'bsc',
    'STOC_INT',
    v_address,
    null,
    'active'
  )
  returning * into v_existing;

  return jsonb_build_object(
    'address', v_existing.address,
    'chain', v_existing.chain,
    'assetCode', v_existing.asset_code,
    'created', true
  );
end;
$$;
revoke all on function public.rpc_register_my_stoc_int_bsc_address(text)
from public, anon, authenticated;
grant execute on function public.rpc_register_my_stoc_int_bsc_address(text)
to authenticated;
-- Service-role-only bulk importer used by the one-time legacy backfill script
-- and by future legacy migrations. It intentionally returns aggregate counts
-- rather than writing one audit/log row per user.
create or replace function public.service_import_legacy_stoc_int_bsc_addresses(
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_row jsonb;
  v_user_id uuid;
  v_address text;
  v_existing_address text;
  v_owner_user_id uuid;
  v_inserted integer := 0;
  v_existing integer := 0;
  v_invalid integer := 0;
  v_conflict integer := 0;
begin
  if jsonb_typeof(coalesce(p_rows, '[]'::jsonb)) <> 'array' then
    raise exception using errcode = 'P0001', message = 'INVALID_IMPORT_ROWS';
  end if;

  for v_row in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    begin
      v_user_id := nullif(trim(coalesce(v_row->>'userId', '')), '')::uuid;
    exception when invalid_text_representation then
      v_user_id := null;
    end;
    v_address := trim(coalesce(v_row->>'address', ''));

    if v_user_id is null
       or not private.is_evm_public_address(v_address)
       or not exists (select 1 from public.member m where m.user_id = v_user_id) then
      v_invalid := v_invalid + 1;
      continue;
    end if;

    perform pg_advisory_xact_lock(
      hashtextextended('stoc-int-bsc-user:' || v_user_id::text, 0)
    );

    select wa.address into v_existing_address
      from public.wallet_addresses wa
     where wa.user_id = v_user_id
       and wa.chain = 'bsc'
       and wa.asset_code = 'STOC_INT'
     limit 1;

    if v_existing_address is not null then
      v_existing := v_existing + 1;
      continue;
    end if;

    perform pg_advisory_xact_lock(
      hashtextextended('stoc-int-bsc-address:' || lower(v_address), 0)
    );

    select wa.user_id into v_owner_user_id
      from public.wallet_addresses wa
     where lower(wa.chain) = 'bsc'
       and lower(wa.address) = lower(v_address)
     limit 1;

    if v_owner_user_id is not null and v_owner_user_id <> v_user_id then
      v_conflict := v_conflict + 1;
      continue;
    end if;

    begin
      insert into public.wallet_addresses (
        user_id, chain, asset_code, address, memo_tag, status
      ) values (
        v_user_id, 'bsc', 'STOC_INT', v_address, null, 'active'
      );
      v_inserted := v_inserted + 1;
    exception when unique_violation then
      v_conflict := v_conflict + 1;
    end;
  end loop;

  return jsonb_build_object(
    'inserted', v_inserted,
    'existing', v_existing,
    'invalid', v_invalid,
    'conflict', v_conflict,
    'processed', v_inserted + v_existing + v_invalid + v_conflict
  );
end;
$$;
revoke all on function public.service_import_legacy_stoc_int_bsc_addresses(jsonb)
from public, anon, authenticated;
grant execute on function public.service_import_legacy_stoc_int_bsc_addresses(jsonb)
to service_role;
