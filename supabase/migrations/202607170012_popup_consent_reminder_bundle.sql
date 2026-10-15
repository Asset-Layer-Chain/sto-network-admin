-- Popup consent reminder bundle.
-- Welcome reward remains independent from all consent flags. The follow-up
-- reminder is shown whenever either marketing or benefit Push is not agreed.

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
  v_marketing_consent public.member_consents%rowtype;
  v_benefit_push_consent public.member_consents%rowtype;
  v_reward_found boolean := false;
  v_marketing_agreed boolean := false;
  v_benefit_push_agreed boolean := false;
  v_missing text[] := array[]::text[];
  v_should_show_consent boolean := false;
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

  v_marketing_agreed := coalesce(v_member.marketing_agreed, false);
  v_benefit_push_agreed := coalesce(v_member.push_notifications_enabled, false);

  if not v_marketing_agreed then
    v_missing := array_append(v_missing, 'marketing_push');
  end if;

  if not v_benefit_push_agreed then
    v_missing := array_append(v_missing, 'benefit_push');
  end if;

  v_should_show_consent := coalesce(array_length(v_missing, 1), 0) > 0;

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
    v_user_id,
    'marketing_push',
    case when v_marketing_agreed then 'agreed' else 'pending' end,
    '2025-01-15',
    'app_popup',
    case when v_marketing_agreed then now() else null end,
    case when v_marketing_agreed then now() else null end,
    null
  ),
  (
    v_user_id,
    'benefit_push',
    case when v_benefit_push_agreed then 'agreed' else 'pending' end,
    '2025-01-15',
    'app_popup',
    case when v_benefit_push_agreed then now() else null end,
    case when v_benefit_push_agreed then now() else null end,
    null
  )
  on conflict (user_id, consent_type) do nothing;

  select * into v_marketing_consent
    from public.member_consents
   where user_id = v_user_id
     and consent_type = 'marketing_push';

  select * into v_benefit_push_consent
    from public.member_consents
   where user_id = v_user_id
     and consent_type = 'benefit_push';

  if v_should_show_consent then
    update public.member_consents
       set prompted_at = now(),
           updated_at = now()
     where user_id = v_user_id
       and consent_type = any(v_missing)
       and prompted_at is null;

    select * into v_marketing_consent
      from public.member_consents
     where user_id = v_user_id
       and consent_type = 'marketing_push';

    select * into v_benefit_push_consent
      from public.member_consents
     where user_id = v_user_id
       and consent_type = 'benefit_push';
  end if;

  select * into v_reward
    from public.member_welcome_rewards
   where user_id = v_user_id;
  v_reward_found := found;

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
    'consentReminder', jsonb_build_object(
      'status', case when v_should_show_consent then 'pending' else 'agreed' end,
      'show', v_should_show_consent,
      'marketingAgreed', v_marketing_agreed,
      'benefitPushAgreed', v_benefit_push_agreed,
      'missing', to_jsonb(v_missing),
      'marketing', jsonb_build_object(
        'status', coalesce(v_marketing_consent.status, case when v_marketing_agreed then 'agreed' else 'pending' end),
        'policyVersion', coalesce(v_marketing_consent.policy_version, '2025-01-15'),
        'promptedAt', v_marketing_consent.prompted_at,
        'updatedAt', v_marketing_consent.updated_at
      ),
      'benefitPush', jsonb_build_object(
        'status', coalesce(v_benefit_push_consent.status, case when v_benefit_push_agreed then 'agreed' else 'pending' end),
        'policyVersion', coalesce(v_benefit_push_consent.policy_version, '2025-01-15'),
        'promptedAt', v_benefit_push_consent.prompted_at,
        'updatedAt', v_benefit_push_consent.updated_at
      )
    ),
    -- Backward-compatible alias for older clients. It now follows the bundled
    -- reminder condition instead of marketing_push only.
    'marketingConsent', jsonb_build_object(
      'status', case when v_should_show_consent then 'pending' else 'agreed' end,
      'show', v_should_show_consent,
      'policyVersion', coalesce(v_marketing_consent.policy_version, '2025-01-15'),
      'promptedAt', v_marketing_consent.prompted_at,
      'updatedAt', nullif(greatest(
        coalesce(v_marketing_consent.updated_at, '-infinity'::timestamptz),
        coalesce(v_benefit_push_consent.updated_at, '-infinity'::timestamptz)
      ), '-infinity'::timestamptz)
    )
  );
end;
$$;
create or replace function public.rpc_update_popup_consents(
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
-- Keep the legacy RPC name as an alias used by older builds.
create or replace function public.rpc_update_marketing_consent(
  p_status text,
  p_source text default 'app_popup'
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
begin
  return public.rpc_update_popup_consents(p_status, p_source);
end;
$$;
revoke all on function public.rpc_get_app_popup_state() from public, anon;
revoke all on function public.rpc_update_popup_consents(text, text) from public, anon;
revoke all on function public.rpc_update_marketing_consent(text, text) from public, anon;
grant execute on function public.rpc_get_app_popup_state() to authenticated;
grant execute on function public.rpc_update_popup_consents(text, text) to authenticated;
grant execute on function public.rpc_update_marketing_consent(text, text) to authenticated;
notify pgrst, 'reload schema';
