-- ============================================================================
-- STO Network - Supabase RPC core migration v1
-- 전제: supabase_schema_draft_v0.sql 적용 후 실행
-- 기준 자산 코드: STOC_INT / BNB
-- 일일 기준 시간대: Asia/Seoul
-- ============================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
-- 대소문자만 다른 회원 ID / 추천 코드 중복 방지
create unique index if not exists member_mb_id_lower_uidx
  on public.member (lower(mb_id));
create unique index if not exists member_referral_code_lower_uidx
  on public.member (lower(referral_code));
-- ---------------------------------------------------------------------------
-- 보호 테이블은 클라이언트 직접 쓰기 금지
-- ---------------------------------------------------------------------------
revoke insert, update, delete on public.member from anon, authenticated;
revoke insert, update, delete on public.member_devices from anon, authenticated;
revoke insert, update, delete on public.wallet_accounts from anon, authenticated;
revoke insert, update, delete on public.wallet_addresses from anon, authenticated;
revoke insert, update, delete on public.transactions from anon, authenticated;
revoke insert, update, delete on public.user_daily_attendance from anon, authenticated;
revoke insert, update, delete on public.roulette_spins from anon, authenticated;
revoke insert, update, delete on public.collector_sessions from anon, authenticated;
revoke insert, update, delete on public.referral_network from anon, authenticated;
revoke insert, update, delete on public.notifications from anon, authenticated;
revoke insert, update, delete on public.event_participants from anon, authenticated;
-- ============================================================================
-- private helper functions
-- ============================================================================

create or replace function private.kst_date(p_at timestamptz default now())
returns date
language sql
stable
set search_path = public, pg_temp
as $$
  select timezone('Asia/Seoul', p_at)::date;
$$;
create or replace function private.week_start_monday(p_date date)
returns date
language sql
immutable
set search_path = public, pg_temp
as $$
  select p_date - (extract(isodow from p_date)::integer - 1);
$$;
create or replace function private.require_active_member()
returns public.member
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_member public.member%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  select *
    into v_member
    from public.member
   where user_id = v_user_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'MEMBER_NOT_FOUND';
  end if;

  if v_member.status <> 'active' then
    raise exception using errcode = 'P0001', message = 'MEMBER_NOT_ACTIVE';
  end if;

  return v_member;
end;
$$;
create or replace function private.wallet_balance(
  p_user_id uuid,
  p_asset_code text,
  p_account_type text default 'internal'
)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((
    select available_balance
      from public.wallet_accounts
     where user_id = p_user_id
       and asset_code = upper(trim(p_asset_code))
       and account_type = p_account_type
  ), 0::numeric);
$$;
create or replace function private.credit_wallet(
  p_user_id uuid,
  p_asset_code text,
  p_amount numeric,
  p_account_type text default 'internal'
)
returns numeric
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_balance numeric;
  v_asset_code text := upper(trim(p_asset_code));
begin
  if p_amount <= 0 then
    raise exception using errcode = '22023', message = 'CREDIT_AMOUNT_MUST_BE_POSITIVE';
  end if;

  insert into public.wallet_accounts (
    user_id,
    asset_code,
    account_type,
    available_balance,
    locked_balance
  ) values (
    p_user_id,
    v_asset_code,
    p_account_type,
    p_amount,
    0
  )
  on conflict (user_id, asset_code, account_type)
  do update set
    available_balance = wallet_accounts.available_balance + excluded.available_balance,
    updated_at = now()
  returning available_balance into v_balance;

  return v_balance;
end;
$$;
create or replace function private.transaction_json(p_transaction_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((
    select to_jsonb(t)
      || jsonb_build_object(
        'sender_id', sm.mb_id,
        'receiver_id', rm.mb_id,
        'currency_type', t.asset_code
      )
      from public.transactions t
      left join public.member sm on sm.user_id = t.sender_user_id
      left join public.member rm on rm.user_id = t.receiver_user_id
     where t.id = p_transaction_id
  ), 'null'::jsonb);
$$;
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
  v_addresses jsonb;
  v_stoc_balance numeric;
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

  select coalesce(jsonb_agg(to_jsonb(x) order by x.chain, x.asset_code), '[]'::jsonb)
    into v_addresses
    from (
      select id, chain, asset_code, address, memo_tag, status, created_at, updated_at
        from public.wallet_addresses
       where user_id = p_user_id
    ) x;

  v_stoc_balance := private.wallet_balance(p_user_id, 'STOC_INT');
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
      'initial_aidas', v_stoc_balance,
      'mb_stoc', v_stoc_balance,
      'BNB', v_bnb_balance,
      'initial_bnb', v_bnb_balance,
      'sto_addr', coalesce(v_sto_addr, ''),
      'direct_referral_count', v_direct_count,
      'total_downline_count', v_direct_count,
      'weekly_stoc_reward', v_weekly_reward,
      'total_referral_reward', v_total_referral_reward,
      'wallets', v_wallets,
      'wallet_addresses', v_addresses,
      'snapshot_date', v_today
    );
