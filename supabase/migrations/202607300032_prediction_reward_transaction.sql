-- 032: Price prediction fixed reward payout.
-- A안: 적중 보상은 정답 record 1건당 1 STOC_INT 고정.
-- 적용 범위:
-- 1) 이후 정산되는 correct prediction_records에 reward_amount=1, transaction, wallet credit 생성
-- 2) 이미 correct 되었지만 reward_amount=0 / transaction_id is null 인 기존 record 1회 보정 지급
-- 3) dashboard RPC 응답에 rewardAmount / transactionId 포함

create or replace function private.grant_prediction_reward(
  p_record_id uuid,
  p_reward_amount numeric default 1
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_record public.prediction_records%rowtype;
  v_transaction_id uuid;
  v_idempotency_key text;
  v_balance numeric;
  v_reward_amount numeric := coalesce(p_reward_amount, 1);
begin
  if p_record_id is null then
    raise exception using errcode = '22023', message = 'PREDICTION_RECORD_ID_REQUIRED';
  end if;

  if v_reward_amount <= 0 then
    raise exception using errcode = '22023', message = 'PREDICTION_REWARD_AMOUNT_INVALID';
  end if;

  select *
    into v_record
    from public.prediction_records
   where id = p_record_id
   for update;

  if not found then
    return jsonb_build_object(
      'recordId', p_record_id,
      'status', 'missing'
    );
  end if;

  if v_record.status <> 'correct' then
    return jsonb_build_object(
      'recordId', v_record.id,
      'status', 'skipped_not_correct',
      'predictionStatus', v_record.status
    );
  end if;

  if v_record.transaction_id is not null then
    update public.prediction_records
       set reward_amount = greatest(reward_amount, v_reward_amount)
     where id = v_record.id;

    return jsonb_build_object(
      'recordId', v_record.id,
      'status', 'already_linked',
      'transactionId', v_record.transaction_id,
      'rewardAmount', greatest(v_record.reward_amount, v_reward_amount)
    );
  end if;

  v_idempotency_key := 'prediction-reward:' || v_record.id::text;

  select t.id
    into v_transaction_id
    from public.transactions t
   where t.idempotency_key = v_idempotency_key
   limit 1;

  if found then
    update public.prediction_records
       set reward_amount = greatest(reward_amount, v_reward_amount),
           transaction_id = v_transaction_id
     where id = v_record.id;

    return jsonb_build_object(
      'recordId', v_record.id,
      'status', 'linked_existing_transaction',
      'transactionId', v_transaction_id,
      'rewardAmount', greatest(v_record.reward_amount, v_reward_amount)
    );
  end if;

  v_transaction_id := extensions.gen_random_uuid();
  v_balance := private.credit_wallet(v_record.user_id, 'STOC_INT', v_reward_amount, 'internal');

  insert into public.transactions (
    id,
    sender_user_id,
    receiver_user_id,
    asset_code,
    amount,
    fee_amount,
    transaction_type,
    status,
    description,
    reference_type,
    reference_id,
    idempotency_key,
    metadata,
    processed_at
  ) values (
    v_transaction_id,
    null,
    v_record.user_id,
    'STOC_INT',
    v_reward_amount,
    0,
    'prediction_reward',
    'completed',
    '가격예측 적중 보상',
    'prediction',
    v_record.id,
    v_idempotency_key,
    jsonb_build_object(
      'slot_id', v_record.slot_id,
      'trading_pair', v_record.trading_pair,
      'prediction_direction', v_record.prediction_direction,
      'result_direction', v_record.result_direction,
      'base_price', v_record.base_price,
      'result_price', v_record.result_price,
      'base_at', v_record.base_at,
      'target_at', v_record.target_at,
      'settled_at', v_record.settled_at,
      'reward_amount', v_reward_amount,
      'asset_code', 'STOC_INT',
      'timezone', 'Asia/Seoul'
    ),
    now()
  );

  update public.prediction_records
     set reward_amount = v_reward_amount,
         transaction_id = v_transaction_id
   where id = v_record.id;

  return jsonb_build_object(
    'recordId', v_record.id,
    'status', 'paid',
    'transactionId', v_transaction_id,
    'rewardAmount', v_reward_amount,
    'walletBalance', v_balance
  );
end;
$$;
revoke all on function private.grant_prediction_reward(uuid, numeric)
  from public, anon, authenticated;
-- Edge Function 전용: 정답 가격을 확정하고 해당 슬롯의 모든 참여 기록을 원자적으로 정산한다.
-- 결과 가격이 기준 가격과 같으면 UP 적중으로 처리한다.
create or replace function public.service_settle_prediction_slot(
  p_slot_id uuid,
  p_result_price numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_slot public.prediction_market_slots%rowtype;
  v_direction text;
  v_record record;
  v_reward_result jsonb;
  v_correct integer := 0;
  v_incorrect integer := 0;
  v_draw integer := 0;
  v_rewarded integer := 0;
  v_total_reward numeric := 0;
  v_reward_amount constant numeric := 1;
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
    select
      count(*) filter (where status = 'correct'),
      count(*) filter (where status = 'incorrect'),
      count(*) filter (where status = 'draw'),
      count(*) filter (where status = 'correct' and reward_amount > 0 and transaction_id is not null),
      coalesce(sum(reward_amount) filter (where status = 'correct'), 0)
    into v_correct, v_incorrect, v_draw, v_rewarded, v_total_reward
    from public.prediction_records
    where slot_id = v_slot.id;

    return jsonb_build_object(
      'slotId', v_slot.id,
      'alreadySettled', true,
      'resultDirection', v_slot.result_direction,
      'basePrice', v_slot.base_price,
      'resultPrice', v_slot.result_price,
      'correctCount', v_correct,
      'incorrectCount', v_incorrect,
      'drawCount', v_draw,
      'rewardAmount', v_reward_amount,
      'rewardedCount', v_rewarded,
      'totalRewardAmount', v_total_reward
    );
  end if;

  if now() < v_slot.target_at + interval '1 minute' then
    raise exception 'PREDICTION_SLOT_NOT_READY';
  end if;

  v_direction := case
    when p_result_price >= v_slot.base_price then 'up'
    else 'down'
  end;

  update public.prediction_market_slots
     set result_price = p_result_price,
         result_direction = v_direction,
         status = 'settled',
         settled_at = now(),
         updated_at = now()
   where id = v_slot.id;

  update public.prediction_records
     set result_price = p_result_price,
         result_direction = v_direction,
         status = case
           when prediction_direction = v_direction then 'correct'
           else 'incorrect'
         end,
         reward_amount = case
           when prediction_direction = v_direction then v_reward_amount
           else 0
         end,
         settled_at = now()
   where slot_id = v_slot.id
     and status = 'pending';

  for v_record in
    select id
      from public.prediction_records
     where slot_id = v_slot.id
       and status = 'correct'
     order by created_at
  loop
    v_reward_result := private.grant_prediction_reward(v_record.id, v_reward_amount);
  end loop;

  select
    count(*) filter (where status = 'correct'),
    count(*) filter (where status = 'incorrect'),
    count(*) filter (where status = 'draw'),
    count(*) filter (where status = 'correct' and reward_amount > 0 and transaction_id is not null),
    coalesce(sum(reward_amount) filter (where status = 'correct'), 0)
  into v_correct, v_incorrect, v_draw, v_rewarded, v_total_reward
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
    'drawCount', v_draw,
    'rewardAmount', v_reward_amount,
    'rewardedCount', v_rewarded,
    'totalRewardAmount', v_total_reward
  );
end;
$$;
revoke all on function public.service_settle_prediction_slot(uuid, numeric)
  from public, anon, authenticated;
grant execute on function public.service_settle_prediction_slot(uuid, numeric)
  to service_role;
-- 운영 보정용: 이미 correct 되었지만 보상/거래가 없는 record를 1회 지급한다.
create or replace function public.service_grant_missing_prediction_rewards(
  p_limit integer default 500
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 500), 5000));
  v_record_id uuid;
  v_result jsonb;
  v_processed integer := 0;
  v_paid integer := 0;
  v_linked integer := 0;
  v_skipped integer := 0;
  v_reward_amount constant numeric := 1;
