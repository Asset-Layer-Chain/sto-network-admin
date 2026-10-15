-- 027: Run GOPAX market sync hourly and move market-data purge to a daily job.
-- Also removes purge side effects from service_record_prediction_market_snapshot so hourly sync stays lightweight.

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
