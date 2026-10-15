-- Legacy authentication migration bridge.
-- Legacy member data is read only by Edge Functions. This migration owns the
-- one-time claim, SMS-ticket consumption, member/security creation and STOC_INT
-- balance transfer in a single database transaction.

create table if not exists public.legacy_migration_attempts (
  id uuid primary key default extensions.gen_random_uuid(),
  mode text not null check (mode in ('google', 'pin')),
  legacy_mb_id text not null,
  legacy_email text,
  legacy_updated_at timestamptz,
  auth_user_id uuid references auth.users(id) on delete cascade,
  auth_email text,
  challenge_token_hash text not null,
  requester_ip_hash text,
  status text not null default 'pending'
    check (status in ('pending', 'completed', 'expired', 'failed')),
  expires_at timestamptz not null,
  verified_phone text,
  migrated_balance numeric(36, 18),
  failure_count integer not null default 0,
  last_error text,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists legacy_migration_attempts_lookup_idx
  on public.legacy_migration_attempts(legacy_mb_id, status, created_at desc);
create index if not exists legacy_migration_attempts_auth_idx
  on public.legacy_migration_attempts(auth_user_id, status, created_at desc)
  where auth_user_id is not null;
drop trigger if exists legacy_migration_attempts_set_updated_at
  on public.legacy_migration_attempts;
create trigger legacy_migration_attempts_set_updated_at
before update on public.legacy_migration_attempts
for each row execute function public.set_updated_at();
create table if not exists public.legacy_migration_claims (
  legacy_mb_id text primary key,
  user_id uuid not null unique references public.member(user_id) on delete restrict,
  attempt_id uuid not null unique references public.legacy_migration_attempts(id) on delete restrict,
  mode text not null check (mode in ('google', 'pin')),
  migrated_amount numeric(36, 18) not null default 0 check (migrated_amount >= 0),
  transaction_id uuid unique references public.transactions(id) on delete set null,
  legacy_updated_at timestamptz,
  completed_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create unique index if not exists legacy_migration_claims_mb_id_lower_uidx
  on public.legacy_migration_claims(lower(legacy_mb_id));
alter table public.legacy_migration_attempts enable row level security;
alter table public.legacy_migration_claims enable row level security;
revoke all on public.legacy_migration_attempts from public, anon, authenticated;
revoke all on public.legacy_migration_claims from public, anon, authenticated;
grant select, insert, update on public.legacy_migration_attempts to service_role;
grant select on public.legacy_migration_claims to service_role;
-- Service-only helper used by the PIN migration Edge Function before creating
-- an auth user. It never exposes this information to anon/authenticated roles.
create or replace function public.service_find_auth_user_by_email(p_email text)
returns jsonb
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select coalesce((
    select jsonb_build_object(
      'userId', u.id,
      'email', u.email,
      'hasMember', exists (
        select 1 from public.member m where m.user_id = u.id
      )
    )
      from auth.users u
     where lower(u.email) = lower(trim(coalesce(p_email, '')))
     order by u.created_at desc, u.id desc
     limit 1
  ), 'null'::jsonb);
$$;
revoke all on function public.service_find_auth_user_by_email(text)
  from public, anon, authenticated;
grant execute on function public.service_find_auth_user_by_email(text)
  to service_role;
create or replace function public.service_complete_legacy_migration(
  p_attempt_id uuid,
  p_challenge_token text,
  p_user_id uuid,
  p_signup_ticket text,
  p_member_id text,
  p_name text,
  p_email text,
  p_pin text,
  p_initial_aidas numeric,
  p_provider text,
  p_google_id text default null,
  p_avatar_url text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, auth, extensions, pg_temp
as $$
declare
  v_attempt public.legacy_migration_attempts%rowtype;
  v_claim public.legacy_migration_claims%rowtype;
  v_request public.phone_verification_requests%rowtype;
  v_member_id text := trim(coalesce(p_member_id, ''));
  v_name text := trim(coalesce(p_name, ''));
  v_email text := lower(trim(coalesce(p_email, '')));
  v_provider text := lower(trim(coalesce(p_provider, '')));
  v_amount numeric(36, 18) := greatest(coalesce(p_initial_aidas, 0), 0);
  v_phone text;
  v_transaction_id uuid;
  v_balance numeric(36, 18) := 0;
  v_synthetic_email text;
  v_existing_balance numeric(36, 18);
begin
  if p_attempt_id is null or p_user_id is null then
    raise exception using errcode = 'P0001', message = 'LEGACY_MIGRATION_INVALID_REQUEST';
  end if;

  select * into v_attempt
    from public.legacy_migration_attempts
   where id = p_attempt_id
   for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'LEGACY_MIGRATION_NOT_FOUND';
  end if;

  if v_attempt.challenge_token_hash <> private.signup_hash(coalesce(p_challenge_token, '')) then
    raise exception using errcode = 'P0001', message = 'LEGACY_MIGRATION_INVALID_CHALLENGE';
  end if;

  if v_attempt.status = 'completed' then
    select * into v_claim
      from public.legacy_migration_claims
     where attempt_id = v_attempt.id
        or legacy_mb_id = v_attempt.legacy_mb_id
     limit 1;

    if found and v_claim.user_id = p_user_id then
      return jsonb_build_object(
        'completed', true,
        'alreadyCompleted', true,
        'member', private.member_snapshot(p_user_id),
        'migratedAmount', v_claim.migrated_amount
      );
    end if;

    raise exception using errcode = 'P0001', message = 'LEGACY_ACCOUNT_ALREADY_MIGRATED';
  end if;

  if v_attempt.status <> 'pending' or v_attempt.expires_at <= now() then
    update public.legacy_migration_attempts
       set status = case when status = 'pending' then 'expired' else status end,
           last_error = 'LEGACY_MIGRATION_EXPIRED',
           updated_at = now()
     where id = v_attempt.id;
    raise exception using errcode = 'P0001', message = 'LEGACY_MIGRATION_EXPIRED';
  end if;

  if v_attempt.auth_user_id is not null and v_attempt.auth_user_id <> p_user_id then
    raise exception using errcode = 'P0001', message = 'LEGACY_MIGRATION_AUTH_MISMATCH';
  end if;

  if v_provider not in ('google', 'pin') or v_provider <> v_attempt.mode then
    raise exception using errcode = 'P0001', message = 'LEGACY_MIGRATION_MODE_MISMATCH';
  end if;

  if v_member_id = '' or lower(v_member_id) <> lower(trim(v_attempt.legacy_mb_id)) then
    raise exception using errcode = 'P0001', message = 'LEGACY_MIGRATION_MEMBER_MISMATCH';
  end if;
  if v_name = '' then
    v_name := v_member_id;
  end if;
  if length(coalesce(p_pin, '')) < 1 or length(coalesce(p_pin, '')) > 128 then
    raise exception using errcode = 'P0001', message = 'LEGACY_MIGRATION_INVALID_PIN';
  end if;
  if not exists (select 1 from auth.users u where u.id = p_user_id) then
    raise exception using errcode = 'P0001', message = 'AUTH_USER_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('legacy-migration:' || lower(v_attempt.legacy_mb_id), 0)
  );

  select * into v_claim
    from public.legacy_migration_claims
   where legacy_mb_id = v_attempt.legacy_mb_id
   for update;

  if found then
    if v_claim.user_id = p_user_id then
      update public.legacy_migration_attempts
         set status = 'completed',
             auth_user_id = p_user_id,
             migrated_balance = v_claim.migrated_amount,
             completed_at = coalesce(completed_at, now()),
             updated_at = now()
       where id = v_attempt.id;
      return jsonb_build_object(
        'completed', true,
        'alreadyCompleted', true,
        'member', private.member_snapshot(p_user_id),
        'migratedAmount', v_claim.migrated_amount
      );
    end if;
    raise exception using errcode = 'P0001', message = 'LEGACY_ACCOUNT_ALREADY_MIGRATED';
  end if;

  select * into v_request
    from public.phone_verification_requests r
   where r.ticket_hash = private.signup_hash(coalesce(p_signup_ticket, ''))
     and r.verified_at is not null
     and r.used_at is null
     and r.verified_at > now() - interval '15 minutes'
   order by r.created_at desc
   limit 1
   for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'PHONE_VERIFICATION_REQUIRED';
  end if;
  v_phone := v_request.phone_normalized;

  if exists (select 1 from public.member where user_id = p_user_id) then
    raise exception using errcode = 'P0001', message = 'MEMBER_ALREADY_EXISTS';
  end if;
  if exists (select 1 from public.member where lower(mb_id) = lower(v_member_id)) then
    raise exception using errcode = 'P0001', message = 'MEMBER_ID_ALREADY_USED';
  end if;
  if exists (
    select 1 from public.member
     where private.normalize_signup_phone(mb_hp) = v_phone
  ) then
    raise exception using errcode = 'P0001', message = 'PHONE_ALREADY_REGISTERED';
  end if;

  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
     or exists (select 1 from public.member where lower(mb_email) = v_email) then
    v_synthetic_email := lower(regexp_replace(v_member_id, '[^a-zA-Z0-9]', '', 'g'));
    if v_synthetic_email = '' then v_synthetic_email := 'legacy'; end if;
    v_email := left(v_synthetic_email, 48)
      || '+' || left(replace(p_user_id::text, '-', ''), 12)
      || '@legacy.stonetwork.invalid';
  end if;

  insert into public.member (
    user_id, mb_id, mb_name, mb_email, mb_hp, mb_profile,
    status, referral_code, google_linked, google_id,
    marketing_agreed, push_notifications_enabled, reg_channel,
    signup_method, signup_completed_at, phone_verified_at, last_login_at
  ) values (
    p_user_id,
    v_member_id,
    v_name,
    v_email,
    v_phone,
    nullif(trim(coalesce(p_avatar_url, '')), ''),
    'active',
    'LEG' || upper(left(replace(p_user_id::text, '-', ''), 12)),
    v_provider = 'google',
    case when v_provider = 'google' then nullif(trim(coalesce(p_google_id, '')), '') else null end,
    false,
    false,
    'legacy_migration',
    'legacy_migration',
    now(),
    now(),
    now()
  );

  insert into public.member_security (
    user_id, pin_hash, pin_updated_at, failed_attempts, locked_until, last_failed_at
  ) values (
    p_user_id,
    extensions.crypt(p_pin, extensions.gen_salt('bf', 10)),
    now(),
    0,
    null,
    null
  )
  on conflict (user_id) do update set
    pin_hash = excluded.pin_hash,
    pin_updated_at = excluded.pin_updated_at,
    failed_attempts = 0,
    locked_until = null,
    last_failed_at = null,
    updated_at = now();

  insert into public.wallet_accounts (
    user_id, asset_code, account_type, available_balance, locked_balance
  ) values
    (p_user_id, 'STOC_INT', 'internal', 0, 0),
    (p_user_id, 'BNB', 'internal', 0, 0)
  on conflict (user_id, asset_code, account_type) do nothing;

  if v_amount > 0 then
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
      v_amount,
      0,
      'legacy_migration',
      'completed',
      'Legacy STOC 자산 이전',
      'legacy_migration',
      v_attempt.id,
      'legacy-migration:' || lower(v_attempt.legacy_mb_id),
      jsonb_build_object(
        'legacy_mb_id', v_attempt.legacy_mb_id,
        'legacy_updated_at', v_attempt.legacy_updated_at,
        'source_column', 'member.initial_aidas',
        'target_asset_code', 'STOC_INT'
      ),
      now()
    ) returning id into v_transaction_id;

    v_balance := private.credit_wallet(p_user_id, 'STOC_INT', v_amount, 'internal');
  else
    select available_balance into v_existing_balance
      from public.wallet_accounts
     where user_id = p_user_id
       and asset_code = 'STOC_INT'
       and account_type = 'internal';
    v_balance := coalesce(v_existing_balance, 0);
  end if;

  insert into public.member_welcome_rewards (
    user_id,
    status,
    failure_message,
    popup_acknowledged_at,
    created_at,
    updated_at
  ) values (
    p_user_id,
    'skipped',
    'LEGACY_MIGRATED_MEMBER',
    now(),
    now(),
    now()
  ) on conflict (user_id) do nothing;

  insert into public.member_consents (
    user_id, consent_type, status, policy_version, source,
    prompted_at, consented_at, declined_at, created_at, updated_at
  ) values
    (p_user_id, 'service_terms', 'agreed', '2025-01-15', 'legacy_migration', now(), now(), null, now(), now()),
    (p_user_id, 'privacy_policy', 'agreed', '2025-01-15', 'legacy_migration', now(), now(), null, now(), now()),
    (p_user_id, 'marketing_push', 'pending', '2025-01-15', 'legacy_migration', null, null, null, now(), now()),
    (p_user_id, 'benefit_push', 'pending', '2025-01-15', 'legacy_migration', null, null, null, now(), now())
  on conflict (user_id, consent_type) do update set
    status = excluded.status,
    source = excluded.source,
    prompted_at = excluded.prompted_at,
    consented_at = excluded.consented_at,
    declined_at = excluded.declined_at,
    updated_at = now();

  insert into public.legacy_migration_claims (
    legacy_mb_id,
    user_id,
    attempt_id,
    mode,
    migrated_amount,
    transaction_id,
    legacy_updated_at,
    completed_at
  ) values (
    v_attempt.legacy_mb_id,
    p_user_id,
    v_attempt.id,
    v_attempt.mode,
    v_amount,
    v_transaction_id,
    v_attempt.legacy_updated_at,
    now()
  );

  update public.phone_verification_requests
     set used_at = now(), updated_at = now()
   where id = v_request.id;

  update public.legacy_migration_attempts
     set status = 'completed',
         auth_user_id = p_user_id,
         verified_phone = v_phone,
         migrated_balance = v_amount,
         completed_at = now(),
         last_error = null,
         updated_at = now()
   where id = v_attempt.id;

  return jsonb_build_object(
    'completed', true,
    'alreadyCompleted', false,
    'member', private.member_snapshot(p_user_id),
    'migratedAmount', v_amount,
    'availableBalance', v_balance
  );
exception
  when others then
    if p_attempt_id is not null then
      update public.legacy_migration_attempts
         set failure_count = failure_count + 1,
             last_error = sqlerrm,
             updated_at = now()
       where id = p_attempt_id
         and status = 'pending';
    end if;
    raise;
end;
$$;
revoke all on function public.service_complete_legacy_migration(
  uuid, text, uuid, text, text, text, text, text, numeric, text, text, text
) from public, anon, authenticated;
grant execute on function public.service_complete_legacy_migration(
  uuid, text, uuid, text, text, text, text, text, numeric, text, text, text
) to service_role;
create or replace function public.service_record_legacy_pin_attempt(
  p_member_id text,
  p_ip_hash text,
  p_success boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_key text := private.signup_hash(
    'legacy:' || lower(trim(coalesce(p_member_id, ''))) || ':'
    || coalesce(nullif(trim(p_ip_hash), ''), 'no-ip')
  );
  v_throttle public.pin_login_throttle%rowtype;
  v_next_attempts integer;
  v_locked_until timestamptz;
begin
  perform pg_advisory_xact_lock(hashtextextended('legacy-pin-login:' || v_key, 0));

  select * into v_throttle
    from public.pin_login_throttle
   where throttle_key = v_key
   for update;

  if found and v_throttle.locked_until is not null and v_throttle.locked_until > now() then
    return jsonb_build_object(
      'allowed', false,
      'error', 'PIN_LOGIN_TEMPORARILY_LOCKED',
      'lockedUntil', v_throttle.locked_until
    );
  end if;

  if found and v_throttle.last_failed_at is not null
     and v_throttle.last_failed_at > now() - interval '1 second' then
    return jsonb_build_object('allowed', false, 'error', 'PIN_LOGIN_TRY_AGAIN');
  end if;

  if coalesce(p_success, false) then
    delete from public.pin_login_throttle where throttle_key = v_key;
    return jsonb_build_object('allowed', true);
  end if;

  v_next_attempts := coalesce(v_throttle.failed_attempts, 0) + 1;
  v_locked_until := case
    when v_next_attempts >= 5 then now() + interval '15 minutes'
    else null
  end;

  insert into public.pin_login_throttle(
    throttle_key, failed_attempts, locked_until, last_failed_at
  ) values (
    v_key, v_next_attempts, v_locked_until, now()
  )
  on conflict (throttle_key) do update set
    failed_attempts = excluded.failed_attempts,
    locked_until = excluded.locked_until,
    last_failed_at = excluded.last_failed_at,
    updated_at = now();

  return jsonb_build_object(
    'allowed', false,
    'error', case
      when v_locked_until is not null then 'PIN_LOGIN_TEMPORARILY_LOCKED'
      else 'INVALID_MEMBER_ID_OR_PIN'
    end,
    'remainingAttempts', greatest(0, 5 - v_next_attempts),
    'lockedUntil', v_locked_until
  );
end;
$$;
revoke all on function public.service_record_legacy_pin_attempt(text, text, boolean)
  from public, anon, authenticated;
grant execute on function public.service_record_legacy_pin_attempt(text, text, boolean)
  to service_role;
notify pgrst, 'reload schema';
