-- 025: Collector client target validation + KST midnight reset
-- Price prediction UI/Edge changes are included in the matching web patch.

-- The old no-argument signature must be removed before adding p_target_at.
drop function if exists public.rpc_start_collector();
create or replace function public.rpc_get_collector_status()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_server_now timestamptz := clock_timestamp();
  v_today date := private.kst_date(v_server_now);
  v_reset_at timestamptz := timezone('Asia/Seoul', (v_today + 1)::timestamp);
  v_session public.collector_sessions%rowtype;
  v_phase text;
  v_remaining integer;
begin
  v_member := private.require_active_member();

  -- KST 날짜가 지난 미수령 세션은 다시 사용할 수 없도록 명시적으로 만료한다.
  update public.collector_sessions
     set status = 'expired',
         updated_at = v_server_now
   where user_id = v_member.user_id
     and claim_date < v_today
     and status in ('collecting', 'claimable');

  select * into v_session
    from public.collector_sessions
   where user_id = v_member.user_id
     and claim_date = v_today;

  if not found or v_session.status = 'expired' then
    return jsonb_build_object(
      'serverNow', v_server_now,
      'resetAt', v_reset_at,
      'claimDate', v_today,
      'phase', 'ready',
      'claimed', false,
      'remainingSeconds', 3600,
      'session', null
    );
  end if;

  if v_session.status = 'claimed' then
    v_phase := 'completed';
    v_remaining := 0;
  elsif v_server_now >= v_session.unlock_at then
    v_phase := 'claimable';
    v_remaining := 0;

    if v_session.status <> 'claimable' then
      update public.collector_sessions
         set status = 'claimable', updated_at = v_server_now
       where id = v_session.id
      returning * into v_session;
    end if;
  else
    v_phase := 'collecting';
    v_remaining := greatest(
      0,
      ceil(extract(epoch from (v_session.unlock_at - v_server_now)))::integer
    );
  end if;

  return jsonb_build_object(
    'serverNow', v_server_now,
    'resetAt', v_reset_at,
    'claimDate', v_today,
    'phase', v_phase,
    'claimed', v_phase = 'completed',
    'remainingSeconds', v_remaining,
    'session', to_jsonb(v_session),
    'transaction', case
      when v_session.transaction_id is null then null
      else private.transaction_json(v_session.transaction_id)
    end
  );
