-- Social signups automatically opt in to both consent flags at member creation.
-- The first-entry benefit popup keeps its existing RPC name, but updates both
-- marketing and benefit Push consent in one database transaction.

create or replace function private.apply_social_signup_consents_before_insert()
returns trigger
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_provider text := 'email';
begin
  select lower(coalesce(
           nullif(au.raw_app_meta_data ->> 'provider', ''),
           nullif(au.raw_app_meta_data -> 'providers' ->> 0, ''),
           'email'
         ))
    into v_provider
    from auth.users au
   where au.id = new.user_id;

  -- Treat every non-password/non-phone provider as an external social provider.
  -- This applies only while the member row is first inserted, so a later login
  -- never overwrites consent choices changed in Settings.
  if coalesce(v_provider, 'email') not in ('email', 'phone', 'anonymous') then
    new.marketing_agreed := true;
    new.push_notifications_enabled := true;
  end if;

  return new;
end;
$$;
revoke all on function private.apply_social_signup_consents_before_insert()
  from public, anon, authenticated;
drop trigger if exists member_apply_social_signup_consents_before_insert
  on public.member;
create trigger member_apply_social_signup_consents_before_insert
before insert on public.member
for each row execute function private.apply_social_signup_consents_before_insert();
-- Keep the consent audit source explicit for new social members. This replaces
-- the prior AFTER INSERT trigger function while preserving its trigger.
create or replace function private.seed_member_consents_after_insert()
returns trigger
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_provider text := 'email';
  v_source text := 'member_create';
begin
  select lower(coalesce(
           nullif(au.raw_app_meta_data ->> 'provider', ''),
           nullif(au.raw_app_meta_data -> 'providers' ->> 0, ''),
           'email'
         ))
    into v_provider
    from auth.users au
   where au.id = new.user_id;

  if coalesce(v_provider, 'email') not in ('email', 'phone', 'anonymous') then
    v_source := 'social_signup';
  end if;

  insert into public.member_consents (
    user_id,
    consent_type,
    status,
    policy_version,
    source,
    prompted_at,
    consented_at,
    declined_at
  ) values
  (
    new.user_id,
    'marketing_push',
    case when new.marketing_agreed then 'agreed' else 'pending' end,
    '2025-01-15',
    v_source,
    case when new.marketing_agreed then now() else null end,
    case when new.marketing_agreed then now() else null end,
    null
  ),
  (
    new.user_id,
    'benefit_push',
    case when new.push_notifications_enabled then 'agreed' else 'declined' end,
    '2025-01-15',
    v_source,
    now(),
    case when new.push_notifications_enabled then now() else null end,
    case when not new.push_notifications_enabled then now() else null end
  )
  on conflict (user_id, consent_type) do nothing;

  return new;
end;
$$;
revoke all on function private.seed_member_consents_after_insert()
  from public, anon, authenticated;
-- Backward-compatible PopupQueue API. Agree/decline applies to both switches.
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
  v_marketing jsonb;
  v_benefit_push jsonb;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  if v_status not in ('agreed', 'declined') then
    raise exception using errcode = 'P0001', message = 'INVALID_MARKETING_CONSENT_STATUS';
  end if;

  perform private.require_active_member();
  perform pg_advisory_xact_lock(
    hashtextextended('popup-consent-bundle:' || v_user_id::text, 0)
  );

  v_marketing := public.rpc_update_member_consent(
    'marketing_push',
    v_status,
    v_source
  );
  v_benefit_push := public.rpc_update_member_consent(
    'benefit_push',
    v_status,
    v_source
  );

  return jsonb_build_object(
    'status', v_status,
    'consents', jsonb_build_object(
      'marketing', v_marketing -> 'consent',
      'benefitPush', v_benefit_push -> 'consent'
    ),
    'member', private.member_snapshot(v_user_id)
  );
end;
$$;
revoke all on function public.rpc_update_marketing_consent(text, text)
  from public, anon;
grant execute on function public.rpc_update_marketing_consent(text, text)
  to authenticated;
notify pgrst, 'reload schema';