end;
$$;
create or replace function private.weekly_attendance_json(
  p_user_id uuid,
  p_anchor_date date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_check_date date := coalesce(p_anchor_date, private.kst_date());
  v_week_start date;
  v_rows jsonb;
  v_attendance_days integer;
  v_weekly_reward numeric;
  v_today_checked boolean;
  v_mb_id text;
begin
  v_week_start := private.week_start_monday(v_check_date);

  select mb_id into v_mb_id
    from public.member
   where user_id = p_user_id;

  select
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', a.id,
          'user_id', a.user_id,
          'mb_id', v_mb_id,
          'check_date', a.check_date,
          'week_start', a.week_start,
          'day_of_week', a.day_of_week,
          'is_checked', true,
          'check_time', a.checked_at,
          'checked_at', a.checked_at,
          'reward_amount', a.reward_amount,
          'transaction_id', a.transaction_id,
          'created_at', a.created_at
        ) order by a.check_date
      ),
      '[]'::jsonb
    ),
    count(*)::integer,
    coalesce(sum(a.reward_amount), 0),
    coalesce(bool_or(a.check_date = v_check_date), false)
  into v_rows, v_attendance_days, v_weekly_reward, v_today_checked
  from public.user_daily_attendance a
  where a.user_id = p_user_id
    and a.week_start = v_week_start;

  return jsonb_build_object(
    'rows', v_rows,
    'checkDate', v_check_date,
    'weekStart', v_week_start,
    'attendanceDays', least(v_attendance_days, 7),
    'remainingDays', greatest(0, 7 - v_attendance_days),
    'weeklyReward', v_weekly_reward,
    'todayChecked', v_today_checked
  );
end;
$$;
-- helper 함수 직접 실행 금지
revoke all on function private.kst_date(timestamptz) from public, anon, authenticated;
revoke all on function private.week_start_monday(date) from public, anon, authenticated;
revoke all on function private.require_active_member() from public, anon, authenticated;
revoke all on function private.wallet_balance(uuid, text, text) from public, anon, authenticated;
revoke all on function private.credit_wallet(uuid, text, numeric, text) from public, anon, authenticated;
revoke all on function private.transaction_json(uuid) from public, anon, authenticated;
revoke all on function private.member_snapshot(uuid) from public, anon, authenticated;
revoke all on function private.weekly_attendance_json(uuid, date) from public, anon, authenticated;
-- ============================================================================
-- 1. 회원 초기화
-- ============================================================================

create or replace function public.rpc_bootstrap_member(
  p_referral_code text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_auth_user auth.users%rowtype;
  v_member public.member%rowtype;
  v_referrer public.member%rowtype;
  v_referral_input text;
  v_base_id text;
  v_member_id text;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('bootstrap:' || v_user_id::text, 0));

  select * into v_auth_user
    from auth.users
   where id = v_user_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'AUTH_USER_NOT_FOUND';
  end if;

  v_base_id := nullif(
    lower(regexp_replace(split_part(coalesce(v_auth_user.email, 'user'), '@', 1), '[^a-zA-Z0-9._-]', '', 'g')),
    ''
  );

  v_member_id := left(
    coalesce(
      nullif(v_auth_user.raw_user_meta_data ->> 'mb_id', ''),
      v_base_id,
      'user'
    ),
    30
  ) || '_' || left(replace(v_user_id::text, '-', ''), 6);

  insert into public.member (
    user_id,
    mb_id,
    mb_name,
    mb_email,
    mb_profile,
    referral_code,
    google_linked,
    google_id,
    marketing_agreed,
    reg_channel,
    last_login_at
  ) values (
    v_user_id,
    v_member_id,
    coalesce(
      nullif(v_auth_user.raw_user_meta_data ->> 'full_name', ''),
      nullif(v_auth_user.raw_user_meta_data ->> 'name', ''),
      v_auth_user.email,
      'STO User'
    ),
    coalesce(v_auth_user.email, v_user_id::text || '@no-email.local'),
    coalesce(
      nullif(v_auth_user.raw_user_meta_data ->> 'avatar_url', ''),
      nullif(v_auth_user.raw_user_meta_data ->> 'picture', '')
    ),
    upper(left(replace(v_user_id::text, '-', ''), 10)),
    coalesce(v_auth_user.raw_app_meta_data ->> 'provider', '') = 'google',
    case
      when coalesce(v_auth_user.raw_app_meta_data ->> 'provider', '') = 'google'
      then coalesce(v_auth_user.raw_user_meta_data ->> 'sub', v_user_id::text)
      else null
    end,
    lower(coalesce(v_auth_user.raw_user_meta_data ->> 'marketing_agreed', 'false')) = 'true',
    coalesce(nullif(v_auth_user.raw_user_meta_data ->> 'reg_channel', ''), 'web'),
    now()
  )
  on conflict (user_id)
  do update set
    last_login_at = now(),
    google_linked = excluded.google_linked or member.google_linked,
    google_id = coalesce(member.google_id, excluded.google_id),
    mb_profile = coalesce(excluded.mb_profile, member.mb_profile),
    updated_at = now()
  returning * into v_member;

  insert into public.wallet_accounts (user_id, asset_code, account_type)
  values
    (v_user_id, 'STOC_INT', 'internal'),
    (v_user_id, 'BNB', 'internal')
  on conflict (user_id, asset_code, account_type) do nothing;

  v_referral_input := nullif(trim(coalesce(
    p_referral_code,
    v_auth_user.raw_user_meta_data ->> 'referral_code'
  )), '');

  if v_referral_input is not null and v_member.referrer_user_id is null then
    select m.*
      into v_referrer
      from public.member m
     where m.user_id <> v_user_id
       and m.status = 'active'
       and (
         lower(m.referral_code) = lower(v_referral_input)
         or lower(m.mb_id) = lower(v_referral_input)
       )
     order by case when lower(m.referral_code) = lower(v_referral_input) then 0 else 1 end
     limit 1;

    if found then
      update public.member
         set referrer_user_id = v_referrer.user_id,
             updated_at = now()
       where user_id = v_user_id
         and referrer_user_id is null
      returning * into v_member;

      insert into public.referral_network (
        referrer_user_id,
        referred_user_id,
        depth,
        status
      ) values (
        v_referrer.user_id,
        v_user_id,
        1,
        'active'
      )
      on conflict (referrer_user_id, referred_user_id, depth)
      do update set status = 'active';
    end if;
  end if;

  return jsonb_build_object(
    'member', private.member_snapshot(v_user_id),
    'initialized', true
  );
