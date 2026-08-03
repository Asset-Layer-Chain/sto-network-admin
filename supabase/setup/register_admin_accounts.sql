-- 관리자 Auth 계정 3개를 public.member / public.admin_profiles에 연결합니다.
-- 실행 전 Supabase Authentication > Users에서 아래 이메일 계정을 생성하거나,
-- 각 Google 계정으로 한 번 로그인하여 auth.users에 계정이 존재하게 해야 합니다.
-- 이메일은 운영 계정에 맞게 수정한 뒤 SQL Editor에서 실행하세요.

begin;

do $$
declare
  v_missing_emails text;
begin
  with admin_config(email) as (
    values
      ('teamlead.admin@stodev.xyz'::text),
      ('center.admin@stodev.xyz'::text),
      ('headquarters.admin@stodev.xyz'::text)
  )
  select string_agg(c.email, ', ' order by c.email)
    into v_missing_emails
    from admin_config c
    left join auth.users u on lower(u.email) = lower(c.email)
   where u.id is null;

  if v_missing_emails is not null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTH_USERS_NOT_FOUND: ' || v_missing_emails;
  end if;
end;
$$;

with admin_config(email, member_id, member_name, admin_grade) as (
  values
    ('teamlead.admin@stodev.xyz'::text, 'admin_team_lead'::text, '팀장급 관리자'::text, 'team_lead'::text),
    ('center.admin@stodev.xyz'::text, 'admin_center_director'::text, '센터장 관리자'::text, 'center_director'::text),
    ('headquarters.admin@stodev.xyz'::text, 'admin_headquarters'::text, '본부 관리자'::text, 'headquarters'::text)
)
insert into public.member (
  user_id,
  mb_id,
  mb_name,
  mb_email,
  status,
  role,
  referral_code,
  signup_method,
  signup_completed_at
)
select
  u.id,
  c.member_id,
  c.member_name,
  u.email,
  'active',
  'admin',
  'ADMIN-' || upper(substr(replace(u.id::text, '-', ''), 1, 16)),
  'admin',
  now()
from admin_config c
join auth.users u on lower(u.email) = lower(c.email)
on conflict (user_id) do update
set
  mb_id = excluded.mb_id,
  mb_name = excluded.mb_name,
  mb_email = excluded.mb_email,
  status = 'active',
  role = 'admin',
  is_del = false,
  deleted_at = null,
  deletion_reason_code = null,
  deletion_reason_text = null,
  updated_at = now();

with admin_config(email, admin_grade) as (
  values
    ('teamlead.admin@stodev.xyz'::text, 'team_lead'::text),
    ('center.admin@stodev.xyz'::text, 'center_director'::text),
    ('headquarters.admin@stodev.xyz'::text, 'headquarters'::text)
)
insert into public.admin_profiles (
  user_id,
  admin_grade,
  is_active
)
select
  u.id,
  c.admin_grade,
  true
from admin_config c
join auth.users u on lower(u.email) = lower(c.email)
on conflict (user_id) do update
set
  admin_grade = excluded.admin_grade,
  is_active = true,
  updated_at = now();

commit;

select
  m.user_id,
  m.mb_id,
  m.mb_name,
  m.mb_email,
  m.role,
  ap.admin_grade,
  ap.is_active
from public.member m
join public.admin_profiles ap on ap.user_id = m.user_id
where lower(m.mb_email) in (
  'teamlead.admin@stodev.xyz',
  'center.admin@stodev.xyz',
  'headquarters.admin@stodev.xyz'
)
order by case ap.admin_grade
  when 'team_lead' then 1
  when 'center_director' then 2
  when 'headquarters' then 3
  else 4
end;
