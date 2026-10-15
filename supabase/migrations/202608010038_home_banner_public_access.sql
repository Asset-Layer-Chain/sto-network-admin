-- 038: 홈 배너는 로그인 전 앱/WebView 진입 화면에서도 조회되어야 하므로 public RPC로 복구한다.
-- - rpc_get_home_banners()에서 private.require_active_member() 호출 제거
-- - anon/authenticated 모두 execute 허용
-- - security definer 함수에서 활성 홈 배너만 반환

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
   where hb.is_active = true
     and (hb.starts_at is null or hb.starts_at <= now())
     and (hb.ends_at is null or hb.ends_at > now());

  return jsonb_build_object('banners', v_banners);
end;
$$;
revoke all on function public.rpc_get_home_banners() from public, anon, authenticated;
grant execute on function public.rpc_get_home_banners() to anon, authenticated;
notify pgrst, 'reload schema';
