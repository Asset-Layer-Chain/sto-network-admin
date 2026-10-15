-- Keep expired notices visible in the archive while excluding disabled/future notices.
-- No changes to notification storage, read RPCs, or user-specific DB state.
create or replace function public.rpc_get_notifications()
returns table (
  id uuid,
  type text,
  title text,
  message text,
  payload jsonb,
  starts_at timestamptz,
  ends_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_active_member();

  return query
  select
    n.id,
    n.type,
    n.title,
    n.message,
    n.payload,
    n.starts_at,
    n.ends_at,
    n.created_at,
    n.updated_at
  from public.notifications n
  where n.is_active = true
    and (n.starts_at is null or n.starts_at <= now())
  order by coalesce(n.starts_at, n.created_at) desc, n.created_at desc
  limit 100;
end;
$$;
comment on function public.rpc_get_notifications() is
  'Returns published global notices, including expired notices, for active members. Client-side local read state controls the Bell indicator.';
