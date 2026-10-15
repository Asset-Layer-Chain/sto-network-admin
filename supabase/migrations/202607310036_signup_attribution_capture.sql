-- 036: Capture signup attribution URL parameters and connect them to members.
-- This records first/last/signup touch data when member-signup completes.

alter table public.member
  add column if not exists signup_attribution_channel text,
  add column if not exists signup_attribution_source text,
  add column if not exists signup_attribution_medium text,
  add column if not exists signup_attribution_campaign text,
  add column if not exists signup_attribution_campaign_id text,
  add column if not exists signup_attribution_ad_group text,
  add column if not exists signup_attribution_ad_group_id text,
  add column if not exists signup_attribution_ad_creative text,
  add column if not exists signup_attribution_ad_creative_id text,
  add column if not exists signup_attribution_click_id text,
  add column if not exists signup_attribution_referral_code text,
  add column if not exists signup_attribution_landing_url text,
  add column if not exists signup_attribution_captured_at timestamptz;
create table if not exists public.marketing_attribution_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null check (event_type in ('first_touch', 'last_touch', 'signup', 'landing', 'deep_link', 'deferred_deep_link')),
  user_id uuid references public.member(user_id) on delete set null,
  anonymous_id text,
  session_id text,
  platform text,
  app_version text,
  raw_url text,
  landing_url text,
  referrer_url text,
  raw_params jsonb not null default '{}'::jsonb,
  attribution_payload jsonb not null default '{}'::jsonb,

  channel text,
  source text,
  medium text,
  campaign text,
  campaign_id text,
  ad_group text,
  ad_group_id text,
  ad_creative text,
  ad_creative_id text,
  ad_id text,
  click_id text,
  gclid text,
  gbraid text,
  wbraid text,
  gaid_raw text,
  routing_short_id text,
  tracking_template_id text,
  ad_type text,
  sub_id text,
  sub_id_1 text,
  sub_id_2 text,
  sub_id_3 text,
  referral_code text,
  referrer_timestamp_raw text,
  referrer_timestamp_at timestamptz,
  client_received_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists marketing_attribution_events_user_created_idx
  on public.marketing_attribution_events(user_id, created_at desc);
create index if not exists marketing_attribution_events_click_id_idx
  on public.marketing_attribution_events(click_id)
  where click_id is not null;
create index if not exists marketing_attribution_events_campaign_idx
  on public.marketing_attribution_events(channel, campaign, created_at desc);
