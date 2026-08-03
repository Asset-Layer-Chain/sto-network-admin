-- STO Network Product Admin
-- 회원 조회, STOC_INT 관리자 조정, 그룹 채팅(최대 100명), 관리자 감사 로그

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists private;

-- ---------------------------------------------------------------------------
-- 관리자 감사 로그
-- ---------------------------------------------------------------------------
create table if not exists public.admin_action_logs (
  id uuid primary key default extensions.gen_random_uuid(),
  actor_user_id uuid not null references public.member(user_id),
  action_type text not null,
  target_user_id uuid references public.member(user_id),
  target_room_id uuid references public.chat_rooms(id),
  transaction_id uuid references public.transactions(id),
  reason text,
  idempotency_key text,
  before_data jsonb not null default '{}'::jsonb,
  after_data jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists admin_action_logs_created_idx
  on public.admin_action_logs(created_at desc);
create index if not exists admin_action_logs_actor_created_idx
  on public.admin_action_logs(actor_user_id, created_at desc);
create index if not exists admin_action_logs_target_user_created_idx
  on public.admin_action_logs(target_user_id, created_at desc)
  where target_user_id is not null;
create index if not exists admin_action_logs_target_room_created_idx
  on public.admin_action_logs(target_room_id, created_at desc)
  where target_room_id is not null;
create index if not exists admin_action_logs_action_created_idx
  on public.admin_action_logs(action_type, created_at desc);
create unique index if not exists admin_action_logs_idempotency_uidx
  on public.admin_action_logs(idempotency_key)
  where idempotency_key is not null;

alter table public.admin_action_logs enable row level security;
revoke all on public.admin_action_logs from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 관리자 권한 및 payload helper
-- ---------------------------------------------------------------------------
create or replace function private.require_admin()
returns public.member
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_member public.member%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  select *
    into v_member
    from public.member m
   where m.user_id = v_user_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'MEMBER_NOT_FOUND';
  end if;

  if v_member.status <> 'active'
     or coalesce(v_member.is_del, false)
     or v_member.role not in ('admin', 'super_admin') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_REQUIRED';
  end if;

  return v_member;
end;
$$;

create or replace function private.require_super_admin()
returns public.member
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_member public.member%rowtype;
begin
  v_member := private.require_admin();
  if v_member.role <> 'super_admin' then
    raise exception using errcode = 'P0001', message = 'SUPER_ADMIN_PERMISSION_REQUIRED';
  end if;
  return v_member;
end;
$$;

create or replace function private.admin_transaction_payload(p_transaction_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select jsonb_build_object(
      'id', t.id,
      'senderUserId', t.sender_user_id,
      'receiverUserId', t.receiver_user_id,
      'senderAddress', t.sender_address,
      'receiverAddress', t.receiver_address,
      'assetCode', t.asset_code,
      'amount', t.amount,
      'feeAmount', t.fee_amount,
      'transactionType', t.transaction_type,
      'status', t.status,
      'description', t.description,
      'txHash', t.tx_hash,
      'referenceType', t.reference_type,
      'referenceId', t.reference_id,
      'idempotencyKey', t.idempotency_key,
      'metadata', t.metadata,
      'scheduledAt', t.scheduled_at,
      'processedAt', t.processed_at,
      'createdAt', t.created_at,
      'updatedAt', t.updated_at,
      'sender', case when sm.user_id is null then null else jsonb_build_object(
        'userId', sm.user_id, 'memberId', sm.mb_id, 'name', sm.mb_name, 'email', sm.mb_email
      ) end,
      'receiver', case when rm.user_id is null then null else jsonb_build_object(
        'userId', rm.user_id, 'memberId', rm.mb_id, 'name', rm.mb_name, 'email', rm.mb_email
      ) end,
      'adminActor', case when am.user_id is null then null else jsonb_build_object(
        'userId', am.user_id, 'memberId', am.mb_id, 'name', am.mb_name, 'role', am.role
      ) end
    )
      from public.transactions t
      left join public.member sm on sm.user_id = t.sender_user_id
      left join public.member rm on rm.user_id = t.receiver_user_id
      left join public.member am on am.user_id::text = t.metadata ->> 'admin_actor_user_id'
     where t.id = p_transaction_id
  ), 'null'::jsonb);
$$;

create or replace function private.admin_chat_message_payload(p_message_id bigint)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select jsonb_build_object(
      'id', cm.id,
      'roomId', cm.room_id,
      'senderId', cm.sender_id,
      'senderName', coalesce(m.mb_name, m.mb_id, 'STO 회원'),
      'senderMemberId', m.mb_id,
      'senderAvatar', coalesce(m.mb_profile, ''),
      'senderRole', coalesce(m.role, 'user'),
      'clientMessageId', cm.client_message_id,
      'content', case when cm.deleted_at is null then cm.content else '' end,
      'deletedAt', cm.deleted_at,
      'createdAt', cm.created_at
    )
      from public.chat_messages cm
      left join public.member m on m.user_id = cm.sender_id
     where cm.id = p_message_id
  ), 'null'::jsonb);
$$;

