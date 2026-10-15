-- Referral reward grant system.
-- Policy:
-- 1) When A registers B as referrer, both A and B receive 5 STOC once.
-- 2) B's direct referral count increases by 1.
-- 3) User display level starts at Lv.1; reaching the first reward tier at 10 direct referrals displays Lv.2.
-- 4) Level rewards are granted once per reached tier.

create table if not exists public.referral_reward_grants (
  id bigserial primary key,
  member_id uuid not null references public.member(user_id) on delete cascade,
  source_member_id uuid references public.member(user_id) on delete set null,
  reward_type text not null,
  reward_level integer,
  amount_stoc numeric(18, 6) not null,
  asset_code text not null default 'STOC_INT',
  status text not null default 'completed',
  granted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint referral_reward_grants_type_check check (reward_type in ('referred_signup', 'referrer_signup', 'level_reward')),
  constraint referral_reward_grants_status_check check (status in ('pending', 'completed', 'cancelled')),
  constraint referral_reward_grants_amount_nonnegative check (amount_stoc >= 0),
  constraint referral_reward_grants_level_required check (
    (reward_type = 'level_reward' and reward_level is not null and reward_level > 0)
    or (reward_type <> 'level_reward' and reward_level is null)
  )
);
create unique index if not exists referral_reward_grants_pair_once_idx
  on public.referral_reward_grants(member_id, source_member_id, reward_type)
  where reward_type in ('referred_signup', 'referrer_signup');
create unique index if not exists referral_reward_grants_level_once_idx
  on public.referral_reward_grants(member_id, reward_type, reward_level)
  where reward_type = 'level_reward';
create index if not exists referral_reward_grants_member_status_idx
  on public.referral_reward_grants(member_id, status, granted_at desc);