end;
$$;
create or replace function public.rpc_start_collector(
  p_target_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_server_now timestamptz := clock_timestamp();
  v_today date := private.kst_date(v_server_now);
  v_reset_at timestamptz := timezone('Asia/Seoul', (v_today + 1)::timestamp);
  v_session public.collector_sessions%rowtype;
  v_phase text;
  v_remaining integer;
  v_target_delay_seconds numeric;
begin
  v_member := private.require_active_member();

  if p_target_at is null then
    raise exception using errcode = '22023', message = 'COLLECTOR_TARGET_REQUIRED';
  end if;

  v_target_delay_seconds := extract(epoch from (p_target_at - v_server_now));

  -- The client may choose the display target, but it cannot shorten the reward wait.
  -- Only a narrow ±30 second transport/clock tolerance is allowed.
  if v_target_delay_seconds < 3570 or v_target_delay_seconds > 3630 then
    raise exception using
      errcode = '22023',
      message = 'COLLECTOR_TARGET_INVALID',
      detail = jsonb_build_object(
        'server_now', v_server_now,
        'target_at', p_target_at,
        'minimum_seconds', 3570,
        'maximum_seconds', 3630,
        'received_seconds', round(v_target_delay_seconds, 3)
      )::text;
  end if;

  update public.collector_sessions
     set status = 'expired',
         updated_at = v_server_now
   where user_id = v_member.user_id
     and claim_date < v_today
     and status in ('collecting', 'claimable');

  perform pg_advisory_xact_lock(
    hashtextextended('collector:' || v_member.user_id::text || ':' || v_today::text, 0)
  );

  select * into v_session
    from public.collector_sessions
   where user_id = v_member.user_id
     and claim_date = v_today
   for update;

  if not found then
    insert into public.collector_sessions (
      user_id,
      claim_date,
      status,
      started_at,
      unlock_at,
      reward_amount
    ) values (
      v_member.user_id,
      v_today,
      'collecting',
      v_server_now,
      p_target_at,
      1
    )
    returning * into v_session;

    return jsonb_build_object(
      'serverNow', v_server_now,
      'resetAt', v_reset_at,
      'alreadyStarted', false,
      'claimDate', v_today,
      'phase', 'collecting',
      'remainingSeconds', greatest(
        0,
        ceil(extract(epoch from (v_session.unlock_at - v_server_now)))::integer
      ),
      'session', to_jsonb(v_session)
    );
  end if;

  -- Defensive recovery for a same-day row that was administratively expired.
  if v_session.status = 'expired' then
    update public.collector_sessions
       set status = 'collecting',
           started_at = v_server_now,
           unlock_at = p_target_at,
           claimed_at = null,
           transaction_id = null,
           reward_amount = 1,
           updated_at = v_server_now
     where id = v_session.id
    returning * into v_session;

    return jsonb_build_object(
      'serverNow', v_server_now,
      'resetAt', v_reset_at,
      'alreadyStarted', false,
      'claimDate', v_today,
      'phase', 'collecting',
      'remainingSeconds', greatest(
        0,
        ceil(extract(epoch from (v_session.unlock_at - v_server_now)))::integer
      ),
      'session', to_jsonb(v_session)
    );
  end if;

  if v_session.status = 'claimed' then
    v_phase := 'completed';
    v_remaining := 0;
  elsif v_server_now >= v_session.unlock_at then
    v_phase := 'claimable';
    v_remaining := 0;

    if v_session.status <> 'claimable' then
      update public.collector_sessions
         set status = 'claimable', updated_at = v_server_now
       where id = v_session.id
      returning * into v_session;
    end if;
  else
    v_phase := 'collecting';
    v_remaining := greatest(
      0,
      ceil(extract(epoch from (v_session.unlock_at - v_server_now)))::integer
    );
  end if;

  return jsonb_build_object(
    'serverNow', v_server_now,
    'resetAt', v_reset_at,
    'alreadyStarted', true,
    'claimDate', v_today,
    'phase', v_phase,
    'remainingSeconds', v_remaining,
    'session', to_jsonb(v_session)
  );
end;
$$;
create or replace function public.rpc_claim_collector(
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_server_now timestamptz := clock_timestamp();
  v_today date := private.kst_date(v_server_now);
  v_reset_at timestamptz := timezone('Asia/Seoul', (v_today + 1)::timestamp);
  v_session public.collector_sessions%rowtype;
  v_transaction_id uuid;
  v_balance numeric;
  v_remaining integer;
begin
  v_member := private.require_active_member();

  update public.collector_sessions
     set status = 'expired',
         updated_at = v_server_now
   where user_id = v_member.user_id
     and claim_date < v_today
     and status in ('collecting', 'claimable');

  perform pg_advisory_xact_lock(
    hashtextextended('collector:' || v_member.user_id::text || ':' || v_today::text, 0)
  );

  select * into v_session
    from public.collector_sessions
   where user_id = v_member.user_id
     and claim_date = v_today
   for update;

  if not found or v_session.status = 'expired' then
    raise exception using errcode = 'P0001', message = 'COLLECTOR_NOT_STARTED';
  end if;

  if v_session.status = 'claimed' then
    return jsonb_build_object(
      'serverNow', v_server_now,
      'resetAt', v_reset_at,
      'alreadyClaimed', true,
      'claimed', true,
      'phase', 'completed',
      'memberInitialAidas', private.wallet_balance(v_member.user_id, 'STOC_INT'),
      'session', to_jsonb(v_session),
      'transaction', case
        when v_session.transaction_id is null then null
        else private.transaction_json(v_session.transaction_id)
      end
    );
  end if;

  if v_server_now < v_session.unlock_at then
    v_remaining := greatest(
      0,
      ceil(extract(epoch from (v_session.unlock_at - v_server_now)))::integer
    );
    raise exception using
      errcode = 'P0001',
      message = 'COLLECTOR_NOT_READY',
      detail = jsonb_build_object('remaining_seconds', v_remaining)::text;
  end if;

  v_transaction_id := gen_random_uuid();
  v_balance := private.credit_wallet(
    v_member.user_id,
    'STOC_INT',
    v_session.reward_amount
  );

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
    v_member.user_id,
    'STOC_INT',
    v_session.reward_amount,
    0,
    'collector_reward',
    'completed',
    '포인트 포인트 수집기',
    'collector',
    v_session.id,
    'collector:' || v_member.user_id::text || ':' || v_today::text,
    jsonb_build_object(
      'request_id', p_idempotency_key,
      'claim_date', v_today,
      'started_at', v_session.started_at,
      'unlock_at', v_session.unlock_at,
      'target_source', 'client_validated',
      'timezone', 'Asia/Seoul'
    ),
    v_server_now
  );

  update public.collector_sessions
     set status = 'claimed',
         claimed_at = v_server_now,
         transaction_id = v_transaction_id,
         updated_at = v_server_now
   where id = v_session.id
  returning * into v_session;

  return jsonb_build_object(
    'serverNow', v_server_now,
    'resetAt', v_reset_at,
    'alreadyClaimed', false,
    'claimed', true,
    'phase', 'completed',
    'memberInitialAidas', v_balance,
    'session', to_jsonb(v_session),
    'transaction', private.transaction_json(v_transaction_id)
  );
end;
$$;
revoke all on function public.rpc_get_collector_status() from public, anon, authenticated;
revoke all on function public.rpc_start_collector(timestamptz) from public, anon, authenticated;
revoke all on function public.rpc_claim_collector(text) from public, anon, authenticated;
grant execute on function public.rpc_get_collector_status() to authenticated;
grant execute on function public.rpc_start_collector(timestamptz) to authenticated;
grant execute on function public.rpc_claim_collector(text) to authenticated;
