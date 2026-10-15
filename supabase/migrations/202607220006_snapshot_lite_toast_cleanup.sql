-- Reduce app/home payload size by separating lightweight app state from wallet summary.
-- Existing private.member_snapshot remains available for legacy RPCs.

-- Backfill wallet network rows once. Read RPCs below do not perform writes.
do $$
declare
  v_user_id uuid;
begin
  for v_user_id in select user_id from public.member loop
    perform private.ensure_wallet_networks(v_user_id);
  end loop;
end $$;
create or replace function private.wallet_summary(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_wallet_networks jsonb;
  v_total_stoc_balance numeric := 0;
  v_internal_stoc_balance numeric := 0;
begin
  with wallet_defs(chain, label, sheet_label, asset_code, display_symbol, icon, sort_order) as (
    values
      ('stoc_internal', 'STOC', 'STOC', 'STOC_INT', 'STOC', '/assets/token-sto.png', 1),
      ('kaia', 'KLAY', 'KLAY', 'STOC_KAIA', 'STOC', '/assets/icon_klay.png', 2),
      ('ethereum', 'ETH', 'ETH', 'STOC_ETH', 'STOC', '/assets/icon_eth.png', 3),
      ('bsc', 'Binance', 'Binance', 'STOC_BSC', 'STOC', '/assets/icon_binance.png', 4),
      ('polygon', 'Polygon', 'Polygon', 'STOC_POLYGON', 'STOC', '/assets/icon_polygon.png', 5)
  ), network_rows as (
    select
      d.chain,
      d.label,
      d.sheet_label,
      d.asset_code,
      d.display_symbol,
      d.icon,
      d.sort_order,
      coalesce(wa.available_balance, 0::numeric) as balance
    from wallet_defs d
    left join public.wallet_accounts wa
      on wa.user_id = p_user_id
     and wa.asset_code = d.asset_code
     and wa.account_type = 'internal'
  )
  select
    coalesce(sum(balance), 0::numeric),
    coalesce(jsonb_agg(jsonb_build_object(
      'chain', chain,
      'label', label,
      'sheetLabel', sheet_label,
      'assetCode', asset_code,
      'displaySymbol', display_symbol,
      'icon', icon,
      'balance', balance
    ) order by sort_order), '[]'::jsonb)
    into v_total_stoc_balance, v_wallet_networks
  from network_rows;

  select coalesce(wa.available_balance, 0::numeric)
    into v_internal_stoc_balance
    from public.wallet_accounts wa
   where wa.user_id = p_user_id
     and wa.asset_code = 'STOC_INT'
     and wa.account_type = 'internal'
   limit 1;

  v_internal_stoc_balance := coalesce(v_internal_stoc_balance, 0::numeric);

  return jsonb_build_object(
    'totalStocBalance', v_total_stoc_balance,
    'internalStocBalance', v_internal_stoc_balance,
    'initial_aidas', v_total_stoc_balance,
    'mb_stoc', v_total_stoc_balance,
    'walletNetworks', v_wallet_networks,
    'updatedAt', now()
  );
end;
$$;
create or replace function private.member_client_snapshot(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_wallet_summary jsonb;
begin
  select * into v_member
    from public.member
   where user_id = p_user_id;

  if not found then
    return 'null'::jsonb;
  end if;

  v_wallet_summary := private.wallet_summary(p_user_id);

  return jsonb_build_object(
    'user_id', v_member.user_id,
    'mb_no', v_member.mb_no,
    'mb_id', v_member.mb_id,
    'mb_name', v_member.mb_name,
    'mb_email', v_member.mb_email,
    'mb_hp', v_member.mb_hp,
    'mb_profile', v_member.mb_profile,
    'status', v_member.status,
    'role', v_member.role,
    'locale', coalesce(v_member.locale, 'ko'),
    'is_del', v_member.is_del,
    'referral_code', v_member.referral_code,
    'referrer_user_id', v_member.referrer_user_id,
    'marketing_agreed', coalesce(v_member.marketing_agreed, false),
    'push_notifications_enabled', coalesce(v_member.push_notifications_enabled, false)
  ) || v_wallet_summary;
end;
$$;
create or replace function public.rpc_get_wallet_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_member public.member%rowtype;
begin
  v_member := private.require_active_member();
  return private.wallet_summary(v_member.user_id);
end;
$$;
create or replace function public.rpc_get_home_snapshot()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_member_snapshot jsonb;
  v_wallet_summary jsonb;
  v_unread integer := 0;
begin
  v_member := private.require_active_member();
  v_member_snapshot := private.member_client_snapshot(v_member.user_id);
  v_wallet_summary := private.wallet_summary(v_member.user_id);

  select count(*)::integer
    into v_unread
    from public.notifications
   where user_id = v_member.user_id
     and is_read = false;

  return jsonb_build_object(
    'member', v_member_snapshot,
    'initial_aidas', (v_wallet_summary ->> 'totalStocBalance')::numeric,
    'totalStocBalance', (v_wallet_summary ->> 'totalStocBalance')::numeric,
    'internalStocBalance', (v_wallet_summary ->> 'internalStocBalance')::numeric,
    'walletNetworks', v_wallet_summary -> 'walletNetworks',
    'unread_notification_count', coalesce(v_unread, 0)
  );
end;
$$;
create or replace function public.rpc_get_app_bootstrap()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_member public.member%rowtype;
  v_access_state jsonb;
  v_member_snapshot jsonb := null;
  v_popup_state jsonb := null;
  v_chat_unread_total integer := 0;
  v_notification_unread_total integer := 0;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  select * into v_member
    from public.member
   where user_id = v_user_id;

  if not found then
    v_access_state := jsonb_build_object(
      'status', 'missing',
      'serviceAllowed', true,
      'contactRequired', false
    );

    return jsonb_build_object(
      'memberAccessState', v_access_state,
      'member', null,
      'popupState', null,
      'chatUnreadTotal', 0,
      'notificationUnreadTotal', 0,
      'locale', 'ko',
      'serverTime', now()
    );
  end if;

  if v_member.is_del or v_member.status = 'deleted' then
    v_access_state := jsonb_build_object(
      'status', 'deleted',
      'serviceAllowed', false,
      'contactRequired', true,
      'inquiryType', 'deleted_account_reactivation',
      'member', jsonb_build_object(
        'user_id', v_member.user_id,
        'mb_id', v_member.mb_id,
        'mb_email', v_member.mb_email,
        'is_del', true,
        'deleted_at', v_member.deleted_at
      )
    );

    return jsonb_build_object(
      'memberAccessState', v_access_state,
      'member', null,
      'popupState', null,
      'chatUnreadTotal', 0,
      'notificationUnreadTotal', 0,
      'locale', coalesce(v_member.locale, 'ko'),
      'serverTime', now()
    );
  end if;

  v_access_state := jsonb_build_object(
    'status', v_member.status,
    'serviceAllowed', v_member.status = 'active',
    'contactRequired', false,
    'member', jsonb_build_object(
      'user_id', v_member.user_id,
      'mb_id', v_member.mb_id,
      'mb_email', v_member.mb_email,
      'is_del', false
    )
  );

  v_member_snapshot := private.member_client_snapshot(v_member.user_id);

  select count(*)::integer
    into v_notification_unread_total
    from public.notifications
   where user_id = v_member.user_id
     and is_read = false;

  select coalesce(sum(cm.unread_count), 0)::integer
    into v_chat_unread_total
    from public.chat_members cm
   where cm.user_id = v_member.user_id
     and cm.left_at is null;

  begin
    v_popup_state := public.rpc_get_app_popup_state();
  exception when others then
    v_popup_state := null;
  end;

  return jsonb_build_object(
    'memberAccessState', v_access_state,
    'member', v_member_snapshot,
    'popupState', v_popup_state,
    'chatUnreadTotal', coalesce(v_chat_unread_total, 0),
    'notificationUnreadTotal', coalesce(v_notification_unread_total, 0),
    'locale', coalesce(v_member.locale, 'ko'),
    'serverTime', now()
  );
end;
$$;
revoke all on function private.wallet_summary(uuid) from public, anon, authenticated;
revoke all on function private.member_client_snapshot(uuid) from public, anon, authenticated;
revoke all on function public.rpc_get_wallet_summary() from public, anon, authenticated;
revoke all on function public.rpc_get_home_snapshot() from public, anon, authenticated;
revoke all on function public.rpc_get_app_bootstrap() from public, anon, authenticated;
grant execute on function public.rpc_get_wallet_summary() to authenticated;
grant execute on function public.rpc_get_home_snapshot() to authenticated;
grant execute on function public.rpc_get_app_bootstrap() to authenticated;
