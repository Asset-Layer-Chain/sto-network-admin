-- Ensure the internal STOC network card uses the effective STOC balance.
-- 006 split wallet data into rpc_get_wallet_summary, but some existing users can have
-- wallet_accounts.STOC_INT = 0 while their completed reward transaction ledger is positive.
-- This migration conservatively backfills missing/zero internal STOC accounts from the
-- completed ledger and makes private.wallet_summary use the same fallback.

with ledger_entries as (
  select
    t.receiver_user_id as user_id,
    t.amount as amount
  from public.transactions t
  where t.status = 'completed'
    and t.asset_code in ('STOC_INT', 'STOC')
    and t.receiver_user_id is not null

  union all

  select
    t.sender_user_id as user_id,
    -1 * (t.amount + coalesce(t.fee_amount, 0)) as amount
  from public.transactions t
  where t.status = 'completed'
    and t.asset_code in ('STOC_INT', 'STOC')
    and t.sender_user_id is not null
), ledger as (
  select
    user_id,
    sum(amount) as ledger_balance
  from ledger_entries
  group by user_id
), positive_ledger as (
  select user_id, greatest(coalesce(ledger_balance, 0), 0::numeric) as ledger_balance
  from ledger
  where coalesce(ledger_balance, 0) > 0
)
insert into public.wallet_accounts (
  user_id,
  chain,
  asset_code,
  account_type,
  available_balance,
  locked_balance
)
select
  user_id,
  'stoc_internal',
  'STOC_INT',
  'internal',
  ledger_balance,
  0
from positive_ledger
on conflict (user_id, asset_code, account_type)
do update set
  chain = coalesce(public.wallet_accounts.chain, excluded.chain),
  available_balance = case
    when coalesce(public.wallet_accounts.available_balance, 0) = 0
      and excluded.available_balance > 0
      then excluded.available_balance
    else public.wallet_accounts.available_balance
  end,
  updated_at = case
    when coalesce(public.wallet_accounts.available_balance, 0) = 0
      and excluded.available_balance > 0
      then now()
    when public.wallet_accounts.chain is null
      then now()
    else public.wallet_accounts.updated_at
  end;
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
  v_internal_account_balance numeric := 0;
  v_internal_ledger_balance numeric := 0;
  v_internal_stoc_balance numeric := 0;
begin
  select coalesce(wa.available_balance, 0::numeric)
    into v_internal_account_balance
    from public.wallet_accounts wa
   where wa.user_id = p_user_id
     and wa.asset_code = 'STOC_INT'
     and wa.account_type = 'internal'
   limit 1;

  v_internal_account_balance := coalesce(v_internal_account_balance, 0::numeric);

  select coalesce(sum(
    case
      when t.receiver_user_id = p_user_id then t.amount
      when t.sender_user_id = p_user_id then -1 * (t.amount + coalesce(t.fee_amount, 0))
      else 0
    end
  ), 0::numeric)
    into v_internal_ledger_balance
    from public.transactions t
   where t.status = 'completed'
     and t.asset_code in ('STOC_INT', 'STOC')
     and (t.receiver_user_id = p_user_id or t.sender_user_id = p_user_id);

  v_internal_stoc_balance := case
    when v_internal_account_balance > 0 then v_internal_account_balance
    when v_internal_ledger_balance > 0 then v_internal_ledger_balance
    else greatest(v_internal_account_balance, 0::numeric)
  end;

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
      case
        when d.asset_code = 'STOC_INT' then v_internal_stoc_balance
        else coalesce(wa.available_balance, 0::numeric)
      end as balance
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