create or replace function private.admin_chat_room_payload(p_room_id uuid, p_admin_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_room public.chat_rooms%rowtype;
  v_members jsonb;
  v_member_count integer;
  v_current_admin_active boolean;
  v_created_by jsonb;
begin
  select * into v_room
    from public.chat_rooms cr
   where cr.id = p_room_id
     and cr.room_type = 'group';

  if not found then
    return null;
  end if;

  select count(*)::integer,
         coalesce(jsonb_agg(jsonb_build_object(
           'userId', m.user_id,
           'memberNo', m.mb_no,
           'memberId', m.mb_id,
           'name', m.mb_name,
           'email', m.mb_email,
           'phone', m.mb_hp,
           'avatarUrl', m.mb_profile,
           'memberRole', m.role,
           'memberStatus', m.status,
           'chatRole', cm.role,
           'joinedAt', cm.joined_at,
           'muted', cm.muted,
           'unreadCount', cm.unread_count
         ) order by case when cm.role = 'admin' then 0 else 1 end, m.mb_name, m.mb_id), '[]'::jsonb)
    into v_member_count, v_members
    from public.chat_members cm
    join public.member m on m.user_id = cm.user_id
   where cm.room_id = p_room_id
     and cm.left_at is null;

  select exists (
    select 1
      from public.chat_members cm
     where cm.room_id = p_room_id
       and cm.user_id = p_admin_user_id
       and cm.left_at is null
  ) into v_current_admin_active;

  select case when m.user_id is null then null else jsonb_build_object(
    'userId', m.user_id, 'memberId', m.mb_id, 'name', m.mb_name, 'role', m.role
  ) end
    into v_created_by
    from public.chat_rooms cr
    left join public.member m on m.user_id = cr.created_by
   where cr.id = p_room_id;

  return jsonb_build_object(
    'id', v_room.id,
    'roomId', v_room.id,
    'roomType', v_room.room_type,
    'title', coalesce(nullif(trim(v_room.title), ''), '그룹 채팅'),
    'memberCount', coalesce(v_member_count, 0),
    'maxMemberCount', 100,
    'members', coalesce(v_members, '[]'::jsonb),
    'currentAdminActive', coalesce(v_current_admin_active, false),
    'lastMessageId', v_room.last_message_id,
    'lastMessagePreview', coalesce(v_room.last_message_preview, ''),
    'lastMessageAt', v_room.last_message_at,
    'createdBy', v_created_by,
    'createdAt', v_room.created_at,
    'updatedAt', v_room.updated_at
  );
end;
$$;

revoke all on function private.require_admin() from public, anon, authenticated;
revoke all on function private.require_super_admin() from public, anon, authenticated;
revoke all on function private.admin_transaction_payload(uuid) from public, anon, authenticated;
revoke all on function private.admin_chat_message_payload(bigint) from public, anon, authenticated;
revoke all on function private.admin_chat_room_payload(uuid, uuid) from public, anon, authenticated;

-- 모든 쓰기 경로에서 그룹 채팅방 활성 인원을 100명으로 제한한다.
create or replace function private.enforce_chat_room_member_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_active_count integer;
begin
  if new.left_at is not null then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.left_at is null then
    return new;
  end if;

  perform 1 from public.chat_rooms cr where cr.id = new.room_id for update;
  select count(*)::integer
    into v_active_count
    from public.chat_members cm
   where cm.room_id = new.room_id
     and cm.left_at is null;
  if v_active_count >= 100 then
    raise exception using errcode = 'P0001', message = 'CHAT_ROOM_MEMBER_LIMIT_EXCEEDED';
  end if;
  return new;
end;
$$;

revoke all on function private.enforce_chat_room_member_limit() from public, anon, authenticated;
drop trigger if exists chat_members_enforce_max_100 on public.chat_members;
create trigger chat_members_enforce_max_100
before insert or update of left_at on public.chat_members
for each row execute function private.enforce_chat_room_member_limit();

-- ---------------------------------------------------------------------------
-- 관리자 세션
-- ---------------------------------------------------------------------------
create or replace function public.rpc_admin_get_session()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
begin
  v_admin := private.require_admin();
  return jsonb_build_object(
    'userId', v_admin.user_id,
    'memberNo', v_admin.mb_no,
    'memberId', v_admin.mb_id,
    'name', v_admin.mb_name,
    'email', v_admin.mb_email,
    'profile', v_admin.mb_profile,
    'role', v_admin.role,
    'permissions', jsonb_build_object(
      'memberRead', true,
      'assetDeposit', true,
      'assetWithdrawal', true,
      'assetAirdrop', true,
      'chatManage', true,
      'adminLogRead', true
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 회원 조회
-- ---------------------------------------------------------------------------
create or replace function public.rpc_admin_list_members(
  p_search text default null,
  p_status text default null,
  p_role text default null,
  p_signup_method text default null,
  p_reg_channel text default null,
  p_is_deleted boolean default null,
  p_page integer default 1,
  p_page_size integer default 30,
  p_sort_column text default 'created_at',
  p_sort_direction text default 'desc'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := least(greatest(coalesce(p_page_size, 30), 1), 100);
  v_offset integer;
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_sort_column text := lower(coalesce(p_sort_column, 'created_at'));
  v_sort_direction text := lower(coalesce(p_sort_direction, 'desc'));
  v_total bigint;
  v_items jsonb;
begin
  v_admin := private.require_admin();
  v_offset := (v_page - 1) * v_page_size;

  if v_sort_column not in ('mb_no', 'mb_id', 'mb_name', 'mb_email', 'status', 'role', 'last_login_at', 'created_at', 'updated_at', 'internal_stoc_balance') then
    v_sort_column := 'created_at';
  end if;
  if v_sort_direction not in ('asc', 'desc') then
    v_sort_direction := 'desc';
  end if;

  with filtered as (
    select m.*,
           coalesce(wa.available_balance, 0::numeric) as internal_stoc_balance
      from public.member m
      left join public.wallet_accounts wa
        on wa.user_id = m.user_id
       and wa.asset_code = 'STOC_INT'
       and wa.account_type = 'internal'
     where (v_search is null or
            m.mb_id ilike '%' || v_search || '%' or
            m.mb_name ilike '%' || v_search || '%' or
            m.mb_email ilike '%' || v_search || '%' or
            coalesce(m.mb_hp, '') ilike '%' || v_search || '%' or
            m.user_id::text ilike '%' || v_search || '%' or
            m.mb_no::text ilike '%' || v_search || '%' or
            m.referral_code ilike '%' || v_search || '%')
       and (p_status is null or p_status = '' or m.status = p_status)
       and (p_role is null or p_role = '' or m.role = p_role)
       and (p_signup_method is null or p_signup_method = '' or m.signup_method = p_signup_method)
       and (p_reg_channel is null or p_reg_channel = '' or m.reg_channel = p_reg_channel)
       and (p_is_deleted is null or coalesce(m.is_del, false) = p_is_deleted)
  )
  select count(*) into v_total from filtered;

  with filtered as (
    select m.*,
           coalesce(wa.available_balance, 0::numeric) as internal_stoc_balance
      from public.member m
      left join public.wallet_accounts wa
        on wa.user_id = m.user_id
       and wa.asset_code = 'STOC_INT'
       and wa.account_type = 'internal'
     where (v_search is null or
            m.mb_id ilike '%' || v_search || '%' or
            m.mb_name ilike '%' || v_search || '%' or
            m.mb_email ilike '%' || v_search || '%' or
            coalesce(m.mb_hp, '') ilike '%' || v_search || '%' or
            m.user_id::text ilike '%' || v_search || '%' or
            m.mb_no::text ilike '%' || v_search || '%' or
            m.referral_code ilike '%' || v_search || '%')
       and (p_status is null or p_status = '' or m.status = p_status)
       and (p_role is null or p_role = '' or m.role = p_role)
       and (p_signup_method is null or p_signup_method = '' or m.signup_method = p_signup_method)
       and (p_reg_channel is null or p_reg_channel = '' or m.reg_channel = p_reg_channel)
       and (p_is_deleted is null or coalesce(m.is_del, false) = p_is_deleted)
  ), page_data as (
    select *
      from filtered f
     order by
       case when v_sort_column = 'mb_no' and v_sort_direction = 'asc' then f.mb_no end asc,
       case when v_sort_column = 'mb_no' and v_sort_direction = 'desc' then f.mb_no end desc,
       case when v_sort_column = 'mb_id' and v_sort_direction = 'asc' then f.mb_id end asc,
       case when v_sort_column = 'mb_id' and v_sort_direction = 'desc' then f.mb_id end desc,
       case when v_sort_column = 'mb_name' and v_sort_direction = 'asc' then f.mb_name end asc,
       case when v_sort_column = 'mb_name' and v_sort_direction = 'desc' then f.mb_name end desc,
       case when v_sort_column = 'mb_email' and v_sort_direction = 'asc' then f.mb_email end asc,
       case when v_sort_column = 'mb_email' and v_sort_direction = 'desc' then f.mb_email end desc,
       case when v_sort_column = 'status' and v_sort_direction = 'asc' then f.status end asc,
       case when v_sort_column = 'status' and v_sort_direction = 'desc' then f.status end desc,
       case when v_sort_column = 'role' and v_sort_direction = 'asc' then f.role end asc,
       case when v_sort_column = 'role' and v_sort_direction = 'desc' then f.role end desc,
       case when v_sort_column = 'last_login_at' and v_sort_direction = 'asc' then f.last_login_at end asc nulls last,
       case when v_sort_column = 'last_login_at' and v_sort_direction = 'desc' then f.last_login_at end desc nulls last,
       case when v_sort_column = 'created_at' and v_sort_direction = 'asc' then f.created_at end asc,
       case when v_sort_column = 'created_at' and v_sort_direction = 'desc' then f.created_at end desc,
       case when v_sort_column = 'updated_at' and v_sort_direction = 'asc' then f.updated_at end asc,
       case when v_sort_column = 'updated_at' and v_sort_direction = 'desc' then f.updated_at end desc,
       case when v_sort_column = 'internal_stoc_balance' and v_sort_direction = 'asc' then f.internal_stoc_balance end asc,
       case when v_sort_column = 'internal_stoc_balance' and v_sort_direction = 'desc' then f.internal_stoc_balance end desc,
       f.user_id
     offset v_offset
     limit v_page_size
  )
  select coalesce(jsonb_agg(to_jsonb(page_data)), '[]'::jsonb)
    into v_items
    from page_data;

  return jsonb_build_object(
    'items', coalesce(v_items, '[]'::jsonb),
    'page', v_page,
    'pageSize', v_page_size,
    'totalCount', coalesce(v_total, 0)
  );
end;
$$;

create or replace function public.rpc_admin_search_members(
  p_search text default null,
  p_limit integer default 30,
  p_exclude_room_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_limit integer := least(greatest(coalesce(p_limit, 30), 1), 100);
  v_result jsonb;
begin
  v_admin := private.require_admin();

  select coalesce(jsonb_agg(jsonb_build_object(
    'userId', m.user_id,
    'memberNo', m.mb_no,
    'memberId', m.mb_id,
    'name', m.mb_name,
    'email', m.mb_email,
    'phone', m.mb_hp,
    'profile', m.mb_profile,
    'role', m.role,
    'status', m.status
  ) order by m.mb_name, m.mb_id), '[]'::jsonb)
    into v_result
    from (
      select m.*
        from public.member m
       where m.status = 'active'
         and not coalesce(m.is_del, false)
         and m.user_id <> v_admin.user_id
         and (v_search is null or
              m.mb_id ilike '%' || v_search || '%' or
              m.mb_name ilike '%' || v_search || '%' or
              m.mb_email ilike '%' || v_search || '%' or
              coalesce(m.mb_hp, '') ilike '%' || v_search || '%' or
              m.user_id::text ilike '%' || v_search || '%')
         and (p_exclude_room_id is null or not exists (
           select 1 from public.chat_members cm
            where cm.room_id = p_exclude_room_id
              and cm.user_id = m.user_id
              and cm.left_at is null
         ))
       order by m.mb_name, m.mb_id
       limit v_limit
    ) m;

  return coalesce(v_result, '[]'::jsonb);
end;
$$;

create or replace function public.rpc_admin_get_member(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_member public.member%rowtype;
  v_internal_balance numeric;
  v_wallet_accounts jsonb;
  v_wallet_addresses jsonb;
  v_devices jsonb;
  v_consents jsonb;
  v_deletion_request jsonb;
  v_marketing_attribution jsonb;
  v_recent_transactions jsonb;
  v_chat_rooms jsonb;
begin
  v_admin := private.require_admin();

  select * into v_member
    from public.member m
   where m.user_id = p_user_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'MEMBER_NOT_FOUND';
  end if;

  select coalesce(wa.available_balance, 0::numeric)
    into v_internal_balance
    from public.wallet_accounts wa
   where wa.user_id = p_user_id
     and wa.asset_code = 'STOC_INT'
     and wa.account_type = 'internal';
  v_internal_balance := coalesce(v_internal_balance, 0::numeric);

  select coalesce(jsonb_agg(to_jsonb(wa) order by wa.asset_code, wa.account_type), '[]'::jsonb)
    into v_wallet_accounts
    from public.wallet_accounts wa
   where wa.user_id = p_user_id;

  select coalesce(jsonb_agg(to_jsonb(wad) order by wad.chain, wad.asset_code), '[]'::jsonb)
    into v_wallet_addresses
    from public.wallet_addresses wad
   where wad.user_id = p_user_id;

  select coalesce(jsonb_agg(to_jsonb(md) - 'push_token' order by md.last_seen_at desc), '[]'::jsonb)
    into v_devices
    from public.member_devices md
   where md.user_id = p_user_id;

  select coalesce(jsonb_agg(to_jsonb(mc) order by mc.created_at desc), '[]'::jsonb)
    into v_consents
    from public.member_consents mc
   where mc.user_id = p_user_id;

  select to_jsonb(mdr)
    into v_deletion_request
    from public.member_deletion_requests mdr
   where mdr.user_id = p_user_id;

  select to_jsonb(mma)
    into v_marketing_attribution
    from public.member_marketing_attribution mma
   where mma.user_id = p_user_id;

  select coalesce(jsonb_agg(private.admin_transaction_payload(q.id) order by q.created_at desc), '[]'::jsonb)
    into v_recent_transactions
    from (
      select t.id, t.created_at
        from public.transactions t
       where t.sender_user_id = p_user_id or t.receiver_user_id = p_user_id
       order by t.created_at desc, t.id desc
       limit 100
    ) q;

  select coalesce(jsonb_agg(jsonb_build_object(
    'roomId', cr.id,
    'title', coalesce(nullif(trim(cr.title), ''), '그룹 채팅'),
    'role', cm.role,
    'joinedAt', cm.joined_at,
    'leftAt', cm.left_at,
    'lastMessageAt', cr.last_message_at
  ) order by cr.last_message_at desc nulls last, cr.created_at desc), '[]'::jsonb)
    into v_chat_rooms
    from public.chat_members cm
    join public.chat_rooms cr on cr.id = cm.room_id
   where cm.user_id = p_user_id
     and cr.room_type = 'group';

  return jsonb_build_object(
    'member', to_jsonb(v_member),
    'internalStocBalance', v_internal_balance,
    'walletAccounts', coalesce(v_wallet_accounts, '[]'::jsonb),
    'walletAddresses', coalesce(v_wallet_addresses, '[]'::jsonb),
    'devices', coalesce(v_devices, '[]'::jsonb),
    'consents', coalesce(v_consents, '[]'::jsonb),
    'deletionRequest', v_deletion_request,
    'marketingAttribution', v_marketing_attribution,
    'recentTransactions', coalesce(v_recent_transactions, '[]'::jsonb),
    'chatRooms', coalesce(v_chat_rooms, '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 자산 조정 및 거래 조회
-- ---------------------------------------------------------------------------
create or replace function public.rpc_admin_adjust_stoc(
  p_target_user_id uuid,
  p_action text,
  p_amount numeric,
  p_reason text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_target public.member%rowtype;
  v_action text := lower(trim(coalesce(p_action, '')));
  v_reason text := trim(coalesce(p_reason, ''));
  v_key text := trim(coalesce(p_idempotency_key, ''));
  v_wallet public.wallet_accounts%rowtype;
  v_existing public.transactions%rowtype;
  v_transaction_id uuid;
  v_balance_before numeric;
  v_balance_after numeric;
  v_log_id uuid;
begin
  v_admin := private.require_admin();

  if v_action not in ('deposit', 'withdrawal', 'airdrop') then
    raise exception using errcode = 'P0001', message = 'INVALID_ADMIN_TRANSACTION_TYPE';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception using errcode = 'P0001', message = 'INVALID_AMOUNT';
  end if;
  if char_length(v_reason) < 2 then
    raise exception using errcode = 'P0001', message = 'ADMIN_REASON_REQUIRED';
  end if;
  if v_key = '' then
    raise exception using errcode = 'P0001', message = 'IDEMPOTENCY_KEY_REQUIRED';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_key, 0));

  select * into v_existing
    from public.transactions t
   where t.idempotency_key = v_key;

  if found then
    if v_existing.transaction_type <> v_action
       or v_existing.amount <> p_amount
       or (v_action = 'withdrawal' and v_existing.sender_user_id is distinct from p_target_user_id)
       or (v_action in ('deposit', 'airdrop') and v_existing.receiver_user_id is distinct from p_target_user_id) then
      raise exception using errcode = 'P0001', message = 'IDEMPOTENCY_KEY_CONFLICT';
    end if;

    return jsonb_build_object(
      'alreadyProcessed', true,
      'action', v_action,
      'amount', p_amount,
      'balanceBefore', coalesce((v_existing.metadata ->> 'balance_before')::numeric, 0),
      'balanceAfter', coalesce((v_existing.metadata ->> 'balance_after')::numeric, 0),
      'transaction', private.admin_transaction_payload(v_existing.id)
    );
  end if;

  select * into v_target
    from public.member m
   where m.user_id = p_target_user_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'MEMBER_NOT_FOUND';
  end if;
  if v_target.status = 'deleted' or coalesce(v_target.is_del, false) then
    raise exception using errcode = 'P0001', message = 'MEMBER_DELETED';
  end if;

  insert into public.wallet_accounts(user_id, asset_code, account_type, available_balance, locked_balance)
  values (p_target_user_id, 'STOC_INT', 'internal', 0, 0)
  on conflict (user_id, asset_code, account_type) do nothing;

  select * into v_wallet
    from public.wallet_accounts wa
   where wa.user_id = p_target_user_id
     and wa.asset_code = 'STOC_INT'
     and wa.account_type = 'internal'
   for update;

  v_balance_before := v_wallet.available_balance;
  if v_action = 'withdrawal' and v_balance_before < p_amount then
    raise exception using errcode = 'P0001', message = 'INSUFFICIENT_BALANCE';
  end if;

  update public.wallet_accounts wa
     set available_balance = case
           when v_action = 'withdrawal' then wa.available_balance - p_amount
           else wa.available_balance + p_amount
         end,
         updated_at = now()
   where wa.id = v_wallet.id
  returning wa.available_balance into v_balance_after;

  insert into public.transactions(
    sender_user_id,
    receiver_user_id,
    asset_code,
    amount,
    fee_amount,
    transaction_type,
    status,
    description,
    reference_type,
    idempotency_key,
    metadata,
    processed_at
  ) values (
    case when v_action = 'withdrawal' then p_target_user_id else null end,
    case when v_action in ('deposit', 'airdrop') then p_target_user_id else null end,
    'STOC_INT',
    p_amount,
    0,
    v_action,
    'completed',
    v_reason,
    'admin_adjustment',
    v_key,
    jsonb_build_object(
      'source', 'sto_network_admin',
      'admin_actor_user_id', v_admin.user_id,
      'admin_actor_member_id', v_admin.mb_id,
      'target_user_id', p_target_user_id,
      'target_member_id', v_target.mb_id,
      'requested_action', v_action,
      'reason', v_reason,
      'balance_before', v_balance_before,
      'balance_after', v_balance_after
    ),
    now()
  ) returning id into v_transaction_id;

  insert into public.admin_action_logs(
    actor_user_id, action_type, target_user_id, transaction_id,
    reason, idempotency_key, before_data, after_data, metadata
  ) values (
    v_admin.user_id,
    'wallet.' || v_action,
    p_target_user_id,
    v_transaction_id,
    v_reason,
    v_key,
    jsonb_build_object('assetCode', 'STOC_INT', 'availableBalance', v_balance_before),
    jsonb_build_object('assetCode', 'STOC_INT', 'availableBalance', v_balance_after),
    jsonb_build_object('amount', p_amount, 'targetMemberId', v_target.mb_id)
  ) returning id into v_log_id;

  return jsonb_build_object(
    'alreadyProcessed', false,
    'action', v_action,
    'amount', p_amount,
    'balanceBefore', v_balance_before,
    'balanceAfter', v_balance_after,
    'adminLogId', v_log_id,
    'transaction', private.admin_transaction_payload(v_transaction_id)
  );
end;
$$;

create or replace function public.rpc_admin_list_transactions(
  p_search text default null,
  p_transaction_type text default null,
  p_status text default null,
  p_asset_code text default null,
  p_user_id uuid default null,
  p_from_at timestamptz default null,
  p_to_at timestamptz default null,
  p_page integer default 1,
  p_page_size integer default 30
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := least(greatest(coalesce(p_page_size, 30), 1), 100);
  v_offset integer;
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_total bigint;
  v_items jsonb;
begin
  v_admin := private.require_admin();
  v_offset := (v_page - 1) * v_page_size;

  with filtered as (
    select t.id, t.created_at
      from public.transactions t
      left join public.member sm on sm.user_id = t.sender_user_id
      left join public.member rm on rm.user_id = t.receiver_user_id
     where (v_search is null or
            t.id::text ilike '%' || v_search || '%' or
            coalesce(t.description, '') ilike '%' || v_search || '%' or
            coalesce(t.idempotency_key, '') ilike '%' || v_search || '%' or
            coalesce(sm.mb_id, '') ilike '%' || v_search || '%' or
            coalesce(sm.mb_name, '') ilike '%' || v_search || '%' or
            coalesce(sm.mb_email, '') ilike '%' || v_search || '%' or
            coalesce(rm.mb_id, '') ilike '%' || v_search || '%' or
            coalesce(rm.mb_name, '') ilike '%' || v_search || '%' or
            coalesce(rm.mb_email, '') ilike '%' || v_search || '%')
       and (p_transaction_type is null or p_transaction_type = '' or t.transaction_type = p_transaction_type)
       and (p_status is null or p_status = '' or t.status = p_status)
       and (p_asset_code is null or p_asset_code = '' or t.asset_code = upper(trim(p_asset_code)))
       and (p_user_id is null or t.sender_user_id = p_user_id or t.receiver_user_id = p_user_id)
       and (p_from_at is null or t.created_at >= p_from_at)
       and (p_to_at is null or t.created_at <= p_to_at)
  )
  select count(*) into v_total from filtered;

  with filtered as (
    select t.id, t.created_at
      from public.transactions t
      left join public.member sm on sm.user_id = t.sender_user_id
      left join public.member rm on rm.user_id = t.receiver_user_id
     where (v_search is null or
            t.id::text ilike '%' || v_search || '%' or
            coalesce(t.description, '') ilike '%' || v_search || '%' or
            coalesce(t.idempotency_key, '') ilike '%' || v_search || '%' or
            coalesce(sm.mb_id, '') ilike '%' || v_search || '%' or
            coalesce(sm.mb_name, '') ilike '%' || v_search || '%' or
            coalesce(sm.mb_email, '') ilike '%' || v_search || '%' or
            coalesce(rm.mb_id, '') ilike '%' || v_search || '%' or
            coalesce(rm.mb_name, '') ilike '%' || v_search || '%' or
            coalesce(rm.mb_email, '') ilike '%' || v_search || '%')
       and (p_transaction_type is null or p_transaction_type = '' or t.transaction_type = p_transaction_type)
       and (p_status is null or p_status = '' or t.status = p_status)
       and (p_asset_code is null or p_asset_code = '' or t.asset_code = upper(trim(p_asset_code)))
       and (p_user_id is null or t.sender_user_id = p_user_id or t.receiver_user_id = p_user_id)
       and (p_from_at is null or t.created_at >= p_from_at)
       and (p_to_at is null or t.created_at <= p_to_at)
     order by t.created_at desc, t.id desc
     offset v_offset
     limit v_page_size
  )
  select coalesce(jsonb_agg(private.admin_transaction_payload(filtered.id) order by filtered.created_at desc), '[]'::jsonb)
    into v_items
    from filtered;

  return jsonb_build_object(
    'items', coalesce(v_items, '[]'::jsonb),
    'page', v_page,
    'pageSize', v_page_size,
    'totalCount', coalesce(v_total, 0)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 그룹 채팅 관리 (최대 100명)
-- ---------------------------------------------------------------------------
create or replace function public.rpc_admin_list_chat_rooms(
  p_search text default null,
  p_page integer default 1,
  p_page_size integer default 30
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := least(greatest(coalesce(p_page_size, 30), 1), 100);
  v_offset integer;
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_total bigint;
  v_items jsonb;
begin
  v_admin := private.require_admin();
  v_offset := (v_page - 1) * v_page_size;

  select count(*) into v_total
    from public.chat_rooms cr
   where cr.room_type = 'group'
     and (v_search is null or cr.id::text ilike '%' || v_search || '%'
          or coalesce(cr.title, '') ilike '%' || v_search || '%'
          or coalesce(cr.last_message_preview, '') ilike '%' || v_search || '%');

  with page_data as (
    select cr.id, cr.last_message_at, cr.created_at
      from public.chat_rooms cr
     where cr.room_type = 'group'
       and (v_search is null or cr.id::text ilike '%' || v_search || '%'
            or coalesce(cr.title, '') ilike '%' || v_search || '%'
            or coalesce(cr.last_message_preview, '') ilike '%' || v_search || '%')
     order by cr.last_message_at desc nulls last, cr.created_at desc
     offset v_offset
     limit v_page_size
  )
  select coalesce(jsonb_agg(private.admin_chat_room_payload(page_data.id, v_admin.user_id)
           order by page_data.last_message_at desc nulls last, page_data.created_at desc), '[]'::jsonb)
    into v_items
    from page_data;

  return jsonb_build_object('items', coalesce(v_items, '[]'::jsonb), 'page', v_page, 'pageSize', v_page_size, 'totalCount', coalesce(v_total, 0));
end;
$$;

create or replace function public.rpc_admin_get_chat_room(p_room_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_result jsonb;
begin
  v_admin := private.require_admin();
  v_result := private.admin_chat_room_payload(p_room_id, v_admin.user_id);
  if v_result is null or v_result = 'null'::jsonb then
    raise exception using errcode = 'P0001', message = 'CHAT_ROOM_NOT_FOUND';
  end if;
  return v_result;
end;
$$;

create or replace function public.rpc_admin_create_chat_room(p_title text, p_member_ids uuid[])
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_title text := trim(coalesce(p_title, ''));
  v_member_ids uuid[];
  v_member_count integer;
  v_valid_count integer;
  v_room_id uuid;
begin
  v_admin := private.require_admin();
  if char_length(v_title) < 2 then
    raise exception using errcode = 'P0001', message = 'CHAT_ROOM_TITLE_REQUIRED';
  end if;
  if char_length(v_title) > 80 then
    v_title := left(v_title, 80);
  end if;

  select coalesce(array_agg(x.user_id order by x.user_id), array[]::uuid[])
    into v_member_ids
    from (
      select distinct u.user_id
        from unnest(coalesce(p_member_ids, array[]::uuid[])) u(user_id)
       where u.user_id is not null
         and u.user_id <> v_admin.user_id
    ) x;

  v_member_count := coalesce(array_length(v_member_ids, 1), 0) + 1;
  if v_member_count < 2 then
    raise exception using errcode = 'P0001', message = 'CHAT_ROOM_MEMBER_COUNT_INVALID';
  end if;
  if v_member_count > 100 then
    raise exception using errcode = 'P0001', message = 'CHAT_ROOM_MEMBER_LIMIT_EXCEEDED';
  end if;

  select count(*)::integer into v_valid_count
    from public.member m
   where m.user_id = any(v_member_ids)
     and m.status = 'active'
     and not coalesce(m.is_del, false);
  if v_valid_count <> coalesce(array_length(v_member_ids, 1), 0) then
    raise exception using errcode = 'P0001', message = 'CHAT_MEMBER_NOT_FOUND';
  end if;

  insert into public.chat_rooms(room_type, title, direct_key, created_by)
  values ('group', v_title, null, v_admin.user_id)
  returning id into v_room_id;

  insert into public.chat_members(room_id, user_id, role, unread_count, joined_at, left_at)
  values (v_room_id, v_admin.user_id, 'admin', 0, now(), null);

  insert into public.chat_members(room_id, user_id, role, unread_count, joined_at, left_at)
  select v_room_id, m.user_id,
         case when m.role in ('admin', 'super_admin') then 'admin' else 'member' end,
         0, now(), null
    from public.member m
   where m.user_id = any(v_member_ids);

  insert into public.admin_action_logs(actor_user_id, action_type, target_room_id, before_data, after_data, metadata)
  values (v_admin.user_id, 'chat.room_create', v_room_id, '{}'::jsonb,
          private.admin_chat_room_payload(v_room_id, v_admin.user_id),
          jsonb_build_object('memberIds', to_jsonb(v_member_ids)));

  return private.admin_chat_room_payload(v_room_id, v_admin.user_id);
end;
$$;

create or replace function public.rpc_admin_update_chat_room(p_room_id uuid, p_title text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_title text := trim(coalesce(p_title, ''));
  v_before jsonb;
  v_after jsonb;
begin
  v_admin := private.require_admin();
  if char_length(v_title) < 2 then
    raise exception using errcode = 'P0001', message = 'CHAT_ROOM_TITLE_REQUIRED';
  end if;
  v_title := left(v_title, 80);
  v_before := private.admin_chat_room_payload(p_room_id, v_admin.user_id);
  if v_before is null or v_before = 'null'::jsonb then
    raise exception using errcode = 'P0001', message = 'CHAT_ROOM_NOT_FOUND';
  end if;

  update public.chat_rooms cr
     set title = v_title,
         updated_at = now()
   where cr.id = p_room_id
     and cr.room_type = 'group';

  v_after := private.admin_chat_room_payload(p_room_id, v_admin.user_id);
  insert into public.admin_action_logs(actor_user_id, action_type, target_room_id, before_data, after_data)
  values (v_admin.user_id, 'chat.room_update', p_room_id, v_before, v_after);
  return v_after;
end;
$$;

create or replace function public.rpc_admin_add_chat_members(p_room_id uuid, p_member_ids uuid[])
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_room public.chat_rooms%rowtype;
  v_member_ids uuid[];
  v_valid_count integer;
  v_current_count integer;
  v_new_count integer;
  v_before jsonb;
  v_after jsonb;
begin
  v_admin := private.require_admin();
  select * into v_room
    from public.chat_rooms cr
   where cr.id = p_room_id and cr.room_type = 'group'
   for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'CHAT_ROOM_NOT_FOUND';
  end if;

  select coalesce(array_agg(x.user_id order by x.user_id), array[]::uuid[])
    into v_member_ids
    from (select distinct u.user_id from unnest(coalesce(p_member_ids, array[]::uuid[])) u(user_id) where u.user_id is not null) x;
  if coalesce(array_length(v_member_ids, 1), 0) = 0 then
    return private.admin_chat_room_payload(p_room_id, v_admin.user_id);
  end if;

  select count(*)::integer into v_valid_count
    from public.member m
   where m.user_id = any(v_member_ids)
     and m.status = 'active'
     and not coalesce(m.is_del, false);
  if v_valid_count <> array_length(v_member_ids, 1) then
    raise exception using errcode = 'P0001', message = 'CHAT_MEMBER_NOT_FOUND';
  end if;

  select count(*)::integer into v_current_count
    from public.chat_members cm
   where cm.room_id = p_room_id and cm.left_at is null;
  select count(*)::integer into v_new_count
    from unnest(v_member_ids) u(user_id)
   where not exists (
     select 1 from public.chat_members cm
      where cm.room_id = p_room_id and cm.user_id = u.user_id and cm.left_at is null
   );
  if v_current_count + v_new_count > 100 then
    raise exception using errcode = 'P0001', message = 'CHAT_ROOM_MEMBER_LIMIT_EXCEEDED';
  end if;

  v_before := private.admin_chat_room_payload(p_room_id, v_admin.user_id);

  insert into public.chat_members(room_id, user_id, role, last_read_message_id, unread_count, joined_at, left_at)
  select p_room_id, m.user_id,
         case when m.role in ('admin', 'super_admin') then 'admin' else 'member' end,
         v_room.last_message_id, 0, now(), null
    from public.member m
   where m.user_id = any(v_member_ids)
     and not exists (
       select 1 from public.chat_members active_cm
        where active_cm.room_id = p_room_id
          and active_cm.user_id = m.user_id
          and active_cm.left_at is null
     )
  on conflict (room_id, user_id) do update set
    role = case when public.chat_members.role = 'admin' then 'admin' else excluded.role end,
    last_read_message_id = excluded.last_read_message_id,
    unread_count = 0,
    joined_at = now(),
    left_at = null;

  v_after := private.admin_chat_room_payload(p_room_id, v_admin.user_id);
  insert into public.admin_action_logs(actor_user_id, action_type, target_room_id, before_data, after_data, metadata)
  values (v_admin.user_id, 'chat.member_add', p_room_id, v_before, v_after,
          jsonb_build_object('memberIds', to_jsonb(v_member_ids), 'addedOrReactivatedCount', v_new_count));
  return v_after;
end;
$$;

create or replace function public.rpc_admin_remove_chat_members(
  p_room_id uuid,
  p_member_ids uuid[],
  p_reason text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_room public.chat_rooms%rowtype;
  v_member_ids uuid[];
  v_active_remove_count integer;
  v_current_count integer;
  v_remaining_admin_count integer;
  v_before jsonb;
  v_after jsonb;
begin
  v_admin := private.require_admin();
  select * into v_room
    from public.chat_rooms cr
   where cr.id = p_room_id and cr.room_type = 'group'
   for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'CHAT_ROOM_NOT_FOUND';
  end if;

  select coalesce(array_agg(x.user_id order by x.user_id), array[]::uuid[])
    into v_member_ids
    from (select distinct u.user_id from unnest(coalesce(p_member_ids, array[]::uuid[])) u(user_id) where u.user_id is not null) x;
  if coalesce(array_length(v_member_ids, 1), 0) = 0 then
    return private.admin_chat_room_payload(p_room_id, v_admin.user_id);
  end if;

  select count(*)::integer into v_current_count
    from public.chat_members cm
   where cm.room_id = p_room_id and cm.left_at is null;
  select count(*)::integer into v_active_remove_count
    from public.chat_members cm
   where cm.room_id = p_room_id and cm.left_at is null and cm.user_id = any(v_member_ids);
  if v_current_count - v_active_remove_count < 1 then
    raise exception using errcode = 'P0001', message = 'CHAT_ROOM_MEMBER_COUNT_INVALID';
  end if;

  select count(*)::integer into v_remaining_admin_count
    from public.chat_members cm
   where cm.room_id = p_room_id
     and cm.left_at is null
     and cm.role = 'admin'
     and not (cm.user_id = any(v_member_ids));
  if v_remaining_admin_count < 1 then
    raise exception using errcode = 'P0001', message = 'CHAT_LAST_ADMIN_REQUIRED';
  end if;

  v_before := private.admin_chat_room_payload(p_room_id, v_admin.user_id);
  update public.chat_members cm
     set left_at = now(), unread_count = 0
   where cm.room_id = p_room_id
     and cm.user_id = any(v_member_ids)
     and cm.left_at is null;

  v_after := private.admin_chat_room_payload(p_room_id, v_admin.user_id);
  insert into public.admin_action_logs(actor_user_id, action_type, target_room_id, reason, before_data, after_data, metadata)
  values (v_admin.user_id, 'chat.member_remove', p_room_id, nullif(trim(coalesce(p_reason, '')), ''),
          v_before, v_after, jsonb_build_object('memberIds', to_jsonb(v_member_ids), 'removedCount', v_active_remove_count));
  return v_after;
end;
$$;

create or replace function public.rpc_admin_join_chat_room(p_room_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_room public.chat_rooms%rowtype;
  v_current_count integer;
  v_was_active boolean;
begin
  v_admin := private.require_admin();
  select * into v_room
    from public.chat_rooms cr
   where cr.id = p_room_id and cr.room_type = 'group'
   for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'CHAT_ROOM_NOT_FOUND';
  end if;

  select exists (
    select 1 from public.chat_members cm
     where cm.room_id = p_room_id and cm.user_id = v_admin.user_id and cm.left_at is null
  ) into v_was_active;
  if v_was_active then
    return private.admin_chat_room_payload(p_room_id, v_admin.user_id);
  end if;

  select count(*)::integer into v_current_count
    from public.chat_members cm
   where cm.room_id = p_room_id and cm.left_at is null;
  if v_current_count >= 100 then
    raise exception using errcode = 'P0001', message = 'CHAT_ROOM_MEMBER_LIMIT_EXCEEDED';
  end if;

  insert into public.chat_members(room_id, user_id, role, last_read_message_id, unread_count, joined_at, left_at)
  values (p_room_id, v_admin.user_id, 'admin', v_room.last_message_id, 0, now(), null)
  on conflict (room_id, user_id) do update set
    role = 'admin', last_read_message_id = excluded.last_read_message_id,
    unread_count = 0, joined_at = now(), left_at = null;

  insert into public.admin_action_logs(actor_user_id, action_type, target_room_id, metadata)
  values (v_admin.user_id, 'chat.admin_join', p_room_id, jsonb_build_object('memberId', v_admin.mb_id));
  return private.admin_chat_room_payload(p_room_id, v_admin.user_id);
end;
$$;

create or replace function public.rpc_admin_get_chat_messages(
  p_room_id uuid,
  p_before_message_id bigint default null,
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 50);
  v_result jsonb;
begin
  v_admin := private.require_admin();
  if not exists (select 1 from public.chat_rooms cr where cr.id = p_room_id and cr.room_type = 'group') then
    raise exception using errcode = 'P0001', message = 'CHAT_ROOM_NOT_FOUND';
  end if;

  with page_data as (
    select cm.id
      from public.chat_messages cm
     where cm.room_id = p_room_id
       and (p_before_message_id is null or cm.id < p_before_message_id)
     order by cm.id desc
     limit v_limit
  )
  select coalesce(jsonb_agg(private.admin_chat_message_payload(page_data.id) order by page_data.id asc), '[]'::jsonb)
    into v_result
    from page_data;
  return coalesce(v_result, '[]'::jsonb);
end;
$$;

create or replace function public.rpc_admin_get_chat_message(p_message_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_result jsonb;
begin
  v_admin := private.require_admin();
  v_result := private.admin_chat_message_payload(p_message_id);
  if v_result is null or v_result = 'null'::jsonb then
    raise exception using errcode = 'P0001', message = 'CHAT_MESSAGE_NOT_FOUND';
  end if;
  return v_result;
end;
$$;

-- 관리자 Realtime 조회 허용. 실제 변경은 RPC만 허용한다.
drop policy if exists chat_rooms_select_admin on public.chat_rooms;
create policy chat_rooms_select_admin
on public.chat_rooms for select to authenticated
using (
  exists (
    select 1 from public.member me
     where me.user_id = (select auth.uid())
       and me.status = 'active'
       and not coalesce(me.is_del, false)
       and me.role in ('admin', 'super_admin')
  )
);

drop policy if exists chat_members_select_admin on public.chat_members;
create policy chat_members_select_admin
on public.chat_members for select to authenticated
using (
  exists (
    select 1 from public.member me
     where me.user_id = (select auth.uid())
       and me.status = 'active'
       and not coalesce(me.is_del, false)
       and me.role in ('admin', 'super_admin')
  )
);

drop policy if exists chat_messages_select_admin on public.chat_messages;
create policy chat_messages_select_admin
on public.chat_messages for select to authenticated
using (
  exists (
    select 1 from public.member me
     where me.user_id = (select auth.uid())
       and me.status = 'active'
       and not coalesce(me.is_del, false)
       and me.role in ('admin', 'super_admin')
  )
);

-- ---------------------------------------------------------------------------
-- 관리자 감사 로그 조회
-- ---------------------------------------------------------------------------
create or replace function public.rpc_admin_list_action_logs(
  p_search text default null,
  p_action_type text default null,
  p_actor_user_id uuid default null,
  p_from_at timestamptz default null,
  p_to_at timestamptz default null,
  p_page integer default 1,
  p_page_size integer default 30
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := least(greatest(coalesce(p_page_size, 30), 1), 100);
  v_offset integer;
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_total bigint;
  v_items jsonb;
begin
  v_admin := private.require_admin();
  v_offset := (v_page - 1) * v_page_size;

  with filtered as (
    select l.id
      from public.admin_action_logs l
      join public.member actor on actor.user_id = l.actor_user_id
      left join public.member target on target.user_id = l.target_user_id
      left join public.chat_rooms room on room.id = l.target_room_id
     where (v_search is null or
            l.id::text ilike '%' || v_search || '%' or
            coalesce(l.reason, '') ilike '%' || v_search || '%' or
            coalesce(l.idempotency_key, '') ilike '%' || v_search || '%' or
            actor.mb_id ilike '%' || v_search || '%' or actor.mb_name ilike '%' || v_search || '%' or
            coalesce(target.mb_id, '') ilike '%' || v_search || '%' or coalesce(target.mb_name, '') ilike '%' || v_search || '%' or
            coalesce(room.title, '') ilike '%' || v_search || '%')
       and (p_action_type is null or p_action_type = '' or l.action_type = p_action_type)
       and (p_actor_user_id is null or l.actor_user_id = p_actor_user_id)
       and (p_from_at is null or l.created_at >= p_from_at)
       and (p_to_at is null or l.created_at <= p_to_at)
  ) select count(*) into v_total from filtered;

  with page_data as (
    select l.*, actor.mb_id as actor_mb_id, actor.mb_name as actor_name, actor.role as actor_role,
           target.mb_id as target_mb_id, target.mb_name as target_name,
           room.title as room_title
      from public.admin_action_logs l
      join public.member actor on actor.user_id = l.actor_user_id
      left join public.member target on target.user_id = l.target_user_id
      left join public.chat_rooms room on room.id = l.target_room_id
     where (v_search is null or
            l.id::text ilike '%' || v_search || '%' or
            coalesce(l.reason, '') ilike '%' || v_search || '%' or
            coalesce(l.idempotency_key, '') ilike '%' || v_search || '%' or
            actor.mb_id ilike '%' || v_search || '%' or actor.mb_name ilike '%' || v_search || '%' or
            coalesce(target.mb_id, '') ilike '%' || v_search || '%' or coalesce(target.mb_name, '') ilike '%' || v_search || '%' or
            coalesce(room.title, '') ilike '%' || v_search || '%')
       and (p_action_type is null or p_action_type = '' or l.action_type = p_action_type)
       and (p_actor_user_id is null or l.actor_user_id = p_actor_user_id)
       and (p_from_at is null or l.created_at >= p_from_at)
       and (p_to_at is null or l.created_at <= p_to_at)
     order by l.created_at desc, l.id desc
     offset v_offset
     limit v_page_size
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id,
    'actionType', p.action_type,
    'actor', jsonb_build_object('userId', p.actor_user_id, 'memberId', p.actor_mb_id, 'name', p.actor_name, 'role', p.actor_role),
    'targetMember', case when p.target_user_id is null then null else jsonb_build_object('userId', p.target_user_id, 'memberId', p.target_mb_id, 'name', p.target_name) end,
    'targetRoom', case when p.target_room_id is null then null else jsonb_build_object('roomId', p.target_room_id, 'title', p.room_title) end,
    'transactionId', p.transaction_id,
    'reason', p.reason,
    'idempotencyKey', p.idempotency_key,
    'beforeData', p.before_data,
    'afterData', p.after_data,
    'metadata', p.metadata,
    'createdAt', p.created_at
  ) order by p.created_at desc), '[]'::jsonb)
    into v_items
    from page_data p;

  return jsonb_build_object('items', coalesce(v_items, '[]'::jsonb), 'page', v_page, 'pageSize', v_page_size, 'totalCount', coalesce(v_total, 0));
end;
$$;

-- ---------------------------------------------------------------------------
-- 권한
-- ---------------------------------------------------------------------------
revoke all on function public.rpc_admin_get_session() from public, anon;
revoke all on function public.rpc_admin_list_members(text, text, text, text, text, boolean, integer, integer, text, text) from public, anon;
revoke all on function public.rpc_admin_search_members(text, integer, uuid) from public, anon;
revoke all on function public.rpc_admin_get_member(uuid) from public, anon;
revoke all on function public.rpc_admin_adjust_stoc(uuid, text, numeric, text, text) from public, anon;
revoke all on function public.rpc_admin_list_transactions(text, text, text, text, uuid, timestamptz, timestamptz, integer, integer) from public, anon;
revoke all on function public.rpc_admin_list_chat_rooms(text, integer, integer) from public, anon;
revoke all on function public.rpc_admin_get_chat_room(uuid) from public, anon;
revoke all on function public.rpc_admin_create_chat_room(text, uuid[]) from public, anon;
revoke all on function public.rpc_admin_update_chat_room(uuid, text) from public, anon;
revoke all on function public.rpc_admin_add_chat_members(uuid, uuid[]) from public, anon;
revoke all on function public.rpc_admin_remove_chat_members(uuid, uuid[], text) from public, anon;
revoke all on function public.rpc_admin_join_chat_room(uuid) from public, anon;
revoke all on function public.rpc_admin_get_chat_messages(uuid, bigint, integer) from public, anon;
revoke all on function public.rpc_admin_get_chat_message(bigint) from public, anon;
revoke all on function public.rpc_admin_list_action_logs(text, text, uuid, timestamptz, timestamptz, integer, integer) from public, anon;

grant execute on function public.rpc_admin_get_session() to authenticated;
grant execute on function public.rpc_admin_list_members(text, text, text, text, text, boolean, integer, integer, text, text) to authenticated;
grant execute on function public.rpc_admin_search_members(text, integer, uuid) to authenticated;
grant execute on function public.rpc_admin_get_member(uuid) to authenticated;
grant execute on function public.rpc_admin_adjust_stoc(uuid, text, numeric, text, text) to authenticated;
grant execute on function public.rpc_admin_list_transactions(text, text, text, text, uuid, timestamptz, timestamptz, integer, integer) to authenticated;
grant execute on function public.rpc_admin_list_chat_rooms(text, integer, integer) to authenticated;
grant execute on function public.rpc_admin_get_chat_room(uuid) to authenticated;
grant execute on function public.rpc_admin_create_chat_room(text, uuid[]) to authenticated;
grant execute on function public.rpc_admin_update_chat_room(uuid, text) to authenticated;
grant execute on function public.rpc_admin_add_chat_members(uuid, uuid[]) to authenticated;
grant execute on function public.rpc_admin_remove_chat_members(uuid, uuid[], text) to authenticated;
grant execute on function public.rpc_admin_join_chat_room(uuid) to authenticated;
grant execute on function public.rpc_admin_get_chat_messages(uuid, bigint, integer) to authenticated;
grant execute on function public.rpc_admin_get_chat_message(bigint) to authenticated;
grant execute on function public.rpc_admin_list_action_logs(text, text, uuid, timestamptz, timestamptz, integer, integer) to authenticated;

select pg_notify('pgrst', 'reload schema');
