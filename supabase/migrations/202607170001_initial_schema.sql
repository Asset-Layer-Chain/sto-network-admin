-- STO Network / Supabase schema draft v0
-- 목적: 현재 React API/UI 호환성을 최대한 유지하면서 Auth + RPC 중심으로 재구성

create extension if not exists pgcrypto;
-- -----------------------------------------------------------------------------
-- 공통 updated_at trigger
-- -----------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
-- -----------------------------------------------------------------------------
-- 1. 회원: auth.users와 1:1
-- 기존 member API의 mb_* 네이밍을 일부 유지한다.
-- 잔액(initial_aidas, mb_stoc, BNB)과 체인 주소는 별도 테이블로 분리한다.
-- -----------------------------------------------------------------------------
create table if not exists public.member (
  user_id uuid primary key references auth.users(id) on delete cascade,
  mb_no bigint generated always as identity unique,
  mb_id text not null unique,
  mb_name text not null,
  mb_email text not null unique,
  mb_hp text,
  mb_profile text,

  status text not null default 'active'
    check (status in ('pending', 'active', 'suspended', 'deleted')),
  role text not null default 'user'
    check (role in ('user', 'admin', 'super_admin')),
  mb_level integer not null default 0 check (mb_level >= 0),
  mb_point numeric(36, 8) not null default 0 check (mb_point >= 0),

  referral_code text not null unique,
  referrer_user_id uuid references public.member(user_id) on delete set null,

  google_linked boolean not null default false,
  google_id text unique,
  marketing_agreed boolean not null default false,
  push_notifications_enabled boolean not null default false,
  locale text not null default 'ko',
  reg_channel text not null default 'web',

  last_login_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists member_referrer_user_id_idx
  on public.member(referrer_user_id);
create index if not exists member_created_at_idx
  on public.member(created_at desc);
create trigger member_set_updated_at
before update on public.member
for each row execute function public.set_updated_at();
-- -----------------------------------------------------------------------------
-- 2. 기기/푸시 토큰: 한 회원이 여러 기기를 가질 수 있도록 분리
-- -----------------------------------------------------------------------------
create table if not exists public.member_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.member(user_id) on delete cascade,
  platform text not null check (platform in ('web', 'android', 'ios')),
  device_id text,
  push_token text,
  app_version text,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, platform, device_id)
);
create unique index if not exists member_devices_push_token_uidx
  on public.member_devices(push_token)
  where push_token is not null;
create trigger member_devices_set_updated_at
before update on public.member_devices
for each row execute function public.set_updated_at();
-- -----------------------------------------------------------------------------
-- 3. 지갑/잔액
-- RPC 외에는 INSERT/UPDATE/DELETE를 허용하지 않는 것을 전제로 한다.
-- -----------------------------------------------------------------------------
create table if not exists public.wallet_accounts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.member(user_id) on delete cascade,
  asset_code text not null,                  -- STOC, BNB 등
  account_type text not null default 'internal'
    check (account_type in ('internal', 'external', 'reward')),
  available_balance numeric(36, 18) not null default 0
    check (available_balance >= 0),
  locked_balance numeric(36, 18) not null default 0
    check (locked_balance >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, asset_code, account_type)
);
create index if not exists wallet_accounts_user_idx
  on public.wallet_accounts(user_id);
