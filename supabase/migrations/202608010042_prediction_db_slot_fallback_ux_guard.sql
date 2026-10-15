-- 042: DB-only price prediction slot fallback and UX guard.
-- 사용자 액션 중 외부 GOPAX API를 기다리지 않는다.
-- 이미 DB에 저장된 가격/캔들만 사용해 현재 시간 slot을 보정한다.

create or replace function private.ensure_prediction_open_slot_from_db(
  p_trading_pair text default 'STOC-KRW',
  p_base_at timestamptz default null
)
returns public.prediction_market_slots
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_pair text := upper(trim(coalesce(p_trading_pair, 'STOC-KRW')));
  v_base_at timestamptz := coalesce(p_base_at, public.prediction_kst_hour_start(now()));
  v_target_at timestamptz := coalesce(p_base_at, public.prediction_kst_hour_start(now())) + interval '1 hour';
  v_slot public.prediction_market_slots%rowtype;
  v_base_price numeric;
  v_price_source text;
begin
  if v_pair !~ '^[A-Z0-9]+-[A-Z0-9]+$' then
    raise exception 'INVALID_TRADING_PAIR';
  end if;

  -- 이미 시간이 지난 slot은 새로 만들지 않는다. 정산/마감 상태는 호출 RPC에서 판단한다.
  if now() >= v_target_at then
    select *
      into v_slot
      from public.prediction_market_slots
     where trading_pair = v_pair
       and base_at = v_base_at
     limit 1;

    return v_slot;
  end if;

  -- 동일 시간대 slot self-heal 동시 실행을 직렬화한다.
  perform pg_advisory_xact_lock(hashtextextended('prediction-slot:' || v_pair || ':' || v_base_at::text, 0));

  select *
    into v_slot
    from public.prediction_market_slots
   where trading_pair = v_pair
     and base_at = v_base_at
   for update;

  if found then
    return v_slot;
  end if;

  -- 1순위: Cron/Edge가 이미 저장한 현재 정각 기준 candle close.
  select c.close,
         'db_hourly_candle_fallback'
    into v_base_price,
         v_price_source
    from public.prediction_market_candles c
   where c.trading_pair = v_pair
     and c.interval_minutes = 60
     and c.candle_at = v_base_at
     and c.close > 0
   order by c.updated_at desc nulls last,
            c.created_at desc
   limit 1;

  -- 2순위: 현재 시간대에 DB에 저장된 최초 가격 snapshot.
  if v_base_price is null or v_base_price <= 0 then
    select p.price,
           'db_market_price_fallback'
      into v_base_price,
           v_price_source
      from public.prediction_market_prices p
     where p.trading_pair = v_pair
       and p.price_at >= v_base_at
       and p.price_at < v_target_at
       and p.price > 0
     order by p.price_at asc,
              p.created_at asc
     limit 1;
  end if;

  -- DB에 현재 시간 기준 가격이 없으면 예측 준비 중으로 둔다. 외부 API 호출은 하지 않는다.
  if v_base_price is null or v_base_price <= 0 then
    return v_slot;
  end if;

  insert into public.prediction_market_slots (
    trading_pair,
    base_at,
    target_at,
    base_price,
    price_source,
    status
  ) values (
    v_pair,
    v_base_at,
    v_target_at,
    v_base_price,
    v_price_source,
    'open'
  )
  on conflict (trading_pair, base_at)
  do update set
    base_price = case
      when public.prediction_market_slots.status = 'open'
        then excluded.base_price
      else public.prediction_market_slots.base_price
    end,
    price_source = case
      when public.prediction_market_slots.status = 'open'
        then excluded.price_source
      else public.prediction_market_slots.price_source
    end,
    updated_at = now()
  returning * into v_slot;

  return v_slot;
end;
$$;
revoke all on function private.ensure_prediction_open_slot_from_db(text, timestamptz)
  from public, anon, authenticated;
grant execute on function private.ensure_prediction_open_slot_from_db(text, timestamptz)
  to service_role;
