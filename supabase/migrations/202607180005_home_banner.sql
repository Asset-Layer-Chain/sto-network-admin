-- 045: 홈 하단 가로 이동 배너. 운영자는 home_banner row를 수정해 홈 배너 문구/색상/순서를 관리한다.

create table if not exists public.home_banner (
  id uuid primary key default gen_random_uuid(),
  message text not null,
  background_color text not null default '#000000',
  text_color text not null default '#ffffff',
  border_color text not null default '#d6b133',
  sort_order integer not null default 0,
  is_active boolean not null default true,
  starts_at timestamptz,
  ends_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (btrim(message) <> ''),
  check (char_length(message) <= 120),
  check (background_color ~ '^#[0-9A-Fa-f]{6}$'),
  check (text_color ~ '^#[0-9A-Fa-f]{6}$'),
  check (border_color ~ '^#[0-9A-Fa-f]{6}$')
);
create index if not exists home_banner_active_order_idx
  on public.home_banner(is_active, sort_order, created_at);
create index if not exists home_banner_active_period_idx
  on public.home_banner(is_active, starts_at, ends_at);
drop trigger if exists home_banner_set_updated_at on public.home_banner;
create trigger home_banner_set_updated_at
before update on public.home_banner
for each row execute function public.set_updated_at();
alter table public.home_banner enable row level security;
drop policy if exists home_banner_admin_all on public.home_banner;
create policy home_banner_admin_all
on public.home_banner for all to authenticated
using (
  exists (
    select 1
      from public.member m
     where m.user_id = (select auth.uid())
       and m.role in ('admin', 'super_admin')
  )
)
with check (
  exists (
    select 1
      from public.member m
     where m.user_id = (select auth.uid())
       and m.role in ('admin', 'super_admin')
  )
);
insert into public.home_banner(message, background_color, text_color, border_color, sort_order, is_active)
select '상담만 받아도 3만원 상당의 추가 혜택', '#000000', '#ffffff', '#d6b133', 10, true
where not exists (
  select 1
    from public.home_banner
   where message = '상담만 받아도 3만원 상당의 추가 혜택'
);
create or replace function public.rpc_get_home_banners()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_banners jsonb;
begin
  perform private.require_active_member();

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', hb.id,
        'message', hb.message,
        'backgroundColor', hb.background_color,
        'textColor', hb.text_color,
        'borderColor', hb.border_color,
        'sortOrder', hb.sort_order
      ) order by hb.sort_order asc, hb.created_at asc
    ),
    '[]'::jsonb
  )
    into v_banners
    from public.home_banner hb
   where hb.is_active
     and (hb.starts_at is null or hb.starts_at <= now())
     and (hb.ends_at is null or hb.ends_at > now());

  return jsonb_build_object('banners', v_banners);
end;
$$;
revoke all on function public.rpc_get_home_banners() from public, anon, authenticated;
grant execute on function public.rpc_get_home_banners() to authenticated;
notify pgrst, 'reload schema';
