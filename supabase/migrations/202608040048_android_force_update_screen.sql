begin;
-- Android WebView 강제 업데이트 정책.
-- 10831 APK/AAB가 Play Store에 100% 노출된 뒤 force_update를 true로 전환한다.
update public.app_versions
set is_active = false
where platform = 'android'
  and is_active = true;
insert into public.app_versions (
  platform,
  version,
  version_code,
  min_supported_version,
  force_update,
  release_notes,
  download_url,
  is_active,
  released_at
)
values (
  'android',
  '8.1.0.2',
  10831,
  '8.1.0.2',
  false,
  '앱 안정성 개선 및 최신 버전 업데이트',
  'https://play.google.com/store/apps/details?id=com.stochain',
  true,
  now()
)
on conflict (platform, version)
do update set
  version_code = excluded.version_code,
  min_supported_version = excluded.min_supported_version,
  force_update = excluded.force_update,
  release_notes = excluded.release_notes,
  download_url = excluded.download_url,
  is_active = excluded.is_active,
  released_at = excluded.released_at;
create or replace function public.rpc_get_app_update_policy(
  p_platform text default 'android'
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (
      select jsonb_build_object(
        'platform', av.platform,
        'versionName', av.version,
        'versionCode', av.version_code,
        'forceUpdate', av.force_update,
        'downloadUrl', av.download_url,
        'releaseNotes', av.release_notes,
        'releasedAt', av.released_at
      )
      from public.app_versions av
      where av.platform = p_platform
        and av.is_active = true
      order by av.version_code desc nulls last,
               av.released_at desc
      limit 1
    ),
    '{}'::jsonb
  );
$$;
revoke all on function public.rpc_get_app_update_policy(text) from public;
grant execute on function public.rpc_get_app_update_policy(text) to anon, authenticated;
commit;