create trigger wallet_accounts_set_updated_at
before update on public.wallet_accounts
for each row execute function public.set_updated_at();
create table if not exists public.wallet_addresses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.member(user_id) on delete cascade,
  chain text not null,                       -- kaia, bsc, ethereum, solana
  asset_code text not null,
  address text not null,
  memo_tag text,
  status text not null default 'active'
    check (status in ('pending', 'active', 'disabled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (chain, address),
  unique (user_id, chain, asset_code)
);
create trigger wallet_addresses_set_updated_at
before update on public.wallet_addresses
for each row execute function public.set_updated_at();
-- -----------------------------------------------------------------------------
-- 4. 통합 거래 원장
-- 기존 transactions UI가 필요로 하는 sender/receiver/amount/type/status를 포함한다.
-- idempotency_key로 중복 요청을 방지한다.
-- -----------------------------------------------------------------------------
create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  sender_user_id uuid references public.member(user_id) on delete set null,
  receiver_user_id uuid references public.member(user_id) on delete set null,
  sender_address text,
  receiver_address text,

  asset_code text not null,
  amount numeric(36, 18) not null check (amount > 0),
  fee_amount numeric(36, 18) not null default 0 check (fee_amount >= 0),

  transaction_type text not null,            -- attendance_reward, roulette_reward, transfer ...
  status text not null default 'pending'
    check (status in ('pending', 'processing', 'completed', 'failed', 'cancelled')),
  description text,
  tx_hash text,

  reference_type text,                       -- attendance, roulette, collector, event ...
  reference_id uuid,
  idempotency_key text not null unique,
  metadata jsonb not null default '{}'::jsonb,

  scheduled_at timestamptz,
  processed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists transactions_sender_created_idx
  on public.transactions(sender_user_id, created_at desc);
create index if not exists transactions_receiver_created_idx
  on public.transactions(receiver_user_id, created_at desc);
create index if not exists transactions_reference_idx
  on public.transactions(reference_type, reference_id);
create unique index if not exists transactions_tx_hash_uidx
  on public.transactions(tx_hash)
  where tx_hash is not null;
create trigger transactions_set_updated_at
before update on public.transactions
for each row execute function public.set_updated_at();
-- -----------------------------------------------------------------------------
-- 5. 출석: 미출석 placeholder row를 만들지 않고, 출석한 날만 한 행 저장
-- 주간 상태는 RPC에서 날짜 배열과 결합하여 반환한다.
-- -----------------------------------------------------------------------------
create table if not exists public.user_daily_attendance (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.member(user_id) on delete cascade,
  check_date date not null,
  week_start date not null,
  day_of_week smallint not null check (day_of_week between 0 and 6),
  reward_amount numeric(36, 18) not null default 0 check (reward_amount >= 0),
  transaction_id uuid unique references public.transactions(id) on delete set null,
  checked_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (user_id, check_date)
);
create index if not exists attendance_user_week_idx
  on public.user_daily_attendance(user_id, week_start, check_date);
-- -----------------------------------------------------------------------------
-- 6. 돌림판: 결과는 클라이언트가 보내지 않고 RPC 내부에서 생성
-- -----------------------------------------------------------------------------
create table if not exists public.roulette_spins (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.member(user_id) on delete cascade,
  spin_date date not null,
  prize_id smallint not null check (prize_id between 1 and 8),
  prize_value numeric(36, 18) not null check (prize_value > 0),
  transaction_id uuid unique references public.transactions(id) on delete set null,
  result_meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (user_id, spin_date)
);
create index if not exists roulette_user_created_idx
  on public.roulette_spins(user_id, created_at desc);
-- -----------------------------------------------------------------------------
-- 7. 포인트 수집기: 브라우저 localStorage 타이머 대신 서버 시각으로 검증
-- -----------------------------------------------------------------------------
create table if not exists public.collector_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.member(user_id) on delete cascade,
  claim_date date not null,
  status text not null default 'collecting'
    check (status in ('collecting', 'claimable', 'claimed', 'expired')),
  started_at timestamptz not null default now(),
  unlock_at timestamptz not null,
  claimed_at timestamptz,
  reward_amount numeric(36, 18) not null default 1 check (reward_amount > 0),
  transaction_id uuid unique references public.transactions(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, claim_date),
  check (unlock_at > started_at)
);
create trigger collector_sessions_set_updated_at
before update on public.collector_sessions
for each row execute function public.set_updated_at();
-- -----------------------------------------------------------------------------
-- 8. 추천 관계
-- direct 친구 목록은 depth=1 조회. 다단계가 필요하면 closure rows를 추가한다.
-- -----------------------------------------------------------------------------
create table if not exists public.referral_network (
  id uuid primary key default gen_random_uuid(),
  referrer_user_id uuid not null references public.member(user_id) on delete cascade,
  referred_user_id uuid not null references public.member(user_id) on delete cascade,
  depth integer not null default 1 check (depth >= 1),
  status text not null default 'active'
    check (status in ('active', 'inactive', 'blocked')),
  joined_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (referrer_user_id, referred_user_id, depth),
  check (referrer_user_id <> referred_user_id)
);
create unique index if not exists referral_direct_child_uidx
  on public.referral_network(referred_user_id)
  where depth = 1 and status = 'active';
