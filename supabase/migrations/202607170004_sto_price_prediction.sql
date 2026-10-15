-- STO 가격 예측: 1시간 슬롯, GOPAX 1분 캔들 종가 기준 정산
-- 기준 시간대: Asia/Seoul. DB 자체 timezone은 UTC를 유지한다.

create extension if not exists pgcrypto with schema extensions;
create table if not exists public.prediction_market_slots (
  id uuid primary key default extensions.gen_random_uuid(),
  trading_pair text not null default 'STOC-KRW',
  base_at timestamptz not null,
  target_at timestamptz not null,
  base_price numeric(36, 18) not null check (base_price > 0),
  result_price numeric(36, 18),
  result_direction text check (result_direction in ('up', 'down', 'draw')),
  status text not null default 'open'
    check (status in ('open', 'settled', 'draw', 'cancelled')),
  price_source text not null default 'gopax_1m_close',
  settled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint prediction_market_slots_one_hour_check
    check (target_at = base_at + interval '1 hour'),
  unique (trading_pair, base_at)
);
create index if not exists prediction_market_slots_due_idx
  on public.prediction_market_slots(status, target_at)
  where status = 'open';
create trigger prediction_market_slots_set_updated_at
before update on public.prediction_market_slots
for each row execute function public.set_updated_at();
alter table public.prediction_records
  add column if not exists slot_id uuid references public.prediction_market_slots(id) on delete set null,
  add column if not exists trading_pair text not null default 'STOC-KRW',
  add column if not exists base_at timestamptz,
  add column if not exists result_direction text;
update public.prediction_records
set base_at = target_at - interval '1 hour'
where base_at is null;
alter table public.prediction_records
  drop constraint if exists prediction_records_status_check;
alter table public.prediction_records
  add constraint prediction_records_status_check
  check (status in ('pending', 'correct', 'incorrect', 'draw', 'cancelled'));
alter table public.prediction_records
  drop constraint if exists prediction_records_result_direction_check;
alter table public.prediction_records
  add constraint prediction_records_result_direction_check
  check (result_direction is null or result_direction in ('up', 'down', 'draw'));
create unique index if not exists prediction_records_user_slot_uniq
  on public.prediction_records(user_id, slot_id)
  where slot_id is not null;
create index if not exists prediction_records_user_created_idx
  on public.prediction_records(user_id, created_at desc);
