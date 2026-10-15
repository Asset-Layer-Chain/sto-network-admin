-- 026: Price prediction DB-first market state + 15-day market data retention.
-- prediction_records is kept permanently and stores enough snapshot fields to render without prediction_market_slots.

create table if not exists public.prediction_market_prices (
  id uuid primary key default extensions.gen_random_uuid(),
  trading_pair text not null default 'STOC-KRW',
  price numeric(36, 18) not null check (price > 0),
  price_at timestamptz not null,
  source text not null default 'gopax_ticker',
  created_at timestamptz not null default now(),
  unique (trading_pair, price_at)
);
create index if not exists prediction_market_prices_pair_at_idx
  on public.prediction_market_prices(trading_pair, price_at desc);
create table if not exists public.prediction_market_candles (
  id uuid primary key default extensions.gen_random_uuid(),
  trading_pair text not null default 'STOC-KRW',
  interval_minutes integer not null default 60 check (interval_minutes > 0),
  candle_at timestamptz not null,
  open numeric(36, 18) not null check (open > 0),
  high numeric(36, 18) not null check (high > 0),
  low numeric(36, 18) not null check (low > 0),
  close numeric(36, 18) not null check (close > 0),
  volume numeric(36, 18) not null default 0 check (volume >= 0),
  source text not null default 'gopax_1m_close_hourly_forward_fill',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (trading_pair, interval_minutes, candle_at)
);
create index if not exists prediction_market_candles_pair_at_idx
  on public.prediction_market_candles(trading_pair, interval_minutes, candle_at desc);
create trigger prediction_market_candles_set_updated_at
before update on public.prediction_market_candles
for each row execute function public.set_updated_at();
alter table public.prediction_market_prices enable row level security;
alter table public.prediction_market_candles enable row level security;
revoke all on table public.prediction_market_prices from public, anon, authenticated;
revoke all on table public.prediction_market_candles from public, anon, authenticated;
grant select, insert, update, delete on table public.prediction_market_prices to service_role;
grant select, insert, update, delete on table public.prediction_market_candles to service_role;
-- Keep display-critical snapshots on prediction_records before market slots can be purged.
update public.prediction_records r
set
  trading_pair = coalesce(nullif(r.trading_pair, ''), s.trading_pair, 'STOC-KRW'),
  base_at = coalesce(r.base_at, s.base_at),
  target_at = coalesce(r.target_at, s.target_at),
  base_price = coalesce(r.base_price, s.base_price),
  result_price = coalesce(r.result_price, s.result_price),
  result_direction = coalesce(r.result_direction, s.result_direction),
  settled_at = coalesce(r.settled_at, s.settled_at)
from public.prediction_market_slots s
where r.slot_id = s.id;
create or replace function public.service_purge_prediction_market_data(
  p_retention_days integer default 15
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_days integer := greatest(1, least(coalesce(p_retention_days, 15), 365));
  v_cutoff timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_retention_days, 15), 365)));
  v_records_backfilled integer := 0;
  v_prices_deleted integer := 0;
  v_candles_deleted integer := 0;
  v_slots_deleted integer := 0;
begin
  if auth.role() <> 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED';
  end if;

  update public.prediction_records r
  set
    trading_pair = coalesce(nullif(r.trading_pair, ''), s.trading_pair, 'STOC-KRW'),
    base_at = coalesce(r.base_at, s.base_at),
    target_at = coalesce(r.target_at, s.target_at),
    base_price = coalesce(r.base_price, s.base_price),
    result_price = coalesce(r.result_price, s.result_price),
    result_direction = coalesce(r.result_direction, s.result_direction),
    settled_at = coalesce(r.settled_at, s.settled_at)
  from public.prediction_market_slots s
  where r.slot_id = s.id
    and s.target_at < v_cutoff;
  get diagnostics v_records_backfilled = row_count;

  delete from public.prediction_market_prices
  where price_at < v_cutoff;
  get diagnostics v_prices_deleted = row_count;

  delete from public.prediction_market_candles
  where candle_at < v_cutoff;
  get diagnostics v_candles_deleted = row_count;

  -- prediction_records.slot_id is ON DELETE SET NULL. Records remain renderable from their own snapshot columns.
  delete from public.prediction_market_slots
  where target_at < v_cutoff;
  get diagnostics v_slots_deleted = row_count;

  return jsonb_build_object(
    'retentionDays', v_days,
    'cutoff', v_cutoff,
    'recordsBackfilled', v_records_backfilled,
    'pricesDeleted', v_prices_deleted,
    'candlesDeleted', v_candles_deleted,
    'slotsDeleted', v_slots_deleted
  );