end;
$$;
-- ============================================================================
-- 2. 홈 데이터 통합 조회
-- ============================================================================

create or replace function public.rpc_get_home_snapshot()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_today date := private.kst_date();
  v_unread integer;
  v_attendance_checked boolean;
  v_roulette_spin public.roulette_spins%rowtype;
  v_collector public.collector_sessions%rowtype;
  v_collector_phase text := 'ready';
  v_recent_transactions jsonb;
begin
  v_member := private.require_active_member();

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
    'member', private.member_snapshot(v_member.user_id),
    'initial_aidas', private.wallet_balance(v_member.user_id, 'STOC_INT'),
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
-- ============================================================================
-- 3. 주간 출석 조회
-- ============================================================================

create or replace function public.rpc_get_weekly_attendance(
  p_anchor_date date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
begin
  v_member := private.require_active_member();
  return private.weekly_attendance_json(v_member.user_id, p_anchor_date);
end;
$$;
-- ============================================================================
-- 4. 일일 출석 보상
-- ============================================================================

create or replace function public.rpc_check_daily_attendance(
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_today date := private.kst_date();
  v_week_start date;
  v_attendance public.user_daily_attendance%rowtype;
  v_attendance_id uuid;
  v_transaction_id uuid;
  v_balance numeric;
  v_result jsonb;
begin
  v_member := private.require_active_member();
  v_week_start := private.week_start_monday(v_today);

  perform pg_advisory_xact_lock(
    hashtextextended('attendance:' || v_member.user_id::text || ':' || v_today::text, 0)
  );

  select * into v_attendance
    from public.user_daily_attendance
   where user_id = v_member.user_id
     and check_date = v_today;

  if found then
    v_result := private.weekly_attendance_json(v_member.user_id, v_today);
    return v_result || jsonb_build_object(
      'alreadyChecked', true,
      'memberInitialAidas', private.wallet_balance(v_member.user_id, 'STOC_INT'),
      'transaction', case
        when v_attendance.transaction_id is null then null
        else private.transaction_json(v_attendance.transaction_id)
      end
    );
  end if;

  v_attendance_id := gen_random_uuid();
  v_transaction_id := gen_random_uuid();
  v_balance := private.credit_wallet(v_member.user_id, 'STOC_INT', 1);

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
    1,
    0,
    'ATT_REW',
    'completed',
    '📆출석 보상',
    'attendance',
    v_attendance_id,
    'attendance:' || v_member.user_id::text || ':' || v_today::text,
    jsonb_build_object(
      'request_id', p_idempotency_key,
      'check_date', v_today,
      'timezone', 'Asia/Seoul'
    ),
    now()
  );

  insert into public.user_daily_attendance (
    id,
    user_id,
    check_date,
    week_start,
    day_of_week,
    reward_amount,
    transaction_id,
    checked_at
  ) values (
    v_attendance_id,
    v_member.user_id,
    v_today,
    v_week_start,
    extract(dow from v_today)::smallint,
    1,
    v_transaction_id,
    now()
  )
  returning * into v_attendance;

  v_result := private.weekly_attendance_json(v_member.user_id, v_today);

  return v_result || jsonb_build_object(
    'alreadyChecked', false,
    'memberInitialAidas', v_balance,
    'transaction', private.transaction_json(v_transaction_id)
  );
end;
$$;
-- ============================================================================
-- 5. 일일 돌림판 상태 조회
-- ============================================================================

create or replace function public.rpc_get_daily_roulette_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_today date := private.kst_date();
  v_spin public.roulette_spins%rowtype;
begin
  v_member := private.require_active_member();

  select * into v_spin
    from public.roulette_spins
   where user_id = v_member.user_id
     and spin_date = v_today;

  return jsonb_build_object(
    'spinDate', v_today,
    'alreadySpun', v_spin.id is not null,
    'spin', case when v_spin.id is null then null else to_jsonb(v_spin) end
  );
end;
$$;
-- ============================================================================
-- 6. 일일 돌림판 실행
-- prize_id: DB에서 1~8
-- prize_value: DB에서 1~4
-- ============================================================================

create or replace function public.rpc_spin_daily_roulette(
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_today date := private.kst_date();
  v_spin public.roulette_spins%rowtype;
  v_spin_id uuid;
  v_transaction_id uuid;
  v_prize_id smallint;
  v_prize_value numeric;
  v_balance numeric;
begin
  v_member := private.require_active_member();

  perform pg_advisory_xact_lock(
    hashtextextended('roulette:' || v_member.user_id::text || ':' || v_today::text, 0)
  );

  select * into v_spin
    from public.roulette_spins
   where user_id = v_member.user_id
     and spin_date = v_today;

  if found then
    return jsonb_build_object(
      'alreadySpun', true,
      'spinDate', v_today,
      'spin', to_jsonb(v_spin),
      'memberInitialAidas', private.wallet_balance(v_member.user_id, 'STOC_INT'),
      'transaction', case
        when v_spin.transaction_id is null then null
        else private.transaction_json(v_spin.transaction_id)
      end
    );
  end if;

  -- 256은 8과 4로 나누어떨어지므로 modulo bias 없음
  v_prize_id := ((get_byte(extensions.gen_random_bytes(1), 0) % 8) + 1)::smallint;
  v_prize_value := ((get_byte(extensions.gen_random_bytes(1), 0) % 4) + 1)::numeric;

  v_spin_id := gen_random_uuid();
  v_transaction_id := gen_random_uuid();
  v_balance := private.credit_wallet(v_member.user_id, 'STOC_INT', v_prize_value);

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
    v_prize_value,
    0,
    'roulette_reward',
    'completed',
    '돌림판',
    'roulette',
    v_spin_id,
    'roulette:' || v_member.user_id::text || ':' || v_today::text,
    jsonb_build_object(
      'request_id', p_idempotency_key,
      'spin_date', v_today,
      'prize_id', v_prize_id,
      'timezone', 'Asia/Seoul'
    ),
    now()
  );

  insert into public.roulette_spins (
    id,
    user_id,
    spin_date,
    prize_id,
    prize_value,
    transaction_id,
    result_meta
  ) values (
    v_spin_id,
    v_member.user_id,
    v_today,
    v_prize_id,
    v_prize_value,
    v_transaction_id,
    jsonb_build_object('generated_by', 'database', 'timezone', 'Asia/Seoul')
  )
  returning * into v_spin;

  return jsonb_build_object(
    'alreadySpun', false,
    'spinDate', v_today,
    'spin', to_jsonb(v_spin),
    'memberInitialAidas', v_balance,
    'transaction', private.transaction_json(v_transaction_id)
  );
end;
$$;
-- ============================================================================
-- 7. 포인트 수집기 상태 조회
-- ============================================================================

create or replace function public.rpc_get_collector_status()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_today date := private.kst_date();
  v_session public.collector_sessions%rowtype;
  v_phase text;
  v_remaining integer;
begin
  v_member := private.require_active_member();

  select * into v_session
    from public.collector_sessions
   where user_id = v_member.user_id
     and claim_date = v_today;

  if not found then
    return jsonb_build_object(
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
  elsif now() >= v_session.unlock_at then
    v_phase := 'claimable';
    v_remaining := 0;

    if v_session.status <> 'claimable' then
      update public.collector_sessions
         set status = 'claimable', updated_at = now()
       where id = v_session.id
      returning * into v_session;
    end if;
  else
    v_phase := 'collecting';
    v_remaining := greatest(0, ceil(extract(epoch from (v_session.unlock_at - now())))::integer);
  end if;

  return jsonb_build_object(
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
-- ============================================================================
-- 8. 포인트 수집기 시작
-- ============================================================================

create or replace function public.rpc_start_collector()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_today date := private.kst_date();
  v_session public.collector_sessions%rowtype;
  v_phase text;
  v_remaining integer;
begin
  v_member := private.require_active_member();

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
      now(),
      now() + interval '1 hour',
      1
    )
    returning * into v_session;

    return jsonb_build_object(
      'alreadyStarted', false,
      'claimDate', v_today,
      'phase', 'collecting',
      'remainingSeconds', 3600,
      'session', to_jsonb(v_session)
    );
  end if;

  if v_session.status = 'claimed' then
    v_phase := 'completed';
    v_remaining := 0;
  elsif now() >= v_session.unlock_at then
    v_phase := 'claimable';
    v_remaining := 0;

    if v_session.status <> 'claimable' then
      update public.collector_sessions
         set status = 'claimable', updated_at = now()
       where id = v_session.id
      returning * into v_session;
    end if;
  else
    v_phase := 'collecting';
    v_remaining := greatest(0, ceil(extract(epoch from (v_session.unlock_at - now())))::integer);
  end if;

  return jsonb_build_object(
    'alreadyStarted', true,
    'claimDate', v_today,
    'phase', v_phase,
    'remainingSeconds', v_remaining,
    'session', to_jsonb(v_session)
  );
end;
$$;
-- ============================================================================
-- 9. 포인트 수집기 보상 수령
-- ============================================================================

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
  v_today date := private.kst_date();
  v_session public.collector_sessions%rowtype;
  v_transaction_id uuid;
  v_balance numeric;
  v_remaining integer;
begin
  v_member := private.require_active_member();

  perform pg_advisory_xact_lock(
    hashtextextended('collector:' || v_member.user_id::text || ':' || v_today::text, 0)
  );

  select * into v_session
    from public.collector_sessions
   where user_id = v_member.user_id
     and claim_date = v_today
   for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'COLLECTOR_NOT_STARTED';
  end if;

  if v_session.status = 'claimed' then
    return jsonb_build_object(
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

  if now() < v_session.unlock_at then
    v_remaining := greatest(0, ceil(extract(epoch from (v_session.unlock_at - now())))::integer);
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
      'timezone', 'Asia/Seoul'
    ),
    now()
  );

  update public.collector_sessions
     set status = 'claimed',
         claimed_at = now(),
         transaction_id = v_transaction_id,
         updated_at = now()
   where id = v_session.id
  returning * into v_session;

  return jsonb_build_object(
    'alreadyClaimed', false,
    'claimed', true,
    'phase', 'completed',
    'memberInitialAidas', v_balance,
    'session', to_jsonb(v_session),
    'transaction', private.transaction_json(v_transaction_id)
  );
end;
$$;
-- ============================================================================
-- 10. 내부 자산 이체
-- p_receiver: user_id / mb_id / referral_code / 등록 지갑 주소
-- ============================================================================

create or replace function public.rpc_transfer_asset(
  p_receiver text,
  p_asset_code text,
  p_amount numeric,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sender public.member%rowtype;
  v_receiver public.member%rowtype;
  v_asset_code text := upper(trim(p_asset_code));
  v_receiver_input text := trim(p_receiver);
  v_idempotency_key text;
  v_transaction public.transactions%rowtype;
  v_sender_balance numeric;
  v_receiver_balance numeric;
  v_transaction_id uuid;
begin
  v_sender := private.require_active_member();

  if v_receiver_input is null or v_receiver_input = '' then
    raise exception using errcode = '22023', message = 'RECEIVER_REQUIRED';
  end if;

  if v_asset_code is null or v_asset_code = '' then
    raise exception using errcode = '22023', message = 'ASSET_CODE_REQUIRED';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception using errcode = '22023', message = 'AMOUNT_MUST_BE_POSITIVE';
  end if;

  if p_idempotency_key is null or trim(p_idempotency_key) = '' then
    raise exception using errcode = '22023', message = 'IDEMPOTENCY_KEY_REQUIRED';
  end if;

  if length(p_idempotency_key) > 128 then
    raise exception using errcode = '22023', message = 'IDEMPOTENCY_KEY_TOO_LONG';
  end if;

  select m.*
    into v_receiver
    from public.member m
   where m.status = 'active'
     and (
       m.user_id::text = v_receiver_input
       or lower(m.mb_id) = lower(v_receiver_input)
       or lower(m.referral_code) = lower(v_receiver_input)
       or exists (
         select 1
           from public.wallet_addresses wa
          where wa.user_id = m.user_id
            and wa.address = v_receiver_input
            and wa.status = 'active'
       )
     )
   limit 1;

  if not found then
    raise exception using errcode = 'P0001', message = 'RECEIVER_NOT_FOUND';
  end if;

  if v_receiver.user_id = v_sender.user_id then
    raise exception using errcode = '22023', message = 'SELF_TRANSFER_NOT_ALLOWED';
  end if;

  v_idempotency_key := 'transfer:' || v_sender.user_id::text || ':' || trim(p_idempotency_key);

  perform pg_advisory_xact_lock(hashtextextended(v_idempotency_key, 0));

  select * into v_transaction
    from public.transactions
   where idempotency_key = v_idempotency_key;

  if found then
    return jsonb_build_object(
      'alreadyProcessed', true,
      'senderBalance', private.wallet_balance(v_sender.user_id, v_asset_code),
      'receiver', jsonb_build_object(
        'user_id', v_receiver.user_id,
        'mb_id', v_receiver.mb_id,
        'mb_name', v_receiver.mb_name
      ),
      'transaction', private.transaction_json(v_transaction.id)
    );
  end if;

  insert into public.wallet_accounts (
    user_id, asset_code, account_type, available_balance, locked_balance
  ) values
    (v_sender.user_id, v_asset_code, 'internal', 0, 0),
    (v_receiver.user_id, v_asset_code, 'internal', 0, 0)
  on conflict (user_id, asset_code, account_type) do nothing;

  -- UUID 정렬 순서로 잠가 상호 송금 시 deadlock 가능성을 줄인다.
  perform wa.id
    from public.wallet_accounts wa
   where wa.user_id in (v_sender.user_id, v_receiver.user_id)
     and wa.asset_code = v_asset_code
     and wa.account_type = 'internal'
   order by wa.user_id
   for update;

  select available_balance
    into v_sender_balance
    from public.wallet_accounts
   where user_id = v_sender.user_id
     and asset_code = v_asset_code
     and account_type = 'internal';

  if v_sender_balance < p_amount then
    raise exception using
      errcode = 'P0001',
      message = 'INSUFFICIENT_BALANCE',
      detail = jsonb_build_object(
        'asset_code', v_asset_code,
        'available_balance', v_sender_balance,
        'requested_amount', p_amount
      )::text;
  end if;

  update public.wallet_accounts
     set available_balance = available_balance - p_amount,
         updated_at = now()
   where user_id = v_sender.user_id
     and asset_code = v_asset_code
     and account_type = 'internal'
  returning available_balance into v_sender_balance;

  update public.wallet_accounts
     set available_balance = available_balance + p_amount,
         updated_at = now()
   where user_id = v_receiver.user_id
     and asset_code = v_asset_code
     and account_type = 'internal'
  returning available_balance into v_receiver_balance;

  v_transaction_id := gen_random_uuid();

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
    idempotency_key,
    metadata,
    processed_at
  ) values (
    v_transaction_id,
    v_sender.user_id,
    v_receiver.user_id,
    v_asset_code,
    p_amount,
    0,
    'internal_transfer',
    'completed',
    '내부 자산 이체',
    'transfer',
    v_idempotency_key,
    jsonb_build_object(
      'receiver_input', v_receiver_input,
      'sender_balance_after', v_sender_balance,
      'receiver_balance_after', v_receiver_balance
    ),
    now()
  );

  return jsonb_build_object(
    'alreadyProcessed', false,
    'senderBalance', v_sender_balance,
    'receiverBalance', v_receiver_balance,
    'receiver', jsonb_build_object(
      'user_id', v_receiver.user_id,
      'mb_id', v_receiver.mb_id,
      'mb_name', v_receiver.mb_name
    ),
    'transaction', private.transaction_json(v_transaction_id)
  );
end;
$$;
-- ============================================================================
-- 11. 거래 내역 조회
-- ============================================================================

create or replace function public.rpc_list_transactions(
  p_limit integer default 50,
  p_cursor timestamptz default null
)
returns table (
  id uuid,
  sender_id text,
  receiver_id text,
  sender_user_id uuid,
  receiver_user_id uuid,
  sender_address text,
  receiver_address text,
  amount numeric,
  fee_amount numeric,
  currency_type text,
  asset_code text,
  transaction_type text,
  status text,
  description text,
  tx_hash text,
  metadata jsonb,
  created_at timestamptz,
  processed_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
begin
  v_member := private.require_active_member();

  return query
  select
    t.id,
    sm.mb_id as sender_id,
    rm.mb_id as receiver_id,
    t.sender_user_id,
    t.receiver_user_id,
    t.sender_address,
    t.receiver_address,
    t.amount,
    t.fee_amount,
    t.asset_code as currency_type,
    t.asset_code,
    t.transaction_type,
    t.status,
    t.description,
    t.tx_hash,
    t.metadata,
    t.created_at,
    t.processed_at
  from public.transactions t
  left join public.member sm on sm.user_id = t.sender_user_id
  left join public.member rm on rm.user_id = t.receiver_user_id
  where (t.sender_user_id = v_member.user_id or t.receiver_user_id = v_member.user_id)
    and (p_cursor is null or t.created_at < p_cursor)
  order by t.created_at desc, t.id desc
  limit v_limit;
end;
$$;
-- ============================================================================
-- 12. 추천 회원 목록
-- ============================================================================

create or replace function public.rpc_list_referred_members(
  p_depth integer default 1,
  p_limit integer default 100
)
returns table (
  user_id uuid,
  mb_no bigint,
  mb_id text,
  mb_name text,
  mb_email text,
  mb_profile text,
  depth integer,
  referral_status text,
  joined_at timestamptz,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_depth integer := greatest(coalesce(p_depth, 1), 1);
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 500);
begin
  v_member := private.require_active_member();

  return query
  select
    m.user_id,
    m.mb_no,
    m.mb_id,
    m.mb_name,
    m.mb_email,
    m.mb_profile,
    rn.depth,
    rn.status as referral_status,
    rn.joined_at,
    m.created_at
  from public.referral_network rn
  join public.member m on m.user_id = rn.referred_user_id
  where rn.referrer_user_id = v_member.user_id
    and rn.depth = v_depth
    and rn.status = 'active'
    and m.status = 'active'
  order by rn.joined_at desc
  limit v_limit;
end;
$$;
-- ============================================================================
-- 13. 알림 읽음 처리
-- p_ids = null 또는 빈 배열이면 본인의 모든 알림 읽음 처리
-- ============================================================================

create or replace function public.rpc_mark_notifications_read(
  p_ids uuid[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_updated_count integer;
  v_unread_count integer;
begin
  v_member := private.require_active_member();

  update public.notifications
     set is_read = true,
         read_at = coalesce(read_at, now())
   where user_id = v_member.user_id
     and is_read = false
     and (
       p_ids is null
       or cardinality(p_ids) = 0
       or id = any(p_ids)
     );

  get diagnostics v_updated_count = row_count;

  select count(*)::integer
    into v_unread_count
    from public.notifications
   where user_id = v_member.user_id
     and is_read = false;

  return jsonb_build_object(
    'updatedCount', v_updated_count,
    'unreadCount', v_unread_count
  );
end;
$$;
-- ============================================================================
-- 14. 회원 설정 변경
-- 허용 키: mb_name, mb_hp, mb_profile, marketing_agreed,
--          push_notifications_enabled, locale
-- ============================================================================

create or replace function public.rpc_update_member_settings(
  p_patch jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_unknown_key text;
  v_name text;
  v_locale text;
begin
  v_member := private.require_active_member();

  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception using errcode = '22023', message = 'PATCH_OBJECT_REQUIRED';
  end if;

  select key into v_unknown_key
    from jsonb_object_keys(p_patch) as x(key)
   where key not in (
     'mb_name',
     'mb_hp',
     'mb_profile',
     'marketing_agreed',
     'push_notifications_enabled',
     'locale'
   )
   limit 1;

  if v_unknown_key is not null then
    raise exception using
      errcode = '22023',
      message = 'UNSUPPORTED_PATCH_KEY',
      detail = v_unknown_key;
  end if;

  if p_patch ? 'mb_name' then
    v_name := nullif(trim(p_patch ->> 'mb_name'), '');
    if v_name is null then
      raise exception using errcode = '22023', message = 'MB_NAME_REQUIRED';
    end if;
    if length(v_name) > 100 then
      raise exception using errcode = '22023', message = 'MB_NAME_TOO_LONG';
    end if;
  end if;

  if p_patch ? 'locale' then
    v_locale := nullif(trim(p_patch ->> 'locale'), '');
    if v_locale is null or v_locale !~ '^[a-z]{2}([_-][A-Za-z]{2})?$' then
      raise exception using errcode = '22023', message = 'INVALID_LOCALE';
    end if;
  end if;

  update public.member
     set mb_name = case
           when p_patch ? 'mb_name' then v_name
           else mb_name
         end,
         mb_hp = case
           when p_patch ? 'mb_hp' then nullif(trim(p_patch ->> 'mb_hp'), '')
           else mb_hp
         end,
         mb_profile = case
           when p_patch ? 'mb_profile' then nullif(trim(p_patch ->> 'mb_profile'), '')
           else mb_profile
         end,
         marketing_agreed = case
           when p_patch ? 'marketing_agreed'
           then (p_patch ->> 'marketing_agreed')::boolean
           else marketing_agreed
         end,
         push_notifications_enabled = case
           when p_patch ? 'push_notifications_enabled'
           then (p_patch ->> 'push_notifications_enabled')::boolean
           else push_notifications_enabled
         end,
         locale = case
           when p_patch ? 'locale' then v_locale
           else locale
         end,
         updated_at = now()
   where user_id = v_member.user_id;

  return private.member_snapshot(v_member.user_id);
end;
$$;
-- ============================================================================
-- 15. 기기 및 Push token 등록
-- ============================================================================

create or replace function public.rpc_upsert_member_device(
  p_platform text,
  p_device_id text,
  p_push_token text default null,
  p_app_version text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_platform text := lower(trim(p_platform));
  v_device_id text := nullif(trim(p_device_id), '');
  v_push_token text := nullif(trim(p_push_token), '');
  v_device public.member_devices%rowtype;
begin
  v_member := private.require_active_member();

  if v_platform is null or v_platform not in ('web', 'android', 'ios') then
    raise exception using errcode = '22023', message = 'INVALID_PLATFORM';
  end if;

  if v_device_id is null then
    raise exception using errcode = '22023', message = 'DEVICE_ID_REQUIRED';
  end if;

  if v_push_token is not null then
    update public.member_devices
       set push_token = null,
           updated_at = now()
     where push_token = v_push_token
       and not (
         user_id = v_member.user_id
         and platform = v_platform
         and device_id = v_device_id
       );
  end if;

  insert into public.member_devices (
    user_id,
    platform,
    device_id,
    push_token,
    app_version,
    last_seen_at
  ) values (
    v_member.user_id,
    v_platform,
    v_device_id,
    v_push_token,
    nullif(trim(p_app_version), ''),
    now()
  )
  on conflict (user_id, platform, device_id)
  do update set
    push_token = excluded.push_token,
    app_version = excluded.app_version,
    last_seen_at = now(),
    updated_at = now()
  returning * into v_device;

  return to_jsonb(v_device);
end;
$$;
-- ============================================================================
-- 16. 이벤트 참여
-- events.metadata.reward_on_join = true인 경우에만 즉시 보상 지급
-- ============================================================================

create or replace function public.rpc_join_event(
  p_event_id uuid,
  p_idempotency_key text,
  p_source text default 'app'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_event public.events%rowtype;
  v_participant public.event_participants%rowtype;
  v_transaction_id uuid;
  v_balance numeric;
  v_reward_on_join boolean;
  v_idempotency_key text;
begin
  v_member := private.require_active_member();

  if p_event_id is null then
    raise exception using errcode = '22023', message = 'EVENT_ID_REQUIRED';
  end if;

  if p_idempotency_key is null or trim(p_idempotency_key) = '' then
    raise exception using errcode = '22023', message = 'IDEMPOTENCY_KEY_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('event:' || v_member.user_id::text || ':' || p_event_id::text, 0)
  );

  select * into v_event
    from public.events
   where id = p_event_id
     and is_active = true
     and (start_at is null or start_at <= now())
     and (end_at is null or end_at >= now())
   for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'EVENT_NOT_AVAILABLE';
  end if;

  select * into v_participant
    from public.event_participants
   where event_id = p_event_id
     and user_id = v_member.user_id
   for update;

  if found then
    return jsonb_build_object(
      'alreadyJoined', true,
      'participant', to_jsonb(v_participant),
      'memberInitialAidas', private.wallet_balance(v_member.user_id, 'STOC_INT'),
      'transaction', case
        when v_participant.reward_transaction_id is null then null
        else private.transaction_json(v_participant.reward_transaction_id)
      end
    );
  end if;

  insert into public.event_participants (
    event_id,
    user_id,
    source,
    status
  ) values (
    p_event_id,
    v_member.user_id,
    nullif(trim(p_source), ''),
    'joined'
  )
  returning * into v_participant;

  v_reward_on_join := lower(coalesce(v_event.metadata ->> 'reward_on_join', 'false')) = 'true';

  if v_reward_on_join
     and v_event.reward_amount > 0
     and v_event.reward_asset_code is not null then

    v_idempotency_key := 'event:' || p_event_id::text || ':' || v_member.user_id::text;
    v_transaction_id := gen_random_uuid();
    v_balance := private.credit_wallet(
      v_member.user_id,
      v_event.reward_asset_code,
      v_event.reward_amount
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
      upper(v_event.reward_asset_code),
      v_event.reward_amount,
      0,
      'event_reward',
      'completed',
      v_event.title || ' 이벤트 보상',
      'event',
      v_participant.id,
      v_idempotency_key,
      jsonb_build_object(
        'request_id', p_idempotency_key,
        'event_id', p_event_id,
        'event_code', v_event.code
      ),
      now()
    );

    update public.event_participants
       set status = 'completed',
           completed_at = now(),
           reward_transaction_id = v_transaction_id
     where id = v_participant.id
    returning * into v_participant;
  else
    v_balance := private.wallet_balance(v_member.user_id, 'STOC_INT');
  end if;

  return jsonb_build_object(
    'alreadyJoined', false,
    'participant', to_jsonb(v_participant),
    'memberInitialAidas', private.wallet_balance(v_member.user_id, 'STOC_INT'),
    'rewardBalance', v_balance,
    'transaction', case
      when v_transaction_id is null then null
      else private.transaction_json(v_transaction_id)
    end
  );
end;
$$;
-- ============================================================================
-- 함수 권한
-- ============================================================================

revoke all on function public.rpc_bootstrap_member(text) from public, anon, authenticated;
revoke all on function public.rpc_get_home_snapshot() from public, anon, authenticated;
revoke all on function public.rpc_get_weekly_attendance(date) from public, anon, authenticated;
revoke all on function public.rpc_check_daily_attendance(text) from public, anon, authenticated;
revoke all on function public.rpc_get_daily_roulette_status() from public, anon, authenticated;
revoke all on function public.rpc_spin_daily_roulette(text) from public, anon, authenticated;
revoke all on function public.rpc_get_collector_status() from public, anon, authenticated;
revoke all on function public.rpc_start_collector() from public, anon, authenticated;
revoke all on function public.rpc_claim_collector(text) from public, anon, authenticated;
revoke all on function public.rpc_transfer_asset(text, text, numeric, text) from public, anon, authenticated;
revoke all on function public.rpc_list_transactions(integer, timestamptz) from public, anon, authenticated;
revoke all on function public.rpc_list_referred_members(integer, integer) from public, anon, authenticated;
revoke all on function public.rpc_mark_notifications_read(uuid[]) from public, anon, authenticated;
revoke all on function public.rpc_update_member_settings(jsonb) from public, anon, authenticated;
revoke all on function public.rpc_upsert_member_device(text, text, text, text) from public, anon, authenticated;
revoke all on function public.rpc_join_event(uuid, text, text) from public, anon, authenticated;
grant execute on function public.rpc_bootstrap_member(text) to authenticated;
grant execute on function public.rpc_get_home_snapshot() to authenticated;
grant execute on function public.rpc_get_weekly_attendance(date) to authenticated;
grant execute on function public.rpc_check_daily_attendance(text) to authenticated;
grant execute on function public.rpc_get_daily_roulette_status() to authenticated;
grant execute on function public.rpc_spin_daily_roulette(text) to authenticated;
grant execute on function public.rpc_get_collector_status() to authenticated;
grant execute on function public.rpc_start_collector() to authenticated;
grant execute on function public.rpc_claim_collector(text) to authenticated;
grant execute on function public.rpc_transfer_asset(text, text, numeric, text) to authenticated;
grant execute on function public.rpc_list_transactions(integer, timestamptz) to authenticated;
grant execute on function public.rpc_list_referred_members(integer, integer) to authenticated;
grant execute on function public.rpc_mark_notifications_read(uuid[]) to authenticated;
grant execute on function public.rpc_update_member_settings(jsonb) to authenticated;
grant execute on function public.rpc_upsert_member_device(text, text, text, text) to authenticated;
grant execute on function public.rpc_join_event(uuid, text, text) to authenticated;
-- PostgREST schema cache refresh
notify pgrst, 'reload schema';