create or replace function public.rpc_get_price_prediction_market_state(
  p_trading_pair text default 'STOC-KRW',
  p_chart_limit integer default 8
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_pair text := upper(trim(coalesce(p_trading_pair, 'STOC-KRW')));
  v_limit integer := greatest(2, least(coalesce(p_chart_limit, 8), 48));
  v_base_at timestamptz := public.prediction_kst_hour_start(now());
  v_slot public.prediction_market_slots%rowtype;
  v_latest_price public.prediction_market_prices%rowtype;
  v_chart jsonb := '[]'::jsonb;
  v_slot_ready boolean := false;
  v_status_reason text := 'preparing';
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if v_pair !~ '^[A-Z0-9]+-[A-Z0-9]+$' then
    raise exception 'INVALID_TRADING_PAIR';
  end if;

  v_slot := private.ensure_prediction_open_slot_from_db(v_pair, v_base_at);

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

  v_slot_ready := v_slot.id is not null
    and v_slot.status = 'open'
    and v_slot.base_price > 0
    and now() < v_slot.target_at;

  v_status_reason := case
    when v_slot.id is null then 'preparing'
    when v_slot.status <> 'open' then v_slot.status
    when now() >= v_slot.target_at then 'closed'
    when v_slot.base_price is null or v_slot.base_price <= 0 then 'preparing'
    else 'ready'
  end;

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
    'marketReady', v_slot_ready,
    'statusReason', v_status_reason,
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
      'priceSource', v_slot.price_source,
      'canPredict', v_slot_ready
    ) end
  );
end;
$$;
revoke all on function public.rpc_get_price_prediction_market_state(text, integer)
  from public, anon;
grant execute on function public.rpc_get_price_prediction_market_state(text, integer)
  to authenticated;
create or replace function public.rpc_submit_price_prediction(
  p_direction text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_direction text := lower(trim(coalesce(p_direction, '')));
  v_base_at timestamptz := public.prediction_kst_hour_start(now());
  v_slot public.prediction_market_slots%rowtype;
  v_record public.prediction_records%rowtype;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if v_direction not in ('up', 'down') then
    raise exception 'INVALID_PREDICTION_DIRECTION';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text || ':' || v_base_at::text, 0));

  v_slot := private.ensure_prediction_open_slot_from_db('STOC-KRW', v_base_at);

  select *
    into v_slot
    from public.prediction_market_slots
   where trading_pair = 'STOC-KRW'
     and base_at = v_base_at
   for update;

  if not found or v_slot.id is null then
    raise exception 'PREDICTION_MARKET_NOT_READY';
  end if;

  if v_slot.status <> 'open' or now() >= v_slot.target_at then
    raise exception 'PREDICTION_SLOT_CLOSED';
  end if;

  if v_slot.base_price is null or v_slot.base_price <= 0 then
    raise exception 'PREDICTION_MARKET_NOT_READY';
  end if;

  insert into public.prediction_records (
    user_id,
    slot_id,
    trading_pair,
    token_symbol,
    prediction_direction,
    base_price,
    base_at,
    target_at,
    status,
    reward_amount
  ) values (
    v_user_id,
    v_slot.id,
    v_slot.trading_pair,
    split_part(v_slot.trading_pair, '-', 1),
    v_direction,
    v_slot.base_price,
    v_slot.base_at,
    v_slot.target_at,
    'pending',
    0
  )
  on conflict (user_id, slot_id) where slot_id is not null
  do nothing
  returning * into v_record;

  if not found then
    raise exception 'PREDICTION_ALREADY_SUBMITTED';
  end if;

  return jsonb_build_object(
    'id', v_record.id,
    'slotId', v_record.slot_id,
    'tradingPair', v_record.trading_pair,
    'direction', v_record.prediction_direction,
    'basePrice', v_record.base_price,
    'baseAt', v_record.base_at,
    'targetAt', v_record.target_at,
    'status', v_record.status
  );
end;
$$;
revoke all on function public.rpc_submit_price_prediction(text)
  from public, anon, authenticated;
grant execute on function public.rpc_submit_price_prediction(text)
  to authenticated;
create or replace function public.rpc_get_price_prediction_dashboard(
  p_history_limit integer default 30,
  p_history_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
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
  v_can_predict boolean := false;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  v_slot := private.ensure_prediction_open_slot_from_db('STOC-KRW', v_base_at);

  select jsonb_build_object(
    'id', r.id,
    'slotId', r.slot_id,
    'tradingPair', r.trading_pair,
    'direction', r.prediction_direction,
    'status', r.status,
    'basePrice', r.base_price,
    'resultPrice', r.result_price,
    'resultDirection', r.result_direction,
    'rewardAmount', r.reward_amount,
    'transactionId', r.transaction_id,
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

  v_can_predict := v_slot.id is not null
    and v_slot.status = 'open'
    and v_slot.base_price > 0
    and now() < v_slot.target_at
    and v_current_prediction is null;

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
          'rewardAmount', r.reward_amount,
          'transactionId', r.transaction_id,
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
    'rewardTotal', coalesce(sum(reward_amount) filter (where status = 'correct'), 0),
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
      'priceSource', v_slot.price_source,
      'canPredict', v_can_predict
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
  to authenticated;
notify pgrst, 'reload schema';