alter table public.prediction_market_slots enable row level security;
-- 슬롯 가격은 Edge Function(service_role)과 보안 함수만 변경한다.
revoke all on table public.prediction_market_slots from public, anon, authenticated;
grant select, insert, update on table public.prediction_market_slots to service_role;
-- 기존 prediction_records는 본인 SELECT 정책만 유지하고 INSERT/UPDATE는 RPC만 허용한다.
revoke insert, update, delete on table public.prediction_records from anon, authenticated;
create or replace function public.prediction_kst_hour_start(p_at timestamptz default now())
returns timestamptz
language sql
stable
set search_path = public, pg_temp
as $$
  select date_trunc('hour', p_at at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
$$;
revoke all on function public.prediction_kst_hour_start(timestamptz) from public, anon, authenticated;
grant execute on function public.prediction_kst_hour_start(timestamptz) to service_role;
-- Edge Function 전용: 현재 시간 슬롯과 1분 캔들 기준가를 생성/갱신한다.
create or replace function public.service_upsert_prediction_slot(
  p_trading_pair text,
  p_base_at timestamptz,
  p_target_at timestamptz,
  p_base_price numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_pair text := upper(trim(coalesce(p_trading_pair, '')));
  v_slot public.prediction_market_slots%rowtype;
begin
  if auth.role() <> 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED';
  end if;

  if v_pair !~ '^[A-Z0-9]+-[A-Z0-9]+$' then
    raise exception 'INVALID_TRADING_PAIR';
  end if;

  if p_base_price is null or p_base_price <= 0 then
    raise exception 'INVALID_BASE_PRICE';
  end if;

  if p_base_at <> public.prediction_kst_hour_start(p_base_at)
     or p_target_at <> p_base_at + interval '1 hour' then
    raise exception 'INVALID_PREDICTION_SLOT';
  end if;

  insert into public.prediction_market_slots (
    trading_pair,
    base_at,
    target_at,
    base_price,
    price_source
  )
  values (
    v_pair,
    p_base_at,
    p_target_at,
    p_base_price,
    'gopax_1m_close'
  )
  on conflict (trading_pair, base_at)
  do update set
    base_price = case
      when public.prediction_market_slots.status = 'open'
        then excluded.base_price
      else public.prediction_market_slots.base_price
    end,
    updated_at = now()
  returning * into v_slot;

  return jsonb_build_object(
    'id', v_slot.id,
    'tradingPair', v_slot.trading_pair,
    'baseAt', v_slot.base_at,
    'targetAt', v_slot.target_at,
    'basePrice', v_slot.base_price,
    'status', v_slot.status
  );
end;
$$;
-- Edge Function 전용: 정답 가격을 확정하고 해당 슬롯의 모든 참여 기록을 원자적으로 정산한다.
create or replace function public.service_settle_prediction_slot(
  p_slot_id uuid,
  p_result_price numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_slot public.prediction_market_slots%rowtype;
  v_direction text;
  v_correct integer := 0;
  v_incorrect integer := 0;
  v_draw integer := 0;
begin
  if auth.role() <> 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED';
  end if;

  if p_result_price is null or p_result_price <= 0 then
    raise exception 'INVALID_RESULT_PRICE';
  end if;

  select *
  into v_slot
  from public.prediction_market_slots
  where id = p_slot_id
  for update;

  if not found then
    raise exception 'PREDICTION_SLOT_NOT_FOUND';
  end if;

  if v_slot.status in ('settled', 'draw') then
    return jsonb_build_object(
      'slotId', v_slot.id,
      'alreadySettled', true,
      'resultDirection', v_slot.result_direction,
      'resultPrice', v_slot.result_price
    );
  end if;

  if now() < v_slot.target_at + interval '1 minute' then
    raise exception 'PREDICTION_SLOT_NOT_READY';
  end if;

  v_direction := case
    when p_result_price > v_slot.base_price then 'up'
    when p_result_price < v_slot.base_price then 'down'
    else 'draw'
  end;

  update public.prediction_market_slots
  set
    result_price = p_result_price,
    result_direction = v_direction,
    status = case when v_direction = 'draw' then 'draw' else 'settled' end,
    settled_at = now(),
    updated_at = now()
  where id = v_slot.id;

  update public.prediction_records
  set
    result_price = p_result_price,
    result_direction = v_direction,
    status = case
      when v_direction = 'draw' then 'draw'
      when prediction_direction = v_direction then 'correct'
      else 'incorrect'
    end,
    reward_amount = 0,
    settled_at = now()
  where slot_id = v_slot.id
    and status = 'pending';

  select
    count(*) filter (where status = 'correct'),
    count(*) filter (where status = 'incorrect'),
    count(*) filter (where status = 'draw')
  into v_correct, v_incorrect, v_draw
  from public.prediction_records
  where slot_id = v_slot.id;

  return jsonb_build_object(
    'slotId', v_slot.id,
    'alreadySettled', false,
    'resultDirection', v_direction,
    'basePrice', v_slot.base_price,
    'resultPrice', p_result_price,
    'correctCount', v_correct,
    'incorrectCount', v_incorrect,
    'drawCount', v_draw
  );
end;
$$;
create or replace function public.rpc_submit_price_prediction(
  p_direction text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
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

  select *
  into v_slot
  from public.prediction_market_slots
  where trading_pair = 'STOC-KRW'
    and base_at = v_base_at
  for update;

  if not found then
    raise exception 'PREDICTION_MARKET_NOT_READY';
  end if;

  if v_slot.status <> 'open' or now() >= v_slot.target_at then
    raise exception 'PREDICTION_SLOT_CLOSED';
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
  )
  values (
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
    'direction', v_record.prediction_direction,
    'basePrice', v_record.base_price,
    'baseAt', v_record.base_at,
    'targetAt', v_record.target_at,
    'status', v_record.status
  );
end;
$$;
create or replace function public.rpc_get_price_prediction_dashboard(
  p_history_limit integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_limit integer := greatest(1, least(coalesce(p_history_limit, 30), 100));
  v_base_at timestamptz := public.prediction_kst_hour_start(now());
  v_slot public.prediction_market_slots%rowtype;
  v_current_prediction jsonb;
  v_history jsonb := '[]'::jsonb;
  v_stats jsonb;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select *
  into v_slot
  from public.prediction_market_slots
  where trading_pair = 'STOC-KRW'
    and base_at = v_base_at;

  if found then
    select jsonb_build_object(
      'id', r.id,
      'slotId', r.slot_id,
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
      and r.slot_id = v_slot.id
    limit 1;
  end if;

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
    'stats', v_stats
  );
end;
$$;
revoke all on function public.service_upsert_prediction_slot(text, timestamptz, timestamptz, numeric)
  from public, anon, authenticated;
revoke all on function public.service_settle_prediction_slot(uuid, numeric)
  from public, anon, authenticated;
revoke all on function public.rpc_submit_price_prediction(text)
  from public, anon, authenticated;
revoke all on function public.rpc_get_price_prediction_dashboard(integer)
  from public, anon, authenticated;
grant execute on function public.service_upsert_prediction_slot(text, timestamptz, timestamptz, numeric)
  to service_role;
grant execute on function public.service_settle_prediction_slot(uuid, numeric)
  to service_role;
grant execute on function public.rpc_submit_price_prediction(text)
  to authenticated;
grant execute on function public.rpc_get_price_prediction_dashboard(integer)
  to authenticated;