alter table public.referral_reward_grants enable row level security;
drop policy if exists referral_reward_grants_select_own on public.referral_reward_grants;
create policy referral_reward_grants_select_own
on public.referral_reward_grants for select to authenticated
using (member_id = auth.uid());
create or replace function private.grant_referral_reward(
  p_member_id uuid,
  p_source_member_id uuid,
  p_reward_type text,
  p_reward_level integer,
  p_amount_stoc numeric
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_grant_id bigint;
  v_amount numeric(18, 6) := coalesce(p_amount_stoc, 0);
  v_transaction_type text;
  v_description text;
begin
  if p_member_id is null or v_amount <= 0 then
    return false;
  end if;

  if p_reward_type = 'level_reward' then
    if p_reward_level is null or p_reward_level <= 0 then
      return false;
    end if;

    insert into public.referral_reward_grants(
      member_id,
      source_member_id,
      reward_type,
      reward_level,
      amount_stoc,
      asset_code,
      status,
      granted_at
    ) values (
      p_member_id,
      p_source_member_id,
      p_reward_type,
      p_reward_level,
      v_amount,
      'STOC_INT',
      'completed',
      now()
    )
    on conflict (member_id, reward_type, reward_level) where reward_type = 'level_reward'
    do nothing
    returning id into v_grant_id;
  else
    if p_source_member_id is null or p_reward_type not in ('referred_signup', 'referrer_signup') then
      return false;
    end if;

    insert into public.referral_reward_grants(
      member_id,
      source_member_id,
      reward_type,
      reward_level,
      amount_stoc,
      asset_code,
      status,
      granted_at
    ) values (
      p_member_id,
      p_source_member_id,
      p_reward_type,
      null,
      v_amount,
      'STOC_INT',
      'completed',
      now()
    )
    on conflict (member_id, source_member_id, reward_type) where reward_type in ('referred_signup', 'referrer_signup')
    do nothing
    returning id into v_grant_id;
  end if;

  if v_grant_id is null then
    return false;
  end if;

  insert into public.wallet_accounts(
    user_id,
    chain,
    asset_code,
    account_type,
    available_balance,
    locked_balance
  ) values (
    p_member_id,
    'stoc_internal',
    'STOC_INT',
    'internal',
    v_amount,
    0
  )
  on conflict (user_id, asset_code, account_type)
  do update set
    chain = coalesce(public.wallet_accounts.chain, excluded.chain),
    available_balance = coalesce(public.wallet_accounts.available_balance, 0) + excluded.available_balance,
    updated_at = now();

  v_transaction_type := case p_reward_type
    when 'referred_signup' then 'referral_referred_reward'
    when 'referrer_signup' then 'referral_referrer_reward'
    when 'level_reward' then 'referral_level_reward'
    else 'referral_reward'
  end;

  v_description := case p_reward_type
    when 'referred_signup' then '추천인 등록 보상'
    when 'referrer_signup' then '친구 추천 보상'
    when 'level_reward' then '추천 레벨 보상'
    else '추천 보상'
  end;

  insert into public.transactions(
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
    p_member_id,
    'STOC_INT',
    v_amount,
    0,
    v_transaction_type,
    'completed',
    v_description,
    'referral_reward',
    null,
    'referral-reward-grant:' || v_grant_id::text,
    jsonb_build_object(
      'grant_id', v_grant_id,
      'reward_type', p_reward_type,
      'reward_level', p_reward_level,
      'source_member_id', p_source_member_id,
      'asset_code', 'STOC_INT'
    ),
    now()
  )
  on conflict (idempotency_key) do nothing;

  return true;
end;
$$;
create or replace function private.apply_referral_rewards(
  p_referred_user_id uuid,
  p_referrer_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_base_reward numeric(18, 6) := 5;
  v_direct_count integer := 0;
  v_granted_referred boolean := false;
  v_granted_referrer boolean := false;
  v_level_grant_count integer := 0;
  v_level record;
begin
  if p_referred_user_id is null or p_referrer_user_id is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_referral');
  end if;

  if p_referred_user_id = p_referrer_user_id then
    return jsonb_build_object('ok', false, 'code', 'self_referral');
  end if;

  insert into public.referral_network(
    referrer_user_id,
    referred_user_id,
    depth,
    status,
    joined_at
  ) values (
    p_referrer_user_id,
    p_referred_user_id,
    1,
    'active',
    now()
  )
  on conflict (referrer_user_id, referred_user_id, depth)
  do update set
    status = 'active',
    joined_at = coalesce(public.referral_network.joined_at, excluded.joined_at);

  v_granted_referred := private.grant_referral_reward(
    p_referred_user_id,
    p_referrer_user_id,
    'referred_signup',
    null,
    v_base_reward
  );

  v_granted_referrer := private.grant_referral_reward(
    p_referrer_user_id,
    p_referred_user_id,
    'referrer_signup',
    null,
    v_base_reward
  );

  select count(*)::integer into v_direct_count
  from public.referral_network rn
  join public.member referred on referred.user_id = rn.referred_user_id
  where rn.referrer_user_id = p_referrer_user_id
    and rn.depth = 1
    and rn.status = 'active'
    and referred.status = 'active'
    and not coalesce(referred.is_del, false);

  for v_level in
    select level, reward_stoc
    from public.referral_reward_levels
    where is_active = true
      and required_referrals <= v_direct_count
    order by level asc
  loop
    if private.grant_referral_reward(
      p_referrer_user_id,
      p_referred_user_id,
      'level_reward',
      v_level.level,
      v_level.reward_stoc
    ) then
      v_level_grant_count := v_level_grant_count + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'directReferralCount', v_direct_count,
    'referredBaseRewardGranted', v_granted_referred,
    'referrerBaseRewardGranted', v_granted_referrer,
    'levelRewardGrantCount', v_level_grant_count
  );
end;
$$;
create or replace function private.apply_referral_rewards_from_member()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.referrer_user_id is null then
    return new;
  end if;

  if current_setting('sto.skip_referral_reward_trigger', true) = 'on' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    perform private.apply_referral_rewards(new.user_id, new.referrer_user_id);
  elsif old.referrer_user_id is distinct from new.referrer_user_id then
    perform private.apply_referral_rewards(new.user_id, new.referrer_user_id);
  end if;

  return new;
end;
$$;
drop trigger if exists member_apply_referral_rewards_trg on public.member;
create trigger member_apply_referral_rewards_trg
after insert or update of referrer_user_id on public.member
for each row
execute function private.apply_referral_rewards_from_member();
create or replace function public.rpc_register_referrer_by_code(
  p_referral_code text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_referrer public.member%rowtype;
  v_input text := trim(coalesce(p_referral_code, ''));
  v_existing_referrer uuid;
  v_reward_result jsonb;
  v_updated_count integer := 0;
begin
  v_member := private.require_active_member();

  perform pg_advisory_xact_lock(
    hashtextextended('register-referrer:' || v_member.user_id::text, 0)
  );

  select * into v_member
    from public.member m
   where m.user_id = v_member.user_id
     and m.status = 'active'
     and not coalesce(m.is_del, false)
   for update;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'member_not_found',
      'message', '회원 정보를 찾을 수 없습니다.'
    );
  end if;

  if v_input = '' then
    return jsonb_build_object(
      'ok', false,
      'code', 'empty_referral_code',
      'message', '추천인 ID를 입력해주세요.'
    );
  end if;

  select rn.referrer_user_id
    into v_existing_referrer
    from public.referral_network rn
   where rn.referred_user_id = v_member.user_id
     and rn.depth = 1
     and rn.status = 'active'
   order by rn.joined_at desc nulls last, rn.created_at desc nulls last
   limit 1;

  if v_member.referrer_user_id is not null or v_existing_referrer is not null then
    return jsonb_build_object(
      'ok', false,
      'code', 'already_has_referrer',
      'message', '이미 추천인 ID가 등록되어 있습니다.'
    );
  end if;

  select * into v_referrer
    from public.member m
   where m.status = 'active'
     and not coalesce(m.is_del, false)
     and (
       lower(m.referral_code) = lower(v_input)
       or lower(m.mb_id) = lower(v_input)
     )
   order by case when lower(m.referral_code) = lower(v_input) then 0 else 1 end
   limit 1;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'not_found',
      'message', '추천인 ID를 찾을 수 없습니다.'
    );
  end if;

  if v_referrer.user_id = v_member.user_id then
    return jsonb_build_object(
      'ok', false,
      'code', 'self_referral',
      'message', '본인의 추천인 ID는 입력할 수 없습니다.'
    );
  end if;

  perform set_config('sto.skip_referral_reward_trigger', 'on', true);

  update public.member
     set referrer_user_id = v_referrer.user_id,
         updated_at = now()
   where user_id = v_member.user_id
     and referrer_user_id is null;

  get diagnostics v_updated_count = row_count;

  if v_updated_count <> 1 then
    return jsonb_build_object(
      'ok', false,
      'code', 'already_has_referrer',
      'message', '이미 추천인 ID가 등록되어 있습니다.'
    );
  end if;

  v_reward_result := private.apply_referral_rewards(v_member.user_id, v_referrer.user_id);

  return jsonb_build_object(
    'ok', true,
    'message', '추천인 ID가 등록되었습니다.',
    'reward', v_reward_result,
    'referrer', jsonb_build_object(
      'user_id', v_referrer.user_id,
      'mb_id', v_referrer.mb_id,
      'mb_name', v_referrer.mb_name,
      'referral_code', v_referrer.referral_code
    )
  );
