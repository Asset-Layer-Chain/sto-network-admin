-- Wallet network selector support for home/wallet cards.
-- STO is intentionally excluded. The visible networks are STOC Internal, KLAY, ETH, Binance, Polygon.

alter table public.wallet_accounts
  add column if not exists chain text;
create index if not exists wallet_accounts_user_chain_asset_idx
  on public.wallet_accounts(user_id, chain, asset_code, account_type);
update public.wallet_accounts
   set chain = case
     when asset_code = 'STOC_INT' then 'stoc_internal'
     when asset_code = 'BNB' then 'bsc'
     else chain
   end
 where chain is null
   and asset_code in ('STOC_INT', 'BNB');
create or replace function private.ensure_wallet_networks(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_user_id is null then
    return;
  end if;

  insert into public.wallet_accounts (user_id, chain, asset_code, account_type, available_balance, locked_balance)
  values
    (p_user_id, 'stoc_internal', 'STOC_INT', 'internal', 0, 0),
    (p_user_id, 'kaia', 'STOC_KAIA', 'internal', 0, 0),
    (p_user_id, 'ethereum', 'STOC_ETH', 'internal', 0, 0),
    (p_user_id, 'bsc', 'STOC_BSC', 'internal', 0, 0),
    (p_user_id, 'polygon', 'STOC_POLYGON', 'internal', 0, 0)
  on conflict (user_id, asset_code, account_type)
  do update set
    chain = excluded.chain,
    updated_at = case
      when public.wallet_accounts.chain is distinct from excluded.chain then now()
      else public.wallet_accounts.updated_at
    end;
end;
$$;
create or replace function private.ensure_wallet_networks_after_member_insert()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform private.ensure_wallet_networks(new.user_id);
  return new;
end;
$$;
drop trigger if exists member_ensure_wallet_networks on public.member;
create trigger member_ensure_wallet_networks
after insert on public.member
for each row execute function private.ensure_wallet_networks_after_member_insert();
do $$
declare
  v_user_id uuid;
begin
  for v_user_id in select user_id from public.member loop
    perform private.ensure_wallet_networks(v_user_id);
  end loop;
end $$;
create or replace function private.member_snapshot(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_wallets jsonb;
  v_wallet_networks jsonb;
  v_addresses jsonb;
  v_internal_stoc_balance numeric;
  v_total_stoc_balance numeric;
  v_bnb_balance numeric;
  v_sto_addr text;
  v_direct_count integer;
  v_weekly_reward numeric;
  v_total_referral_reward numeric;
  v_today date := private.kst_date();
  v_week_start date := private.week_start_monday(private.kst_date());
begin
  select * into v_member
    from public.member
   where user_id = p_user_id;

  if not found then
    return 'null'::jsonb;
  end if;

  select coalesce(jsonb_object_agg(x.asset_code, x.available_balance), '{}'::jsonb)
    into v_wallets
    from (
      select asset_code, available_balance
        from public.wallet_accounts
       where user_id = p_user_id
         and account_type = 'internal'
       order by asset_code
    ) x;

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

  select coalesce(jsonb_agg(to_jsonb(x) order by x.chain, x.asset_code), '[]'::jsonb)
    into v_addresses
    from (
      select id, chain, asset_code, address, memo_tag, status, created_at, updated_at
        from public.wallet_addresses
       where user_id = p_user_id
    ) x;

  v_internal_stoc_balance := private.wallet_balance(p_user_id, 'STOC_INT');
  v_bnb_balance := private.wallet_balance(p_user_id, 'BNB');

  select wa.address
    into v_sto_addr
    from public.wallet_addresses wa
   where wa.user_id = p_user_id
     and wa.asset_code in ('STOC_INT', 'STOC')
     and wa.status = 'active'
   order by case wa.asset_code when 'STOC_INT' then 0 else 1 end, wa.created_at
   limit 1;

  select count(*)::integer
    into v_direct_count
    from public.referral_network rn
   where rn.referrer_user_id = p_user_id
     and rn.depth = 1
     and rn.status = 'active';

  select coalesce(sum(t.amount), 0)
    into v_weekly_reward
    from public.transactions t
   where t.receiver_user_id = p_user_id
     and t.status = 'completed'
     and t.asset_code = 'STOC_INT'
     and t.transaction_type in ('ATT_REW', 'attendance_reward', 'roulette_reward', 'collector_reward')
     and private.kst_date(t.created_at) between v_week_start and (v_week_start + 6);

  select coalesce(sum(t.amount), 0)
    into v_total_referral_reward
    from public.transactions t
   where t.receiver_user_id = p_user_id
     and t.status = 'completed'
     and t.asset_code = 'STOC_INT'
     and t.transaction_type = 'referral_reward';

  return to_jsonb(v_member)
    || jsonb_build_object(
      'initial_aidas', v_total_stoc_balance,
      'mb_stoc', v_total_stoc_balance,
      'internalStocBalance', v_internal_stoc_balance,
      'totalStocBalance', v_total_stoc_balance,
      'BNB', v_bnb_balance,
      'initial_bnb', v_bnb_balance,
      'sto_addr', coalesce(v_sto_addr, ''),
      'direct_referral_count', v_direct_count,
      'total_downline_count', v_direct_count,
      'weekly_stoc_reward', v_weekly_reward,
      'total_referral_reward', v_total_referral_reward,
      'wallets', v_wallets,
      'walletNetworks', v_wallet_networks,
      'wallet_networks', v_wallet_networks,
      'wallet_addresses', v_addresses,
      'snapshot_date', v_today
    );
end;
$$;
create or replace function public.rpc_get_home_snapshot()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_member_snapshot jsonb;
  v_today date := private.kst_date();
  v_unread integer;
  v_attendance_checked boolean;
  v_roulette_spin public.roulette_spins%rowtype;
  v_collector public.collector_sessions%rowtype;
  v_collector_phase text := 'ready';
  v_recent_transactions jsonb;
  v_total_stoc_balance numeric;
begin
  v_member := private.require_active_member();
  perform private.ensure_wallet_networks(v_member.user_id);
  v_member_snapshot := private.member_snapshot(v_member.user_id);
  v_total_stoc_balance := coalesce((v_member_snapshot ->> 'totalStocBalance')::numeric, 0::numeric);

  select count(*)::integer
    into v_unread
    from public.notifications
   where user_id = v_member.user_id
     and is_read = false;

  select exists(
    select 1
      from public.user_daily_attendance
     where user_id = v_member.user_id
       and check_date = v_today
  ) into v_attendance_checked;

  select * into v_roulette_spin
    from public.roulette_spins
   where user_id = v_member.user_id
     and spin_date = v_today;

  select * into v_collector
    from public.collector_sessions
   where user_id = v_member.user_id
     and claim_date = v_today;

  if found then
    v_collector_phase := case
      when v_collector.status = 'claimed' then 'completed'
      when now() >= v_collector.unlock_at then 'claimable'
      else 'collecting'
    end;
  end if;

  select coalesce(jsonb_agg(x.row_json order by x.created_at desc), '[]'::jsonb)
    into v_recent_transactions
    from (
      select
        t.created_at,
        to_jsonb(t) || jsonb_build_object(
          'sender_id', sm.mb_id,
          'receiver_id', rm.mb_id,
          'currency_type', t.asset_code
        ) as row_json
      from public.transactions t
      left join public.member sm on sm.user_id = t.sender_user_id
      left join public.member rm on rm.user_id = t.receiver_user_id
      where t.sender_user_id = v_member.user_id
         or t.receiver_user_id = v_member.user_id
      order by t.created_at desc
      limit 10
    ) x;

  return jsonb_build_object(
    'member', v_member_snapshot,
    'initial_aidas', v_total_stoc_balance,
    'totalStocBalance', v_total_stoc_balance,
    'walletNetworks', v_member_snapshot -> 'walletNetworks',
    'unread_notification_count', v_unread,
    'attendance', jsonb_build_object(
      'checkDate', v_today,
      'todayChecked', v_attendance_checked
    ),
    'roulette', jsonb_build_object(
      'spinDate', v_today,
      'alreadySpun', v_roulette_spin.id is not null,
      'spin', case when v_roulette_spin.id is null then null else to_jsonb(v_roulette_spin) end
    ),
    'collector', jsonb_build_object(
      'claimDate', v_today,
      'phase', v_collector_phase,
      'session', case when v_collector.id is null then null else to_jsonb(v_collector) end
    ),
    'recent_transactions', v_recent_transactions
  );
end;
$$;
revoke all on function private.ensure_wallet_networks(uuid) from public, anon, authenticated;
revoke all on function private.ensure_wallet_networks_after_member_insert() from public, anon, authenticated;
revoke all on function public.rpc_get_home_snapshot() from public, anon, authenticated;
grant execute on function public.rpc_get_home_snapshot() to authenticated;
