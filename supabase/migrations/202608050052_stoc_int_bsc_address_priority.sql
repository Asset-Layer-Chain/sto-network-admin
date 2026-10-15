-- STOC_INT/BSC address priority:
--   1) existing current DB address (no update)
--   2) legacy address for reg_channel=legacy_migration (resolved by Edge Function)
--   3) browser-generated candidate
--
-- This service-role RPC is the single race-safe write path used by the Edge
-- Function. Existing rows are returned exactly as stored and are never updated.

create or replace function public.service_ensure_stoc_int_bsc_address(
  p_user_id uuid,
  p_address text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_address text := trim(coalesce(p_address, ''));
  v_existing public.wallet_addresses%rowtype;
  v_conflicting_user_id uuid;
  v_created boolean := false;
begin
  if p_user_id is null
     or not exists (select 1 from public.member m where m.user_id = p_user_id) then
    raise exception using errcode = 'P0001', message = 'MEMBER_NOT_FOUND';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('stoc-int-bsc-user:' || p_user_id::text, 0)
  );

  select * into v_existing
    from public.wallet_addresses wa
   where wa.user_id = p_user_id
     and lower(wa.chain) = 'bsc'
     and upper(wa.asset_code) = 'STOC_INT'
   order by wa.created_at asc
   limit 1;

  if found then
    return jsonb_build_object(
      'address', v_existing.address,
      'chain', v_existing.chain,
      'assetCode', v_existing.asset_code,
      'status', v_existing.status,
      'created', false
    );
  end if;

  if not private.is_evm_public_address(v_address) then
    raise exception using errcode = 'P0001', message = 'INVALID_WALLET_ADDRESS';
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
     and v_conflicting_user_id <> p_user_id then
    raise exception using errcode = 'P0001', message = 'WALLET_ADDRESS_ALREADY_ASSIGNED';
  end if;

  begin
    insert into public.wallet_addresses (
      user_id,
      chain,
      asset_code,
      address,
      memo_tag,
      status
    ) values (
      p_user_id,
      'bsc',
      'STOC_INT',
      v_address,
      null,
      'active'
    )
    returning * into v_existing;
    v_created := true;
  exception when unique_violation then
    -- A concurrent request may have inserted the user's address after the
    -- initial read. Return that row without updating it.
    select * into v_existing
      from public.wallet_addresses wa
     where wa.user_id = p_user_id
       and lower(wa.chain) = 'bsc'
       and upper(wa.asset_code) = 'STOC_INT'
     order by wa.created_at asc
     limit 1;

    if not found then
      raise;
    end if;
  end;

  return jsonb_build_object(
    'address', v_existing.address,
    'chain', v_existing.chain,
    'assetCode', v_existing.asset_code,
    'status', v_existing.status,
    'created', v_created
  );
end;
$$;
revoke all on function public.service_ensure_stoc_int_bsc_address(uuid, text)
from public, anon, authenticated;
grant execute on function public.service_ensure_stoc_int_bsc_address(uuid, text)
to service_role;
-- Backward-compatible guard for cached pre-052 web bundles. Existing addresses
-- are still returned unchanged. Legacy members without a current address are
-- blocked from the old direct-create path so they cannot bypass legacy lookup.
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
  v_existing public.wallet_addresses%rowtype;
begin
  v_member := private.require_active_member();

  perform pg_advisory_xact_lock(
    hashtextextended('stoc-int-bsc-user:' || v_member.user_id::text, 0)
  );

  select * into v_existing
    from public.wallet_addresses wa
   where wa.user_id = v_member.user_id
     and lower(wa.chain) = 'bsc'
     and upper(wa.asset_code) = 'STOC_INT'
   order by wa.created_at asc
   limit 1;

  if found then
    return jsonb_build_object(
      'address', v_existing.address,
      'chain', v_existing.chain,
      'assetCode', v_existing.asset_code,
      'status', v_existing.status,
      'created', false
    );
  end if;

  if lower(trim(coalesce(v_member.reg_channel, ''))) = 'legacy_migration' then
    raise exception using errcode = 'P0001', message = 'LEGACY_ADDRESS_REQUIRES_ENSURE';
  end if;

  return public.service_ensure_stoc_int_bsc_address(v_member.user_id, p_address);
end;
$$;
revoke all on function public.rpc_register_my_stoc_int_bsc_address(text)
from public, anon, authenticated;
grant execute on function public.rpc_register_my_stoc_int_bsc_address(text)
to authenticated;
comment on function public.service_import_legacy_stoc_int_bsc_addresses(jsonb) is
  'Deprecated after 052. Kept temporarily for deployment compatibility; no current web or Edge Function calls it.';
