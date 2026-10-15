-- Welcome reward and first-entry marketing consent popup queue
-- Existing members are excluded from the welcome campaign at migration time.

create table if not exists public.member_welcome_rewards (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.member(user_id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'completed', 'failed', 'skipped')),
  target_krw_amount numeric(18, 2) not null default 100000
    check (target_krw_amount > 0),
  reference_price numeric(36, 18),
  granted_amount numeric(36, 18),
  granted_krw_value numeric(36, 2),
  price_at timestamptz,
  transaction_id uuid unique references public.transactions(id) on delete set null,
  failure_message text,
  popup_acknowledged_at timestamptz,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  updated_at timestamptz not null default now()
);
create index if not exists member_welcome_rewards_status_idx
  on public.member_welcome_rewards(status, created_at desc);
create trigger member_welcome_rewards_set_updated_at
before update on public.member_welcome_rewards
for each row execute function public.set_updated_at();
create table if not exists public.member_consents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.member(user_id) on delete cascade,
  consent_type text not null,
  status text not null default 'pending'
    check (status in ('pending', 'agreed', 'declined')),
  policy_version text not null default '2026-07-17',
  source text not null default 'app_popup',
  prompted_at timestamptz,
  consented_at timestamptz,
  declined_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, consent_type)
);
create index if not exists member_consents_user_status_idx
  on public.member_consents(user_id, consent_type, status);
create trigger member_consents_set_updated_at
before update on public.member_consents
for each row execute function public.set_updated_at();
alter table public.member_welcome_rewards enable row level security;
alter table public.member_consents enable row level security;
revoke all on public.member_welcome_rewards from anon, authenticated;
revoke all on public.member_consents from anon, authenticated;
-- Members that already exist when this migration runs are not new-signup recipients.
insert into public.member_welcome_rewards (
  user_id,
  status,
  failure_message,
  popup_acknowledged_at,
  created_at,
  updated_at
)
select
  m.user_id,
  'skipped',
  'PRE_CAMPAIGN_MEMBER',
  now(),
  now(),
  now()
from public.member m
on conflict (user_id) do nothing;
-- Existing explicit agreements are preserved. A false value is treated as
-- "not decided yet" so the first-entry popup can ask once.
insert into public.member_consents (
  user_id,
  consent_type,
  status,
  policy_version,
  source,
  prompted_at,
  consented_at,
  created_at,
  updated_at
)
select
  m.user_id,
  'marketing_push',
  case when m.marketing_agreed then 'agreed' else 'pending' end,
  '2026-07-17',
  'migration',
  case when m.marketing_agreed then now() else null end,
  case when m.marketing_agreed then now() else null end,
  now(),
  now()
from public.member m
on conflict (user_id, consent_type) do nothing;
create or replace function private.ensure_marketing_consent(p_user_id uuid)
returns public.member_consents
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_consent public.member_consents%rowtype;
  v_marketing_agreed boolean;
begin
  select marketing_agreed
    into v_marketing_agreed
    from public.member
   where user_id = p_user_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'MEMBER_NOT_FOUND';
  end if;

  insert into public.member_consents (
    user_id,
    consent_type,
    status,
    policy_version,
    source,
    prompted_at,
    consented_at
  ) values (
    p_user_id,
    'marketing_push',
    case when v_marketing_agreed then 'agreed' else 'pending' end,
    '2026-07-17',
    'app_popup',
    case when v_marketing_agreed then now() else null end,
    case when v_marketing_agreed then now() else null end
  )
  on conflict (user_id, consent_type)
  do update set updated_at = member_consents.updated_at
  returning * into v_consent;

  return v_consent;
end;
$$;
revoke all on function private.ensure_marketing_consent(uuid)
  from public, anon, authenticated;
