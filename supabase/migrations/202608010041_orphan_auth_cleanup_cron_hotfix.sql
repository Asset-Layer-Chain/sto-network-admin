-- 041: Schedule cleanup for Google OAuth auth users that never completed STO member signup/migration.
--
-- Required secrets before the cron job can successfully call the function:
--   1) Function secret: ORPHAN_AUTH_CLEANUP_SECRET
--   2) DB Vault secret: orphan_auth_cleanup_secret       -- same value as function secret
--   3) DB Vault secret: orphan_auth_cleanup_project_url  -- e.g. https://YOUR_PROJECT_REF.supabase.co
--
-- The cron body intentionally deletes only users older/inactive for 24+ hours and caps each run.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;
-- Replace the job if it already exists.
do $$
begin
  perform cron.unschedule('cleanup-google-orphan-auth-users');
exception
  when others then
    null;
end $$;
select cron.schedule(
  'cleanup-google-orphan-auth-users',
  '30 18 * * *', -- KST 03:30 every day
  $$
  with cleanup_config as (
    select
      (
        select rtrim(decrypted_secret, '/')
        from vault.decrypted_secrets
        where name = 'orphan_auth_cleanup_project_url'
        limit 1
      ) as project_url,
      (
        select decrypted_secret
        from vault.decrypted_secrets
        where name = 'orphan_auth_cleanup_secret'
        limit 1
      ) as cleanup_secret
  )
  select case
    when project_url is null
      or cleanup_secret is null
      or trim(project_url) = ''
      or trim(cleanup_secret) = ''
    then null::bigint
    else net.http_post(
      url := project_url || '/functions/v1/orphan-auth-cleanup',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-cleanup-secret', cleanup_secret
      ),
      body := jsonb_build_object(
        'dryRun', false,
        'olderThanHours', 24,
        'maxScan', 1000,
        'maxDelete', 50,
        'source', 'pg_cron_daily'
      )
    )
  end as request_id
  from cleanup_config;
  $$
);