alter table public.marketing_attribution_events enable row level security;
drop policy if exists marketing_attribution_events_select_own on public.marketing_attribution_events;
create policy marketing_attribution_events_select_own
on public.marketing_attribution_events
for select
to authenticated
using (auth.uid() = user_id);
grant select on table public.marketing_attribution_events to authenticated;
grant select, insert, update, delete on table public.marketing_attribution_events to service_role;
create table if not exists public.member_marketing_attribution (
  user_id uuid primary key references public.member(user_id) on delete cascade,
  first_touch_event_id uuid references public.marketing_attribution_events(id) on delete set null,
  last_touch_event_id uuid references public.marketing_attribution_events(id) on delete set null,
  signup_event_id uuid references public.marketing_attribution_events(id) on delete set null,

  channel text,
  source text,
  medium text,
  campaign text,
  campaign_id text,
  ad_group text,
  ad_group_id text,
  ad_creative text,
  ad_creative_id text,
  click_id text,
  referral_code text,
  landing_url text,
  attribution_payload jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
drop trigger if exists member_marketing_attribution_set_updated_at on public.member_marketing_attribution;
create trigger member_marketing_attribution_set_updated_at
before update on public.member_marketing_attribution
for each row execute function public.set_updated_at();
alter table public.member_marketing_attribution enable row level security;
drop policy if exists member_marketing_attribution_select_own on public.member_marketing_attribution;
create policy member_marketing_attribution_select_own
on public.member_marketing_attribution
for select
to authenticated
using (auth.uid() = user_id);
grant select on table public.member_marketing_attribution to authenticated;
grant select, insert, update, delete on table public.member_marketing_attribution to service_role;
create or replace function private.marketing_attribution_text(
  p_json jsonb,
  variadic p_keys text[]
)
returns text
language plpgsql
stable
set search_path = public, private, pg_temp
as $$
declare
  v_key text;
  v_value text;
begin
  if p_json is null then
    return null;
  end if;

  foreach v_key in array p_keys loop
    v_value := nullif(trim(p_json ->> v_key), '');
    if v_value is not null then return v_value; end if;

    v_value := nullif(trim(p_json #>> array['normalized', v_key]), '');
    if v_value is not null then return v_value; end if;

    v_value := nullif(trim(p_json #>> array['summary', v_key]), '');
    if v_value is not null then return v_value; end if;
  end loop;

  return null;
end;
$$;
revoke all on function private.marketing_attribution_text(jsonb, text[])
  from public, anon, authenticated;
create or replace function private.marketing_attribution_timestamp(p_value text)
returns timestamptz
language plpgsql
stable
set search_path = public, private, pg_temp
as $$
declare
  v_raw text := trim(coalesce(p_value, ''));
  v_ts timestamptz;
  v_epoch numeric;
begin
  if v_raw = '' then
    return null;
  end if;

  begin
    if v_raw ~ '^[0-9]{13}$' then
      v_epoch := v_raw::numeric / 1000;
      v_ts := to_timestamp(v_epoch);
    elsif v_raw ~ '^[0-9]{10}$' then
      v_ts := to_timestamp(v_raw::numeric);
    else
      v_ts := v_raw::timestamptz;
    end if;
  exception when others then
    return null;
  end;

  -- Keep malformed future/past install referrer timestamps as raw text only.
  if v_ts > now() + interval '1 day' or v_ts < now() - interval '2 years' then
    return null;
  end if;

  return v_ts;
end;
$$;
revoke all on function private.marketing_attribution_timestamp(text)
  from public, anon, authenticated;
create or replace function private.insert_marketing_attribution_event(
  p_user_id uuid,
  p_event_type text,
  p_event jsonb,
  p_summary jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_event jsonb := coalesce(p_event, '{}'::jsonb);
  v_summary jsonb := coalesce(p_summary, '{}'::jsonb);
  v_id uuid;
  v_referrer_timestamp_raw text;
begin
  if coalesce(jsonb_typeof(v_event), 'object') <> 'object' then
    v_event := '{}'::jsonb;
  end if;
  if coalesce(jsonb_typeof(v_summary), 'object') <> 'object' then
    v_summary := '{}'::jsonb;
  end if;

  if v_event = '{}'::jsonb and v_summary = '{}'::jsonb then
    return null;
  end if;

  v_referrer_timestamp_raw := coalesce(
    private.marketing_attribution_text(v_event, 'referrer_timestamp'),
    private.marketing_attribution_text(v_summary, 'referrer_timestamp')
  );

  insert into public.marketing_attribution_events (
    event_type,
    user_id,
    anonymous_id,
    session_id,
    platform,
    app_version,
    raw_url,
    landing_url,
    referrer_url,
    raw_params,
    attribution_payload,
    channel,
    source,
    medium,
    campaign,
    campaign_id,
    ad_group,
    ad_group_id,
    ad_creative,
    ad_creative_id,
    ad_id,
    click_id,
    gclid,
    gbraid,
    wbraid,
    gaid_raw,
    routing_short_id,
    tracking_template_id,
    ad_type,
    sub_id,
    sub_id_1,
    sub_id_2,
    sub_id_3,
    referral_code,
    referrer_timestamp_raw,
    referrer_timestamp_at,
    client_received_at
  ) values (
    p_event_type,
    p_user_id,
    coalesce(private.marketing_attribution_text(v_event, 'anonymousId', 'anonymous_id'), private.marketing_attribution_text(v_summary, 'anonymousId', 'anonymous_id')),
    coalesce(private.marketing_attribution_text(v_event, 'sessionId', 'session_id'), private.marketing_attribution_text(v_summary, 'sessionId', 'session_id')),
    coalesce(private.marketing_attribution_text(v_event, 'platform'), private.marketing_attribution_text(v_summary, 'platform')),
    coalesce(private.marketing_attribution_text(v_event, 'appVersion', 'app_version'), private.marketing_attribution_text(v_summary, 'appVersion', 'app_version')),
    private.marketing_attribution_text(v_event, 'rawUrl', 'raw_url'),
    private.marketing_attribution_text(v_event, 'landingUrl', 'landing_url'),
    private.marketing_attribution_text(v_event, 'referrerUrl', 'referrer_url'),
    coalesce(v_event -> 'rawParams', v_event -> 'raw_params', '{}'::jsonb),
    v_event,
    coalesce(private.marketing_attribution_text(v_summary, 'channel'), private.marketing_attribution_text(v_event, 'channel')),
    coalesce(private.marketing_attribution_text(v_summary, 'source', 'utm_source'), private.marketing_attribution_text(v_event, 'source', 'utm_source')),
    coalesce(private.marketing_attribution_text(v_summary, 'medium', 'utm_medium'), private.marketing_attribution_text(v_event, 'medium', 'utm_medium')),
    coalesce(private.marketing_attribution_text(v_summary, 'campaign', 'utm_campaign'), private.marketing_attribution_text(v_event, 'campaign', 'utm_campaign')),
    coalesce(private.marketing_attribution_text(v_summary, 'campaign_id'), private.marketing_attribution_text(v_event, 'campaign_id')),
    coalesce(private.marketing_attribution_text(v_summary, 'ad_group', 'adgroup'), private.marketing_attribution_text(v_event, 'ad_group', 'adgroup')),
    coalesce(private.marketing_attribution_text(v_summary, 'ad_group_id', 'adgroup_id'), private.marketing_attribution_text(v_event, 'ad_group_id', 'adgroup_id')),
    coalesce(private.marketing_attribution_text(v_summary, 'ad_creative', 'creative', 'utm_content'), private.marketing_attribution_text(v_event, 'ad_creative', 'creative', 'utm_content')),
    coalesce(private.marketing_attribution_text(v_summary, 'ad_creative_id', 'creative_id'), private.marketing_attribution_text(v_event, 'ad_creative_id', 'creative_id')),
    coalesce(private.marketing_attribution_text(v_summary, 'ad_id'), private.marketing_attribution_text(v_event, 'ad_id')),
    coalesce(private.marketing_attribution_text(v_summary, 'click_id'), private.marketing_attribution_text(v_event, 'click_id')),
    coalesce(private.marketing_attribution_text(v_summary, 'gclid'), private.marketing_attribution_text(v_event, 'gclid')),
    coalesce(private.marketing_attribution_text(v_summary, 'gbraid'), private.marketing_attribution_text(v_event, 'gbraid')),
    coalesce(private.marketing_attribution_text(v_summary, 'wbraid'), private.marketing_attribution_text(v_event, 'wbraid')),
    coalesce(private.marketing_attribution_text(v_summary, 'gaid_raw'), private.marketing_attribution_text(v_event, 'gaid_raw')),
    coalesce(private.marketing_attribution_text(v_summary, 'routing_short_id'), private.marketing_attribution_text(v_event, 'routing_short_id')),
    coalesce(private.marketing_attribution_text(v_summary, 'tracking_template_id'), private.marketing_attribution_text(v_event, 'tracking_template_id')),
    coalesce(private.marketing_attribution_text(v_summary, 'ad_type'), private.marketing_attribution_text(v_event, 'ad_type')),
    coalesce(private.marketing_attribution_text(v_summary, 'sub_id'), private.marketing_attribution_text(v_event, 'sub_id')),
    coalesce(private.marketing_attribution_text(v_summary, 'sub_id_1'), private.marketing_attribution_text(v_event, 'sub_id_1')),
    coalesce(private.marketing_attribution_text(v_summary, 'sub_id_2'), private.marketing_attribution_text(v_event, 'sub_id_2')),
    coalesce(private.marketing_attribution_text(v_summary, 'sub_id_3'), private.marketing_attribution_text(v_event, 'sub_id_3')),
    coalesce(private.marketing_attribution_text(v_summary, 'referral_code', 'ref', 'referral', 'referrer'), private.marketing_attribution_text(v_event, 'referral_code', 'ref', 'referral', 'referrer')),
    v_referrer_timestamp_raw,
    private.marketing_attribution_timestamp(v_referrer_timestamp_raw),
    private.marketing_attribution_timestamp(private.marketing_attribution_text(v_event, 'clientReceivedAt', 'client_received_at'))
  ) returning id into v_id;

  return v_id;
end;
$$;
revoke all on function private.insert_marketing_attribution_event(uuid, text, jsonb, jsonb)
  from public, anon, authenticated;
create or replace function public.service_record_member_marketing_attribution(
  p_user_id uuid,
  p_attribution jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_payload jsonb := coalesce(p_attribution, '{}'::jsonb);
  v_summary jsonb;
  v_first_touch jsonb;
  v_last_touch jsonb;
  v_signup_touch jsonb;
  v_first_event_id uuid;
  v_last_event_id uuid;
  v_signup_event_id uuid;
  v_channel text;
  v_source text;
  v_medium text;
  v_campaign text;
  v_campaign_id text;
  v_ad_group text;
  v_ad_group_id text;
  v_ad_creative text;
  v_ad_creative_id text;
  v_click_id text;
  v_referral_code text;
  v_landing_url text;
begin
  if auth.role() <> 'service_role' then
    raise exception using errcode = '42501', message = 'SERVICE_ROLE_REQUIRED';
  end if;

  if p_user_id is null then
    raise exception using errcode = 'P0001', message = 'USER_REQUIRED';
  end if;

  if coalesce(jsonb_typeof(v_payload), 'object') <> 'object' or v_payload = '{}'::jsonb then
    return jsonb_build_object('ok', true, 'recorded', false, 'code', 'empty_attribution');
  end if;

  v_summary := coalesce(v_payload -> 'summary', '{}'::jsonb);
  if coalesce(jsonb_typeof(v_summary), 'object') <> 'object' then
    v_summary := '{}'::jsonb;
  end if;

  v_first_touch := coalesce(v_payload -> 'firstTouch', '{}'::jsonb);
  v_last_touch := coalesce(v_payload -> 'lastTouch', '{}'::jsonb);
  v_signup_touch := coalesce(v_payload -> 'signupTouch', '{}'::jsonb);

  v_first_event_id := private.insert_marketing_attribution_event(p_user_id, 'first_touch', v_first_touch, v_summary);
  v_last_event_id := private.insert_marketing_attribution_event(p_user_id, 'last_touch', v_last_touch, v_summary);
  v_signup_event_id := private.insert_marketing_attribution_event(p_user_id, 'signup', v_signup_touch || jsonb_build_object('attribution', v_payload), v_summary);

  v_channel := private.marketing_attribution_text(v_summary, 'channel');
  v_source := private.marketing_attribution_text(v_summary, 'source', 'utm_source');
  v_medium := private.marketing_attribution_text(v_summary, 'medium', 'utm_medium');
  v_campaign := private.marketing_attribution_text(v_summary, 'campaign', 'utm_campaign');
  v_campaign_id := private.marketing_attribution_text(v_summary, 'campaign_id');
  v_ad_group := private.marketing_attribution_text(v_summary, 'ad_group', 'adgroup');
  v_ad_group_id := private.marketing_attribution_text(v_summary, 'ad_group_id', 'adgroup_id');
  v_ad_creative := private.marketing_attribution_text(v_summary, 'ad_creative', 'creative', 'utm_content');
  v_ad_creative_id := private.marketing_attribution_text(v_summary, 'ad_creative_id', 'creative_id');
  v_click_id := private.marketing_attribution_text(v_summary, 'click_id');
  v_referral_code := private.marketing_attribution_text(v_summary, 'referral_code', 'ref', 'referral', 'referrer');
  v_landing_url := coalesce(
    private.marketing_attribution_text(v_signup_touch, 'landingUrl', 'landing_url'),
    private.marketing_attribution_text(v_last_touch, 'landingUrl', 'landing_url'),
    private.marketing_attribution_text(v_first_touch, 'landingUrl', 'landing_url'),
    private.marketing_attribution_text(v_signup_touch, 'rawUrl', 'raw_url'),
    private.marketing_attribution_text(v_last_touch, 'rawUrl', 'raw_url'),
    private.marketing_attribution_text(v_first_touch, 'rawUrl', 'raw_url')
  );

  insert into public.member_marketing_attribution (
    user_id,
    first_touch_event_id,
    last_touch_event_id,
    signup_event_id,
    channel,
    source,
    medium,
    campaign,
    campaign_id,
    ad_group,
    ad_group_id,
    ad_creative,
    ad_creative_id,
    click_id,
    referral_code,
    landing_url,
    attribution_payload
  ) values (
    p_user_id,
    v_first_event_id,
    v_last_event_id,
    v_signup_event_id,
    v_channel,
    v_source,
    v_medium,
    v_campaign,
    v_campaign_id,
    v_ad_group,
    v_ad_group_id,
    v_ad_creative,
    v_ad_creative_id,
    v_click_id,
    v_referral_code,
    v_landing_url,
    v_payload
  )
  on conflict (user_id) do update set
    first_touch_event_id = coalesce(public.member_marketing_attribution.first_touch_event_id, excluded.first_touch_event_id),
    last_touch_event_id = excluded.last_touch_event_id,
    signup_event_id = coalesce(public.member_marketing_attribution.signup_event_id, excluded.signup_event_id),
    channel = coalesce(public.member_marketing_attribution.channel, excluded.channel),
    source = coalesce(public.member_marketing_attribution.source, excluded.source),
    medium = coalesce(public.member_marketing_attribution.medium, excluded.medium),
    campaign = coalesce(public.member_marketing_attribution.campaign, excluded.campaign),
    campaign_id = coalesce(public.member_marketing_attribution.campaign_id, excluded.campaign_id),
    ad_group = coalesce(public.member_marketing_attribution.ad_group, excluded.ad_group),
    ad_group_id = coalesce(public.member_marketing_attribution.ad_group_id, excluded.ad_group_id),
    ad_creative = coalesce(public.member_marketing_attribution.ad_creative, excluded.ad_creative),
    ad_creative_id = coalesce(public.member_marketing_attribution.ad_creative_id, excluded.ad_creative_id),
    click_id = coalesce(public.member_marketing_attribution.click_id, excluded.click_id),
    referral_code = coalesce(public.member_marketing_attribution.referral_code, excluded.referral_code),
    landing_url = coalesce(public.member_marketing_attribution.landing_url, excluded.landing_url),
    attribution_payload = case
      when public.member_marketing_attribution.attribution_payload = '{}'::jsonb then excluded.attribution_payload
      else public.member_marketing_attribution.attribution_payload
    end,
    updated_at = now();

  update public.member m
     set signup_attribution_channel = coalesce(m.signup_attribution_channel, v_channel),
         signup_attribution_source = coalesce(m.signup_attribution_source, v_source),
         signup_attribution_medium = coalesce(m.signup_attribution_medium, v_medium),
         signup_attribution_campaign = coalesce(m.signup_attribution_campaign, v_campaign),
         signup_attribution_campaign_id = coalesce(m.signup_attribution_campaign_id, v_campaign_id),
         signup_attribution_ad_group = coalesce(m.signup_attribution_ad_group, v_ad_group),
         signup_attribution_ad_group_id = coalesce(m.signup_attribution_ad_group_id, v_ad_group_id),
         signup_attribution_ad_creative = coalesce(m.signup_attribution_ad_creative, v_ad_creative),
         signup_attribution_ad_creative_id = coalesce(m.signup_attribution_ad_creative_id, v_ad_creative_id),
         signup_attribution_click_id = coalesce(m.signup_attribution_click_id, v_click_id),
         signup_attribution_referral_code = coalesce(m.signup_attribution_referral_code, v_referral_code),
         signup_attribution_landing_url = coalesce(m.signup_attribution_landing_url, v_landing_url),
         signup_attribution_captured_at = coalesce(m.signup_attribution_captured_at, now()),
         updated_at = now()
   where m.user_id = p_user_id;

  return jsonb_build_object(
    'ok', true,
    'recorded', true,
    'firstTouchEventId', v_first_event_id,
    'lastTouchEventId', v_last_event_id,
    'signupEventId', v_signup_event_id,
    'channel', v_channel,
    'campaign', v_campaign,
    'clickId', v_click_id,
    'referralCode', v_referral_code
  );
end;
$$;
revoke all on function public.service_record_member_marketing_attribution(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.service_record_member_marketing_attribution(uuid, jsonb)
  to service_role;
