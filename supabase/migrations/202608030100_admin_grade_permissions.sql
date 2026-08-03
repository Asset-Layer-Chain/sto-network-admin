-- STO Network Product Admin - 관리자 등급별 자산 권한
-- team_lead: airdrop
-- center_director: airdrop, withdrawal
-- headquarters: deposit, airdrop, withdrawal

create table if not exists public.admin_profiles (
  user_id uuid primary key references public.member(user_id) on delete cascade,
  admin_grade text not null check (
    admin_grade in ('team_lead', 'center_director', 'headquarters')
  ),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists admin_profiles_grade_active_idx
  on public.admin_profiles(admin_grade, is_active);

create or replace function private.touch_admin_profiles_updated_at()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function private.touch_admin_profiles_updated_at() from public, anon, authenticated;
drop trigger if exists admin_profiles_touch_updated_at on public.admin_profiles;
create trigger admin_profiles_touch_updated_at
before update on public.admin_profiles
for each row execute function private.touch_admin_profiles_updated_at();

alter table public.admin_profiles enable row level security;
revoke all on public.admin_profiles from public, anon, authenticated;

create or replace function private.admin_grade_for(
  p_user_id uuid,
  p_member_role text
)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_profile public.admin_profiles%rowtype;
begin
  select *
    into v_profile
    from public.admin_profiles ap
   where ap.user_id = p_user_id;

  if found then
    if not v_profile.is_active then
      return null;
    end if;
    return v_profile.admin_grade;
  end if;

  -- 기존 super_admin 계정은 프로필을 추가하기 전에도 본부 권한으로 호환한다.
  if p_member_role = 'super_admin' then
    return 'headquarters';
  end if;

  return null;
end;
$$;

create or replace function private.require_admin_asset_permission(
  p_user_id uuid,
  p_member_role text,
  p_action text
)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_action text := lower(trim(coalesce(p_action, '')));
  v_grade text;
  v_allowed boolean := false;
begin
  v_grade := private.admin_grade_for(p_user_id, p_member_role);

  if v_grade is null then
    raise exception using errcode = 'P0001', message = 'ADMIN_PROFILE_REQUIRED';
  end if;

  v_allowed := case v_action
    when 'airdrop' then v_grade in ('team_lead', 'center_director', 'headquarters')
    when 'withdrawal' then v_grade in ('center_director', 'headquarters')
    when 'deposit' then v_grade = 'headquarters'
    else false
  end;

  if not v_allowed then
    raise exception using errcode = 'P0001', message = 'ADMIN_ASSET_PERMISSION_DENIED';
  end if;

  return v_grade;
end;
$$;

revoke all on function private.admin_grade_for(uuid, text) from public, anon, authenticated;
revoke all on function private.require_admin_asset_permission(uuid, text, text) from public, anon, authenticated;

create or replace function public.rpc_admin_get_session()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_grade text;
  v_grade_label text;
begin
  v_admin := private.require_admin();
  v_grade := private.admin_grade_for(v_admin.user_id, v_admin.role);
  v_grade_label := case v_grade
    when 'team_lead' then '팀장급'
    when 'center_director' then '센터장'
    when 'headquarters' then '본부'
    else '자산 권한 미설정'
  end;

  return jsonb_build_object(
    'userId', v_admin.user_id,
    'memberNo', v_admin.mb_no,
    'memberId', v_admin.mb_id,
    'name', v_admin.mb_name,
    'email', v_admin.mb_email,
    'profile', v_admin.mb_profile,
    'role', v_admin.role,
    'adminGrade', v_grade,
    'adminGradeLabel', v_grade_label,
    'permissions', jsonb_build_object(
      'memberRead', true,
      'assetDeposit', v_grade = 'headquarters',
      'assetWithdrawal', v_grade in ('center_director', 'headquarters'),
      'assetAirdrop', v_grade in ('team_lead', 'center_director', 'headquarters'),
      'chatManage', true,
      'adminLogRead', true
    )
  );
end;
$$;

create or replace function public.rpc_admin_adjust_stoc(
  p_target_user_id uuid,
  p_action text,
  p_amount numeric,
  p_reason text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_admin_grade text;
  v_target public.member%rowtype;
  v_action text := lower(trim(coalesce(p_action, '')));
  v_reason text := trim(coalesce(p_reason, ''));
  v_key text := trim(coalesce(p_idempotency_key, ''));
  v_wallet public.wallet_accounts%rowtype;
  v_existing public.transactions%rowtype;
  v_transaction_id uuid;
  v_balance_before numeric;
  v_balance_after numeric;
  v_log_id uuid;
begin
  v_admin := private.require_admin();

  if v_action not in ('deposit', 'withdrawal', 'airdrop') then
    raise exception using errcode = 'P0001', message = 'INVALID_ADMIN_TRANSACTION_TYPE';
  end if;

  v_admin_grade := private.require_admin_asset_permission(
    v_admin.user_id,
    v_admin.role,
    v_action
  );

  if p_amount is null or p_amount <= 0 then
    raise exception using errcode = 'P0001', message = 'INVALID_AMOUNT';
  end if;
  if p_amount <> round(p_amount, 8) then
    raise exception using errcode = 'P0001', message = 'INVALID_AMOUNT_SCALE';
  end if;
  if p_amount > 999999999999999.99999999::numeric then
    raise exception using errcode = 'P0001', message = 'ADMIN_AMOUNT_LIMIT_EXCEEDED';
  end if;
  if char_length(v_reason) < 2 then
    raise exception using errcode = 'P0001', message = 'ADMIN_REASON_REQUIRED';
  end if;
  if v_key = '' then
    raise exception using errcode = 'P0001', message = 'IDEMPOTENCY_KEY_REQUIRED';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_key, 0));

  select * into v_existing
    from public.transactions t
   where t.idempotency_key = v_key;

  if found then
    if v_existing.transaction_type <> v_action
       or v_existing.amount <> p_amount
       or (v_action = 'withdrawal' and v_existing.sender_user_id is distinct from p_target_user_id)
       or (v_action in ('deposit', 'airdrop') and v_existing.receiver_user_id is distinct from p_target_user_id) then
      raise exception using errcode = 'P0001', message = 'IDEMPOTENCY_KEY_CONFLICT';
    end if;

    return jsonb_build_object(
      'alreadyProcessed', true,
      'action', v_action,
      'amount', p_amount::text,
      'balanceBefore', coalesce(v_existing.metadata ->> 'balance_before', '0'),
      'balanceAfter', coalesce(v_existing.metadata ->> 'balance_after', '0'),
      'transaction', private.admin_transaction_payload(v_existing.id)
    );
  end if;

  select * into v_target
    from public.member m
   where m.user_id = p_target_user_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'MEMBER_NOT_FOUND';
  end if;
  if v_target.status = 'deleted' or coalesce(v_target.is_del, false) then
    raise exception using errcode = 'P0001', message = 'MEMBER_DELETED';
  end if;

  insert into public.wallet_accounts(user_id, asset_code, account_type, available_balance, locked_balance)
  values (p_target_user_id, 'STOC_INT', 'internal', 0, 0)
  on conflict (user_id, asset_code, account_type) do nothing;

  select * into v_wallet
    from public.wallet_accounts wa
   where wa.user_id = p_target_user_id
     and wa.asset_code = 'STOC_INT'
     and wa.account_type = 'internal'
   for update;

  v_balance_before := v_wallet.available_balance;
  if v_action = 'withdrawal' and v_balance_before < p_amount then
    raise exception using errcode = 'P0001', message = 'INSUFFICIENT_BALANCE';
  end if;

  update public.wallet_accounts wa
     set available_balance = case
           when v_action = 'withdrawal' then wa.available_balance - p_amount
           else wa.available_balance + p_amount
         end,
         updated_at = now()
   where wa.id = v_wallet.id
  returning wa.available_balance into v_balance_after;

  insert into public.transactions(
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
    case when v_action = 'withdrawal' then p_target_user_id else null end,
    case when v_action in ('deposit', 'airdrop') then p_target_user_id else null end,
    'STOC_INT',
    p_amount,
    0,
    v_action,
    'completed',
    v_reason,
    'admin_adjustment',
    v_key,
    jsonb_build_object(
      'source', 'sto_network_admin',
      'admin_actor_user_id', v_admin.user_id,
      'admin_actor_member_id', v_admin.mb_id,
      'admin_grade', v_admin_grade,
      'target_user_id', p_target_user_id,
      'target_member_id', v_target.mb_id,
      'requested_action', v_action,
      'reason', v_reason,
      'balance_before', v_balance_before,
      'balance_after', v_balance_after
    ),
    now()
  ) returning id into v_transaction_id;

  insert into public.admin_action_logs(
    actor_user_id, action_type, target_user_id, transaction_id,
    reason, idempotency_key, before_data, after_data, metadata
  ) values (
    v_admin.user_id,
    'wallet.' || v_action,
    p_target_user_id,
    v_transaction_id,
    v_reason,
    v_key,
    jsonb_build_object('assetCode', 'STOC_INT', 'availableBalance', v_balance_before),
    jsonb_build_object('assetCode', 'STOC_INT', 'availableBalance', v_balance_after),
    jsonb_build_object(
      'amount', p_amount,
      'targetMemberId', v_target.mb_id,
      'adminGrade', v_admin_grade
    )
  ) returning id into v_log_id;

  return jsonb_build_object(
    'alreadyProcessed', false,
    'action', v_action,
    'amount', p_amount::text,
    'balanceBefore', v_balance_before::text,
    'balanceAfter', v_balance_after::text,
    'adminGrade', v_admin_grade,
    'adminLogId', v_log_id,
    'transaction', private.admin_transaction_payload(v_transaction_id)
  );
end;
$$;

revoke all on function public.rpc_admin_get_session() from public, anon;
revoke all on function public.rpc_admin_adjust_stoc(uuid, text, numeric, text, text) from public, anon;
grant execute on function public.rpc_admin_get_session() to authenticated;
grant execute on function public.rpc_admin_adjust_stoc(uuid, text, numeric, text, text) to authenticated;