end;
$$;
revoke all on function public.service_purge_prediction_market_data(integer) from public, anon, authenticated;
grant execute on function public.service_purge_prediction_market_data(integer) to service_role;
create or replace function public.service_record_prediction_market_snapshot(
  p_trading_pair text,
  p_price numeric,
  p_price_at timestamptz,
  p_chart_points jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_pair text := upper(trim(coalesce(p_trading_pair, '')));
  v_point jsonb;
  v_at timestamptz;
  v_open numeric;
  v_high numeric;
  v_low numeric;
  v_close numeric;
  v_volume numeric;
  v_candles_upserted integer := 0;
begin
  if auth.role() <> 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED';
  end if;

  if v_pair !~ '^[A-Z0-9]+-[A-Z0-9]+$' then
    raise exception 'INVALID_TRADING_PAIR';
  end if;

  if p_price is not null and p_price > 0 and p_price_at is not null then
    insert into public.prediction_market_prices (
      trading_pair,
      price,
      price_at,
      source
    ) values (
      v_pair,
      p_price,
      p_price_at,
      'gopax_ticker'
    )
    on conflict (trading_pair, price_at)
    do update set
      price = excluded.price,
      source = excluded.source;
  end if;

  if jsonb_typeof(coalesce(p_chart_points, '[]'::jsonb)) = 'array' then
    for v_point in select value from jsonb_array_elements(p_chart_points)
    loop
      begin
        v_at := nullif(v_point->>'at', '')::timestamptz;
        v_open := nullif(v_point->>'open', '')::numeric;
        v_high := nullif(v_point->>'high', '')::numeric;
        v_low := nullif(v_point->>'low', '')::numeric;
        v_close := nullif(v_point->>'close', '')::numeric;
        v_volume := coalesce(nullif(v_point->>'volume', '')::numeric, 0);
      exception when others then
        continue;
      end;

      if v_at is null
        or v_open is null or v_open <= 0
        or v_high is null or v_high <= 0
        or v_low is null or v_low <= 0
        or v_close is null or v_close <= 0
      then
        continue;
      end if;

      insert into public.prediction_market_candles (
        trading_pair,
        interval_minutes,
        candle_at,
        open,
        high,
        low,
        close,
        volume,
        source
      ) values (
        v_pair,
        60,
        v_at,
        v_open,
        greatest(v_high, v_open, v_close),
        least(v_low, v_open, v_close),
        v_close,
        greatest(v_volume, 0),
        'gopax_1m_close_hourly_forward_fill'
      )
      on conflict (trading_pair, interval_minutes, candle_at)
      do update set
        open = excluded.open,
        high = excluded.high,
        low = excluded.low,
        close = excluded.close,
        volume = excluded.volume,
        source = excluded.source,
        updated_at = now();

      v_candles_upserted := v_candles_upserted + 1;
    end loop;
  end if;

  return jsonb_build_object(
    'tradingPair', v_pair,
    'priceAt', p_price_at,
    'candlesUpserted', v_candles_upserted
  );
end;
$$;
revoke all on function public.service_record_prediction_market_snapshot(text, numeric, timestamptz, jsonb)
  from public, anon, authenticated;
grant execute on function public.service_record_prediction_market_snapshot(text, numeric, timestamptz, jsonb)
  to service_role;
create or replace function public.rpc_get_price_prediction_market_state(
  p_trading_pair text default 'STOC-KRW',
  p_chart_limit integer default 8
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_pair text := upper(trim(coalesce(p_trading_pair, 'STOC-KRW')));
  v_limit integer := greatest(2, least(coalesce(p_chart_limit, 8), 48));
  v_base_at timestamptz := public.prediction_kst_hour_start(now());
  v_slot public.prediction_market_slots%rowtype;
  v_latest_price public.prediction_market_prices%rowtype;
  v_chart jsonb := '[]'::jsonb;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if v_pair !~ '^[A-Z0-9]+-[A-Z0-9]+$' then
    raise exception 'INVALID_TRADING_PAIR';
  end if;

  select *
  into v_slot
  from public.prediction_market_slots
  where trading_pair = v_pair
    and base_at = v_base_at;

  select *
  into v_latest_price
  from public.prediction_market_prices
  where trading_pair = v_pair
  order by price_at desc
  limit 1;

  select coalesce(jsonb_agg(item order by candle_at asc), '[]'::jsonb)
  into v_chart
  from (
    select
      candle_at,
      jsonb_build_object(
        'at', candle_at,
        'open', open,
        'high', high,
        'low', low,
        'close', close,
        'volume', volume
      ) as item
    from public.prediction_market_candles
    where trading_pair = v_pair
      and interval_minutes = 60
    order by candle_at desc
    limit v_limit
  ) candles;

  return jsonb_build_object(
    'tradingPair', v_pair,
    'timeZone', 'Asia/Seoul',
    'serverNow', now(),
    'currentPrice', coalesce(v_latest_price.price, v_slot.base_price, 0),
    'priceAt', v_latest_price.price_at,
    'stale', v_latest_price.price_at is null or v_latest_price.price_at < now() - interval '2 minutes',
    'baseAt', coalesce(v_slot.base_at, v_base_at),
    'targetAt', coalesce(v_slot.target_at, v_base_at + interval '1 hour'),
    'basePrice', v_slot.base_price,
    'marketReady', v_slot.id is not null and v_slot.status = 'open',
    'chartSampling', 'db_hourly_forward_fill',
    'chartPoints', v_chart,
    'slot', case when v_slot.id is null then null else jsonb_build_object(
      'id', v_slot.id,
      'tradingPair', v_slot.trading_pair,
      'baseAt', v_slot.base_at,
      'targetAt', v_slot.target_at,
      'basePrice', v_slot.base_price,
      'resultPrice', v_slot.result_price,
      'resultDirection', v_slot.result_direction,
      'status', v_slot.status,
      'canPredict', v_slot.status = 'open' and now() < v_slot.target_at
    ) end
  );
end;
$$;
revoke all on function public.rpc_get_price_prediction_market_state(text, integer)
  from public, anon;
grant execute on function public.rpc_get_price_prediction_market_state(text, integer)
  to authenticated, service_role;
drop function if exists public.rpc_get_price_prediction_dashboard(integer);
create or replace function public.rpc_get_price_prediction_dashboard(
  p_history_limit integer default 30,
  p_history_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_limit integer := greatest(1, least(coalesce(p_history_limit, 30), 100));
  v_offset integer := greatest(0, coalesce(p_history_offset, 0));
  v_base_at timestamptz := public.prediction_kst_hour_start(now());
  v_slot public.prediction_market_slots%rowtype;
  v_current_prediction jsonb;
  v_history jsonb := '[]'::jsonb;
  v_stats jsonb;
  v_history_count integer := 0;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select *
  into v_slot
  from public.prediction_market_slots
  where trading_pair = 'STOC-KRW'
    and base_at = v_base_at;

  select jsonb_build_object(
    'id', r.id,
    'slotId', r.slot_id,
    'tradingPair', r.trading_pair,
    'direction', r.prediction_direction,
    'status', r.status,
    'basePrice', r.base_price,
    'resultPrice', r.result_price,
    'resultDirection', r.result_direction,
    'baseAt', r.base_at,
    'targetAt', r.target_at,
    'createdAt', r.created_at,
    'settledAt', r.settled_at
  )
  into v_current_prediction
  from public.prediction_records r
  where r.user_id = v_user_id
    and r.trading_pair = 'STOC-KRW'
    and r.base_at = v_base_at
  order by r.created_at desc
  limit 1;

  select count(*)
  into v_history_count
  from public.prediction_records
  where user_id = v_user_id;

  select coalesce(jsonb_agg(item order by item_created_at desc), '[]'::jsonb)
  into v_history
  from (
    select
      r.created_at as item_created_at,
      jsonb_build_object(
        'id', r.id,
        'slotId', r.slot_id,
        'tradingPair', r.trading_pair,
        'direction', r.prediction_direction,
        'status', r.status,
        'basePrice', r.base_price,
        'resultPrice', r.result_price,
        'resultDirection', r.result_direction,
        'baseAt', r.base_at,
        'targetAt', r.target_at,
        'createdAt', r.created_at,
        'settledAt', r.settled_at
      ) as item
    from public.prediction_records r
    where r.user_id = v_user_id
    order by r.created_at desc
    limit v_limit
    offset v_offset
  ) history_rows;

  select jsonb_build_object(
    'total', count(*) filter (where status <> 'cancelled'),
    'pending', count(*) filter (where status = 'pending'),
    'correct', count(*) filter (where status = 'correct'),
    'incorrect', count(*) filter (where status = 'incorrect'),
    'draw', count(*) filter (where status = 'draw'),
    'accuracy', case
      when count(*) filter (where status in ('correct', 'incorrect')) = 0 then 0
      else round(
        (count(*) filter (where status = 'correct'))::numeric
        * 100
        / (count(*) filter (where status in ('correct', 'incorrect')))::numeric,
        1
      )
    end
  )
  into v_stats
  from public.prediction_records
  where user_id = v_user_id;

  return jsonb_build_object(
    'serverNow', now(),
    'timeZone', 'Asia/Seoul',
    'currentSlot', case when v_slot.id is null then null else jsonb_build_object(
      'id', v_slot.id,
      'tradingPair', v_slot.trading_pair,
      'baseAt', v_slot.base_at,
      'targetAt', v_slot.target_at,
      'basePrice', v_slot.base_price,
      'resultPrice', v_slot.result_price,
      'resultDirection', v_slot.result_direction,
      'status', v_slot.status,
      'canPredict', v_slot.status = 'open'
        and now() < v_slot.target_at
        and v_current_prediction is null
    ) end,
    'currentPrediction', v_current_prediction,
    'history', v_history,
    'historyPaging', jsonb_build_object(
      'limit', v_limit,
      'offset', v_offset,
      'total', v_history_count,
      'hasMore', v_offset + v_limit < v_history_count
    ),
    'stats', v_stats
  );
end;
$$;
revoke all on function public.rpc_get_price_prediction_dashboard(integer, integer)
  from public, anon;
grant execute on function public.rpc_get_price_prediction_dashboard(integer, integer)
  to authenticated, service_role;
notify pgrst, 'reload schema';