end;
$$;
revoke all on function public.rpc_register_referrer_by_code(text) from public, anon;
grant execute on function public.rpc_register_referrer_by_code(text) to authenticated;
drop function if exists public.rpc_get_referral_reward_summary();
create or replace function public.rpc_get_referral_reward_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, pg_temp
as $rpc_get_referral_reward_summary$
declare
  v_member public.member%rowtype;
  v_direct_count integer := 0;
  v_yesterday_count integer := 0;
  v_base_reward numeric(18, 6) := 5;
  v_today_reward numeric(18, 6) := 0;
  v_total_reward numeric(18, 6) := 0;
  v_achieved_reward_level integer := 0;
  v_current_level integer := 1;
  v_next_level jsonb;
  v_levels jsonb;
begin
  v_member := private.require_active_member();

  select count(*)::integer into v_direct_count
  from public.referral_network rn
  join public.member referred on referred.user_id = rn.referred_user_id
  where rn.referrer_user_id = v_member.user_id
    and rn.depth = 1
    and rn.status = 'active'
    and referred.status = 'active'
    and not coalesce(referred.is_del, false);

  select coalesce(sum(rg.amount_stoc), 0)
    into v_today_reward
  from public.referral_reward_grants rg
  where rg.member_id = v_member.user_id
    and rg.status = 'completed'
    and rg.granted_at >= date_trunc('day', now())
    and rg.granted_at < date_trunc('day', now()) + interval '1 day';

  select count(*)::integer into v_yesterday_count
  from public.referral_network rn
  where rn.referrer_user_id = v_member.user_id
    and rn.depth = 1
    and rn.status = 'active'
    and rn.joined_at >= date_trunc('day', now()) - interval '1 day'
    and rn.joined_at < date_trunc('day', now());

  select coalesce(sum(rg.amount_stoc), 0)
    into v_total_reward
  from public.referral_reward_grants rg
  where rg.member_id = v_member.user_id
    and rg.status = 'completed';

  select coalesce(max(level), 0)
    into v_achieved_reward_level
  from public.referral_reward_levels
  where is_active = true
    and required_referrals <= v_direct_count;

  v_current_level := v_achieved_reward_level + 1;

  select jsonb_build_object(
    'rewardLevel', level,
    'level', level + 1,
    'requiredReferrals', required_referrals,
    'rewardStoc', reward_stoc,
    'remaining', greatest(required_referrals - v_direct_count, 0)
  ) into v_next_level
  from public.referral_reward_levels
  where is_active = true
    and required_referrals > v_direct_count
  order by required_referrals asc
  limit 1;

  select coalesce(jsonb_agg(jsonb_build_object(
    'rewardLevel', level,
    'level', level + 1,
    'requiredReferrals', required_referrals,
    'rewardStoc', reward_stoc
  ) order by level asc), '[]'::jsonb)
    into v_levels
  from public.referral_reward_levels
  where is_active = true;

  return jsonb_build_object(
    'directReferralCount', v_direct_count,
    'todayRewardStoc', v_today_reward,
    'yesterdayReferralCount', v_yesterday_count,
    'totalRewardStoc', v_total_reward,
    'baseRewardStoc', v_base_reward,
    'currentLevel', v_current_level,
    'nextLevel', v_next_level,
    'levels', v_levels,
    'updatedAt', now()
  );