create or replace function public.rpc_get_app_popup_state()
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_member public.member%rowtype;
  v_reward public.member_welcome_rewards%rowtype;
  v_consent public.member_consents%rowtype;
  v_reward_found boolean := false;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  select * into v_member
    from public.member
   where user_id = v_user_id
     and status = 'active';

  if not found then
    raise exception using errcode = 'P0001', message = 'MEMBER_NOT_FOUND';
  end if;

  v_consent := private.ensure_marketing_consent(v_user_id);

  select * into v_reward
    from public.member_welcome_rewards
   where user_id = v_user_id;
  v_reward_found := found;

  if v_consent.status = 'pending' and v_consent.prompted_at is null then
    update public.member_consents
       set prompted_at = now(),
           updated_at = now()
     where id = v_consent.id
    returning * into v_consent;
  end if;

  return jsonb_build_object(
    'welcomeReward', case
      when v_reward_found then jsonb_build_object(
        'id', v_reward.id,
        'status', v_reward.status,
        'show', v_reward.status = 'completed' and v_reward.popup_acknowledged_at is null,
        'targetKrwAmount', v_reward.target_krw_amount,
        'referencePrice', v_reward.reference_price,
        'grantedAmount', v_reward.granted_amount,
        'grantedKrwValue', v_reward.granted_krw_value,
        'priceAt', v_reward.price_at,
        'completedAt', v_reward.completed_at,
        'acknowledgedAt', v_reward.popup_acknowledged_at
      )
      else jsonb_build_object(
        'status', 'eligible',
        'show', false,
        'targetKrwAmount', 100000
      )
    end,
    'marketingConsent', jsonb_build_object(
      'status', v_consent.status,
      'show', v_consent.status = 'pending',
      'policyVersion', v_consent.policy_version,
      'promptedAt', v_consent.prompted_at,
      'updatedAt', v_consent.updated_at
    )
  );
end;
$$;
create or replace function public.rpc_acknowledge_welcome_reward()
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_reward public.member_welcome_rewards%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  update public.member_welcome_rewards
     set popup_acknowledged_at = coalesce(popup_acknowledged_at, now()),
         updated_at = now()
   where user_id = v_user_id
     and status = 'completed'
  returning * into v_reward;

  if not found then
    raise exception using errcode = 'P0001', message = 'WELCOME_REWARD_NOT_COMPLETED';
  end if;

  return jsonb_build_object(
    'status', v_reward.status,
    'acknowledgedAt', v_reward.popup_acknowledged_at
  );
