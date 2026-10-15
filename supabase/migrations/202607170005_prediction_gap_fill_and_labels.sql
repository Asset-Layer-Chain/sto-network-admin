-- STO 가격 예측 무거래 시간 보간 / 동점 UP 처리 / 혜택 명칭 정리
-- 202607170004_sto_price_prediction.sql 적용 후 실행한다.

-- 기존 거래내역에 저장된 노출 문구를 새 명칭으로 정리한다.
update public.transactions
set description = '돌림판'
where transaction_type = 'roulette_reward'
  and description is distinct from '돌림판';
update public.transactions
set description = '포인트 수집기'
where transaction_type = 'collector_reward'
  and description is distinct from '포인트 수집기';
-- 기존에 배포된 보상 RPC가 이전 설명을 넣더라도 거래내역에는 새 문구로 저장한다.
create or replace function public.normalize_benefit_transaction_description()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.transaction_type = 'roulette_reward' then
    new.description := '돌림판';
  elsif new.transaction_type = 'collector_reward' then
    new.description := '포인트 수집기';
  end if;
  return new;
end;
$$;
drop trigger if exists transactions_normalize_benefit_description
  on public.transactions;
create trigger transactions_normalize_benefit_description
before insert or update of transaction_type, description
on public.transactions
for each row
execute function public.normalize_benefit_transaction_description();
revoke all on function public.normalize_benefit_transaction_description()
  from public, anon, authenticated;
-- 결과 가격이 기준 가격과 같으면 UP 적중으로 처리한다.
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
    when p_result_price >= v_slot.base_price then 'up'
    else 'down'
  end;

  update public.prediction_market_slots
  set
    result_price = p_result_price,
    result_direction = v_direction,
    status = 'settled',
    settled_at = now(),
    updated_at = now()
  where id = v_slot.id;

  update public.prediction_records
  set
    result_price = p_result_price,
    result_direction = v_direction,
    status = case
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
revoke all on function public.service_settle_prediction_slot(uuid, numeric)
  from public, anon, authenticated;
grant execute on function public.service_settle_prediction_slot(uuid, numeric)
  to service_role;
notify pgrst, 'reload schema';