end;
$rpc_get_referral_reward_summary$;
revoke all on function public.rpc_get_referral_reward_summary() from public, anon;
grant execute on function public.rpc_get_referral_reward_summary() to authenticated;
drop function if exists public.rpc_list_friend_members(integer);
create or replace function public.rpc_list_friend_members(
  p_limit integer default 100
)
returns table (
  user_id uuid,
  mb_no bigint,
  mb_id text,
  mb_name text,
  mb_email text,
  mb_profile text,
  relation_type text,
  referral_status text,
  joined_at timestamptz,
  created_at timestamptz,
  direct_referral_count integer,
  friend_level integer
)
language plpgsql
stable
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 200);
begin
  v_member := private.require_active_member();

  return query
  with referrer_edges as (
    select rn.referrer_user_id as referrer_user_id, rn.status as referral_status, rn.joined_at
    from public.referral_network rn
    where rn.referred_user_id = v_member.user_id
      and rn.depth = 1
      and rn.status = 'active'

    union all

    select v_member.referrer_user_id as referrer_user_id, 'active'::text as referral_status, v_member.created_at as joined_at
    where v_member.referrer_user_id is not null
  ),
  distinct_referrers as (
    select distinct on (re.referrer_user_id) re.referrer_user_id, re.referral_status, re.joined_at
    from referrer_edges re
    where re.referrer_user_id is not null
    order by re.referrer_user_id, re.joined_at desc nulls last
  ),
  friends as (
    select
      referrer.user_id,
      referrer.mb_no,
      referrer.mb_id,
      referrer.mb_name,
      referrer.mb_email,
      referrer.mb_profile,
      'referrer'::text as relation_type,
      coalesce(dr.referral_status, 'active') as referral_status,
      coalesce(dr.joined_at, v_member.created_at) as joined_at,
      referrer.created_at,
      0 as relation_order
    from distinct_referrers dr
    join public.member referrer on referrer.user_id = dr.referrer_user_id
    where referrer.status = 'active'
      and not coalesce(referrer.is_del, false)

    union all

    select
      referred.user_id,
      referred.mb_no,
      referred.mb_id,
      referred.mb_name,
      referred.mb_email,
      referred.mb_profile,
      'referred'::text as relation_type,
      rn.status as referral_status,
      rn.joined_at,
      referred.created_at,
      1 as relation_order
    from public.referral_network rn
    join public.member referred on referred.user_id = rn.referred_user_id
    where rn.referrer_user_id = v_member.user_id
      and rn.depth = 1
      and rn.status = 'active'
      and referred.status = 'active'
      and not coalesce(referred.is_del, false)
  ),
  friend_counts as (
    select
      f.*,
      (
        select count(*)::integer
        from public.referral_network child_rn
        join public.member child on child.user_id = child_rn.referred_user_id
        where child_rn.referrer_user_id = f.user_id
          and child_rn.depth = 1
          and child_rn.status = 'active'
          and child.status = 'active'
          and not coalesce(child.is_del, false)
      ) as direct_referral_count
    from friends f
  )
  select
    fc.user_id,
    fc.mb_no,
    fc.mb_id,
    fc.mb_name,
    fc.mb_email,
    fc.mb_profile,
    fc.relation_type,
    fc.referral_status,
    fc.joined_at,
    fc.created_at,
    fc.direct_referral_count,
    coalesce((
      select max(rrl.level)
      from public.referral_reward_levels rrl
      where rrl.is_active = true
        and rrl.required_referrals <= fc.direct_referral_count
    ), 0) + 1 as friend_level
  from friend_counts fc
  order by fc.relation_order asc, fc.joined_at desc nulls last, fc.created_at desc
  limit v_limit;
end;
$$;
revoke all on function public.rpc_list_friend_members(integer) from public, anon;
grant execute on function public.rpc_list_friend_members(integer) to authenticated;