end;
$$;
create or replace function public.rpc_update_marketing_consent(
  p_status text,
  p_source text default 'app_popup'
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_status text := lower(trim(coalesce(p_status, '')));
  v_source text := left(coalesce(nullif(trim(p_source), ''), 'app_popup'), 50);
  v_consent public.member_consents%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  if v_status not in ('agreed', 'declined') then
    raise exception using errcode = 'P0001', message = 'INVALID_MARKETING_CONSENT_STATUS';
  end if;

  perform private.require_active_member();
  perform pg_advisory_xact_lock(hashtextextended('marketing-consent:' || v_user_id::text, 0));

  insert into public.member_consents (
    user_id,
    consent_type,
    status,
    policy_version,
    source,
    prompted_at,
    consented_at,
    declined_at
  ) values (
    v_user_id,
    'marketing_push',
    v_status,
    '2026-07-17',
    v_source,
    now(),
    case when v_status = 'agreed' then now() else null end,
    case when v_status = 'declined' then now() else null end
  )
  on conflict (user_id, consent_type)
  do update set
    status = excluded.status,
    policy_version = excluded.policy_version,
    source = excluded.source,
    prompted_at = coalesce(member_consents.prompted_at, excluded.prompted_at),
    consented_at = case when excluded.status = 'agreed' then now() else null end,
    declined_at = case when excluded.status = 'declined' then now() else null end,
    updated_at = now()
  returning * into v_consent;

  update public.member
     set marketing_agreed = (v_status = 'agreed'),
         updated_at = now()
   where user_id = v_user_id;

  return jsonb_build_object(
    'consent', jsonb_build_object(
      'status', v_consent.status,
      'policyVersion', v_consent.policy_version,
      'source', v_consent.source,
      'consentedAt', v_consent.consented_at,
      'declinedAt', v_consent.declined_at,
      'updatedAt', v_consent.updated_at
    ),
    'member', private.member_snapshot(v_user_id)
  );
end;
$$;
-- Service-role-only function. The client never supplies price or reward amount.
create or replace function public.rpc_grant_welcome_reward(
  p_user_id uuid,
  p_reference_price numeric,
  p_granted_amount numeric,
  p_price_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_reward public.member_welcome_rewards%rowtype;
  v_transaction_id uuid;
  v_balance numeric;
  v_krw_value numeric;
  v_idempotency_key text;
begin
  if p_user_id is null then
    raise exception using errcode = '22023', message = 'WELCOME_REWARD_USER_REQUIRED';
  end if;

  if p_reference_price is null or p_reference_price <= 0 then
    raise exception using errcode = '22023', message = 'WELCOME_REWARD_PRICE_INVALID';
  end if;

  if p_granted_amount is null or p_granted_amount <= 0 then
    raise exception using errcode = '22023', message = 'WELCOME_REWARD_AMOUNT_INVALID';
  end if;

  v_krw_value := round(p_granted_amount * p_reference_price, 2);
  if v_krw_value < 100000 then
    raise exception using errcode = '22023', message = 'WELCOME_REWARD_BELOW_TARGET';
  end if;

  -- Prevent a malformed Edge deployment from issuing an unreasonable amount.
  if v_krw_value > 110000 then
    raise exception using errcode = '22023', message = 'WELCOME_REWARD_ABOVE_GUARD';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('welcome-reward:' || p_user_id::text, 0));

  if not exists (
    select 1 from public.member
     where user_id = p_user_id
       and status = 'active'
  ) then
    raise exception using errcode = 'P0001', message = 'MEMBER_NOT_FOUND';
  end if;

  select * into v_reward
    from public.member_welcome_rewards
   where user_id = p_user_id
   for update;

  if found and v_reward.status = 'skipped' then
    return jsonb_build_object('status', 'skipped');
  end if;

  if found and v_reward.status = 'completed' then
    return jsonb_build_object(
      'status', 'completed',
      'grantedAmount', v_reward.granted_amount,
      'grantedKrwValue', v_reward.granted_krw_value,
      'referencePrice', v_reward.reference_price,
      'priceAt', v_reward.price_at,
      'alreadyGranted', true
    );
  end if;

  if not found then
    insert into public.member_welcome_rewards (
      user_id,
      status,
      target_krw_amount
    ) values (
      p_user_id,
      'pending',
      100000
    )
    returning * into v_reward;
  end if;

  v_idempotency_key := 'welcome-reward:' || p_user_id::text;

  insert into public.transactions (
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
    p_user_id,
    'STOC_INT',
    p_granted_amount,
    0,
    'welcome_reward',
    'completed',
    '회원가입 축하 보상',
    'welcome_reward',
    v_reward.id,
    v_idempotency_key,
    jsonb_build_object(
      'target_krw_amount', 100000,
      'reference_price', p_reference_price,
      'granted_krw_value', v_krw_value,
      'price_at', coalesce(p_price_at, now()),
      'source', 'gopax:STOC-KRW'
    ),
    now()
  )
  returning id into v_transaction_id;

  v_balance := private.credit_wallet(p_user_id, 'STOC_INT', p_granted_amount, 'internal');

  update public.member_welcome_rewards
     set status = 'completed',
         reference_price = p_reference_price,
         granted_amount = p_granted_amount,
         granted_krw_value = v_krw_value,
         price_at = coalesce(p_price_at, now()),
         transaction_id = v_transaction_id,
         failure_message = null,
         completed_at = now(),
         updated_at = now()
   where id = v_reward.id
  returning * into v_reward;

  return jsonb_build_object(
    'status', v_reward.status,
    'grantedAmount', v_reward.granted_amount,
    'grantedKrwValue', v_reward.granted_krw_value,
    'referencePrice', v_reward.reference_price,
    'priceAt', v_reward.price_at,
    'balance', v_balance,
    'transactionId', v_transaction_id,
    'alreadyGranted', false
  );
end;
$$;
revoke all on function public.rpc_get_app_popup_state() from public, anon;
revoke all on function public.rpc_acknowledge_welcome_reward() from public, anon;
revoke all on function public.rpc_update_marketing_consent(text, text) from public, anon;
revoke all on function public.rpc_grant_welcome_reward(uuid, numeric, numeric, timestamptz)
  from public, anon, authenticated;
grant execute on function public.rpc_get_app_popup_state() to authenticated;
grant execute on function public.rpc_acknowledge_welcome_reward() to authenticated;
grant execute on function public.rpc_update_marketing_consent(text, text) to authenticated;
grant execute on function public.rpc_grant_welcome_reward(uuid, numeric, numeric, timestamptz)
  to service_role;
notify pgrst, 'reload schema';