create index if not exists referral_parent_depth_idx
  on public.referral_network(referrer_user_id, depth, created_at desc);
-- -----------------------------------------------------------------------------
-- 9. 알림/공지
-- -----------------------------------------------------------------------------
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.member(user_id) on delete cascade,
  type text not null default 'general',
  title text not null,
  message text not null,
  payload jsonb not null default '{}'::jsonb,
  is_read boolean not null default false,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists notifications_user_read_created_idx
  on public.notifications(user_id, is_read, created_at desc);
create table if not exists public.chat_notices (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text not null,
  notice_type text not null default 'system',
  is_active boolean not null default true,
  starts_at timestamptz,
  ends_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger chat_notices_set_updated_at
before update on public.chat_notices
for each row execute function public.set_updated_at();
-- -----------------------------------------------------------------------------
-- 10. 앱 설정/버전
-- -----------------------------------------------------------------------------
create table if not exists public.app_settings (
  key text primary key,
  value jsonb not null,
  description text,
  is_active boolean not null default true,
  updated_at timestamptz not null default now()
);
create table if not exists public.app_versions (
  id uuid primary key default gen_random_uuid(),
  platform text not null check (platform in ('web', 'android', 'ios')),
  version text not null,
  version_code integer,
  min_supported_version text,
  force_update boolean not null default false,
  release_notes text,
  download_url text,
  is_active boolean not null default true,
  released_at timestamptz not null default now(),
  unique (platform, version)
);
create table if not exists public.blocked_versions (
  id uuid primary key default gen_random_uuid(),
  platform text not null check (platform in ('web', 'android', 'ios')),
  version text not null,
  reason text,
  created_at timestamptz not null default now(),
  unique (platform, version)
);
-- -----------------------------------------------------------------------------
-- 11. 이벤트/혜택
-- -----------------------------------------------------------------------------
create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  title text not null,
  description text,
  reward_asset_code text,
  reward_amount numeric(36, 18) not null default 0 check (reward_amount >= 0),
  start_at timestamptz,
  end_at timestamptz,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger events_set_updated_at
before update on public.events
for each row execute function public.set_updated_at();
create table if not exists public.event_participants (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references public.member(user_id) on delete cascade,
  source text,
  status text not null default 'joined'
    check (status in ('joined', 'completed', 'cancelled', 'disqualified')),
  reward_transaction_id uuid references public.transactions(id) on delete set null,
  joined_at timestamptz not null default now(),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (event_id, user_id)
);
-- -----------------------------------------------------------------------------
-- 12. 현재 코드에 이름만 존재하는 2차 기능 테이블
-- -----------------------------------------------------------------------------
create table if not exists public.daily_quiz_progress (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.member(user_id) on delete cascade,
  quiz_date date not null,
  question_id text not null,
  selected_answer integer,
  is_correct boolean,
  reward_amount numeric(36, 18) not null default 0,
  transaction_id uuid references public.transactions(id) on delete set null,
  answered_at timestamptz,
  created_at timestamptz not null default now(),
  unique (user_id, quiz_date, question_id)
);
create table if not exists public.prediction_records (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.member(user_id) on delete cascade,
  token_symbol text not null,
  prediction_direction text not null check (prediction_direction in ('up', 'down')),
  base_price numeric(36, 18) not null,
  target_at timestamptz not null,
  status text not null default 'pending'
    check (status in ('pending', 'correct', 'incorrect', 'cancelled')),
  result_price numeric(36, 18),
  reward_amount numeric(36, 18) not null default 0,
  transaction_id uuid references public.transactions(id) on delete set null,
  settled_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists prediction_pending_target_idx
  on public.prediction_records(status, target_at)
  where status = 'pending';
create table if not exists public.sim_orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.member(user_id) on delete cascade,
  symbol text not null,
  side text not null check (side in ('long', 'short', 'buy', 'sell')),
  order_type text not null check (order_type in ('market', 'limit')),
  amount numeric(36, 18) not null check (amount > 0),
  leverage numeric(12, 4) not null default 1 check (leverage >= 1),
  price numeric(36, 18),
  status text not null default 'pending'
    check (status in ('pending', 'filled', 'cancelled', 'rejected')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger sim_orders_set_updated_at
before update on public.sim_orders
for each row execute function public.set_updated_at();
create table if not exists public.sim_positions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.member(user_id) on delete cascade,
  symbol text not null,
  side text not null check (side in ('long', 'short')),
  entry_price numeric(36, 18) not null,
  exit_price numeric(36, 18),
  size numeric(36, 18) not null check (size > 0),
  leverage numeric(12, 4) not null default 1,
  pnl numeric(36, 18) not null default 0,
  status text not null default 'open' check (status in ('open', 'closed', 'liquidated')),
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger sim_positions_set_updated_at
before update on public.sim_positions
for each row execute function public.set_updated_at();
create table if not exists public.qr_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.member(user_id) on delete cascade,
  purpose text not null,
  qr_payload text not null,
  status text not null default 'active' check (status in ('active', 'used', 'expired', 'cancelled')),
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists qr_sessions_active_expiry_idx
  on public.qr_sessions(status, expires_at)
  where status = 'active';
create table if not exists public.platform_fee_config (
  id uuid primary key default gen_random_uuid(),
  chain text not null,
  asset_code text not null,
  fee_type text not null,
  fee_bps integer not null default 0 check (fee_bps between 0 and 10000),
  min_fee numeric(36, 18) not null default 0,
  max_fee numeric(36, 18),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (chain, asset_code, fee_type)
);
create trigger platform_fee_config_set_updated_at
before update on public.platform_fee_config
for each row execute function public.set_updated_at();
-- -----------------------------------------------------------------------------
-- Auth signup 최소 프로필 생성
-- 복잡한 추천 처리/지갑 생성은 rpc_bootstrap_member()에서 수행하는 것을 권장한다.
-- -----------------------------------------------------------------------------
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_base_id text;
  v_member_id text;
begin
  v_base_id := lower(regexp_replace(split_part(coalesce(new.email, 'user'), '@', 1), '[^a-zA-Z0-9._-]', '', 'g'));
  v_member_id := left(coalesce(nullif(new.raw_user_meta_data ->> 'mb_id', ''), v_base_id, 'user'), 30)
    || '_' || left(replace(new.id::text, '-', ''), 6);

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
    reg_channel
  ) values (
    new.id,
    v_member_id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name', new.email, 'STO User'),
    coalesce(new.email, new.id::text || '@no-email.local'),
    coalesce(new.raw_user_meta_data ->> 'avatar_url', new.raw_user_meta_data ->> 'picture'),
    upper(left(replace(new.id::text, '-', ''), 10)),
    coalesce(new.raw_app_meta_data ->> 'provider', '') = 'google',
    case when coalesce(new.raw_app_meta_data ->> 'provider', '') = 'google'
      then coalesce(new.raw_user_meta_data ->> 'sub', new.id::text)
      else null
    end,
    case lower(coalesce(new.raw_user_meta_data ->> 'marketing_agreed', 'false'))
      when 'true' then true else false end,
    coalesce(new.raw_user_meta_data ->> 'reg_channel', 'web')
  )
  on conflict (user_id) do nothing;

  return new;
end;
$$;
revoke execute on function public.handle_new_auth_user() from public, anon, authenticated;
-- 실제 적용 전 기존 trigger 이름 충돌 여부 확인
-- create trigger on_auth_user_created
-- after insert on auth.users
-- for each row execute function public.handle_new_auth_user();

-- -----------------------------------------------------------------------------
-- RLS 기본 방향
-- 읽기는 본인 소유 데이터만. 잔액/거래/보상 테이블의 쓰기는 RPC만 허용한다.
-- -----------------------------------------------------------------------------
alter table public.member enable row level security;
alter table public.chat_notices enable row level security;
alter table public.app_settings enable row level security;
alter table public.app_versions enable row level security;
alter table public.blocked_versions enable row level security;
alter table public.events enable row level security;
alter table public.platform_fee_config enable row level security;
alter table public.member_devices enable row level security;
alter table public.wallet_accounts enable row level security;
alter table public.wallet_addresses enable row level security;
alter table public.transactions enable row level security;
alter table public.user_daily_attendance enable row level security;
alter table public.roulette_spins enable row level security;
alter table public.collector_sessions enable row level security;
alter table public.referral_network enable row level security;
alter table public.notifications enable row level security;
alter table public.event_participants enable row level security;
alter table public.daily_quiz_progress enable row level security;
alter table public.prediction_records enable row level security;
alter table public.sim_orders enable row level security;
alter table public.sim_positions enable row level security;
alter table public.qr_sessions enable row level security;
create policy member_select_self
on public.member for select to authenticated
using (user_id = (select auth.uid()));
-- member 변경은 rpc_update_member_settings()로 제한한다.
-- role/status/referrer 같은 민감 컬럼을 일반 UPDATE 정책으로 열지 않는다.

create policy wallet_accounts_select_self
on public.wallet_accounts for select to authenticated
using (user_id = (select auth.uid()));
create policy wallet_addresses_select_self
on public.wallet_addresses for select to authenticated
using (user_id = (select auth.uid()));
create policy transactions_select_participant
on public.transactions for select to authenticated
using (
  sender_user_id = (select auth.uid())
  or receiver_user_id = (select auth.uid())
);
create policy attendance_select_self
on public.user_daily_attendance for select to authenticated
using (user_id = (select auth.uid()));
create policy roulette_select_self
on public.roulette_spins for select to authenticated
using (user_id = (select auth.uid()));
create policy collector_select_self
on public.collector_sessions for select to authenticated
using (user_id = (select auth.uid()));
create policy notifications_select_self
on public.notifications for select to authenticated
using (user_id = (select auth.uid()));
-- 알림 읽음도 rpc_mark_notifications_read()로만 처리한다.


create policy member_devices_select_self
on public.member_devices for select to authenticated
using (user_id = (select auth.uid()));
create policy referral_network_select_related
on public.referral_network for select to authenticated
using (
  referrer_user_id = (select auth.uid())
  or referred_user_id = (select auth.uid())
);
create policy event_participants_select_self
on public.event_participants for select to authenticated
using (user_id = (select auth.uid()));
create policy daily_quiz_progress_select_self
on public.daily_quiz_progress for select to authenticated
using (user_id = (select auth.uid()));
create policy prediction_records_select_self
on public.prediction_records for select to authenticated
using (user_id = (select auth.uid()));
create policy sim_orders_select_self
on public.sim_orders for select to authenticated
using (user_id = (select auth.uid()));
create policy sim_positions_select_self
on public.sim_positions for select to authenticated
using (user_id = (select auth.uid()));
create policy qr_sessions_select_self
on public.qr_sessions for select to authenticated
using (user_id = (select auth.uid()));
create policy public_read_chat_notices
on public.chat_notices for select to anon, authenticated
using (
  is_active = true
  and (starts_at is null or starts_at <= now())
  and (ends_at is null or ends_at >= now())
);
create policy public_read_app_settings
on public.app_settings for select to anon, authenticated
using (is_active = true);
create policy public_read_app_versions
on public.app_versions for select to anon, authenticated
using (is_active = true);
create policy public_read_blocked_versions
on public.blocked_versions for select to anon, authenticated
using (true);
create policy public_read_events
on public.events for select to anon, authenticated
using (
  is_active = true
  and (start_at is null or start_at <= now())
  and (end_at is null or end_at >= now())
);
create policy public_read_platform_fee_config
on public.platform_fee_config for select to authenticated
using (is_active = true);
-- referral friend 목록은 member 테이블을 직접 공개하지 말고
-- rpc_list_referred_members()에서 이름/프로필/가입일만 반환한다.

-- -----------------------------------------------------------------------------
-- 권장 RPC 목록 (함수 구현은 다음 migration에서)
-- -----------------------------------------------------------------------------
-- rpc_bootstrap_member(p_referral_code text)
-- rpc_get_home_snapshot()
-- rpc_get_weekly_attendance()
-- rpc_check_daily_attendance(p_idempotency_key text)
-- rpc_spin_daily_roulette(p_idempotency_key text)
-- rpc_start_collector()
-- rpc_claim_collector(p_idempotency_key text)
-- rpc_transfer_asset(p_receiver text, p_asset_code text, p_amount numeric, p_idempotency_key text)
-- rpc_list_transactions(p_limit int, p_cursor timestamptz)
-- rpc_list_referred_members()
-- rpc_mark_notifications_read(p_ids uuid[])
-- rpc_join_event(p_event_id uuid, p_idempotency_key text)
-- rpc_submit_quiz_answer(...)
-- rpc_place_sim_order(...)
-- rpc_close_sim_position(...)
-- rpc_settle_predictions(...): service_role/cron 전용;