begin
  if auth.role() <> 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED';
  end if;

  for v_record_id in
    select r.id
      from public.prediction_records r
     where r.status = 'correct'
       and coalesce(r.reward_amount, 0) = 0
       and r.transaction_id is null
     order by r.settled_at nulls last, r.created_at
     limit v_limit
  loop
    v_processed := v_processed + 1;
    v_result := private.grant_prediction_reward(v_record_id, v_reward_amount);

    if v_result->>'status' = 'paid' then
      v_paid := v_paid + 1;
    elsif v_result->>'status' in ('linked_existing_transaction', 'already_linked') then
      v_linked := v_linked + 1;
    else
      v_skipped := v_skipped + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'processed', v_processed,
    'paid', v_paid,
    'linked', v_linked,
    'skipped', v_skipped,
    'rewardAmount', v_reward_amount
  );
end;
$$;
revoke all on function public.service_grant_missing_prediction_rewards(integer)
  from public, anon, authenticated;
grant execute on function public.service_grant_missing_prediction_rewards(integer)
  to service_role;
-- 기존에 이미 correct 처리되었지만 reward_amount=0 / transaction_id 없는 record를 migration 적용 시 1회 보정한다.
do $$
declare
  v_record_id uuid;
  v_result jsonb;
  v_backfilled integer := 0;
begin
  for v_record_id in
    select r.id
      from public.prediction_records r
     where r.status = 'correct'
       and coalesce(r.reward_amount, 0) = 0
       and r.transaction_id is null
     order by r.settled_at nulls last, r.created_at
  loop
    v_result := private.grant_prediction_reward(v_record_id, 1);
    if v_result->>'status' in ('paid', 'linked_existing_transaction', 'already_linked') then
      v_backfilled := v_backfilled + 1;
    end if;
  end loop;

  raise notice '032 prediction reward backfilled % record(s)', v_backfilled;
end $$;
-- 기록/현재 예측 응답에 rewardAmount와 transactionId를 포함한다.
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
