-- STO Network Product Admin - transaction cursor pagination
--
-- 목표:
--   1) 첫 조회/필터 변경 시에만 정확한 totalCount를 계산한다.
--   2) 페이지 이동은 OFFSET 없이 (created_at, id) cursor로 조회한다.
--   3) 다음 페이지 존재 여부는 page_size + 1건만 읽어서 판단한다.
--   4) 기본 필터(transaction_type + asset_code)에 맞는 정렬 인덱스를 추가한다.

create index if not exists transactions_admin_type_asset_created_idx
  on public.transactions (transaction_type, asset_code, created_at desc, id desc);

create or replace function public.rpc_admin_list_transactions_cursor(
  p_search text default null,
  p_transaction_type text default null,
  p_status text default null,
  p_asset_code text default null,
  p_user_id uuid default null,
  p_from_at timestamptz default null,
  p_to_at timestamptz default null,
  p_cursor_created_at timestamptz default null,
  p_cursor_id uuid default null,
  p_include_total boolean default true,
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
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_search_uuid uuid;
  v_exact_member_user_id uuid;
  v_total bigint;
  v_items jsonb := '[]'::jsonb;
  v_has_next boolean := false;
  v_next_created_at timestamptz;
  v_next_id uuid;
begin
  v_admin := private.require_admin();

  if (p_cursor_created_at is null) <> (p_cursor_id is null) then
    raise exception 'INVALID_TRANSACTION_CURSOR';
  end if;

  if v_search is not null
     and v_search ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
    v_search_uuid := v_search::uuid;
  end if;

  if v_search is not null and v_search_uuid is null then
    select m.user_id
      into v_exact_member_user_id
      from public.member m
     where lower(m.mb_id) = lower(v_search)
     limit 1;
  end if;

  if v_search is null then
    if coalesce(p_include_total, true) then
      select count(*)
        into v_total
        from public.transactions t
       where (p_transaction_type is null or p_transaction_type = '' or t.transaction_type = p_transaction_type)
         and (p_status is null or p_status = '' or t.status = p_status)
         and (p_asset_code is null or p_asset_code = '' or t.asset_code = upper(trim(p_asset_code)))
         and (p_user_id is null or t.sender_user_id = p_user_id or t.receiver_user_id = p_user_id)
         and (p_from_at is null or t.created_at >= p_from_at)
         and (p_to_at is null or t.created_at <= p_to_at);
    end if;

    with page_data as materialized (
      select t.id, t.created_at
        from public.transactions t
       where (p_transaction_type is null or p_transaction_type = '' or t.transaction_type = p_transaction_type)
         and (p_status is null or p_status = '' or t.status = p_status)
         and (p_asset_code is null or p_asset_code = '' or t.asset_code = upper(trim(p_asset_code)))
         and (p_user_id is null or t.sender_user_id = p_user_id or t.receiver_user_id = p_user_id)
         and (p_from_at is null or t.created_at >= p_from_at)
         and (p_to_at is null or t.created_at <= p_to_at)
         and (p_cursor_created_at is null or (t.created_at, t.id) < (p_cursor_created_at, p_cursor_id))
       order by t.created_at desc, t.id desc
       limit v_page_size + 1
    ), visible_page as (
      select p.id, p.created_at
        from page_data p
       order by p.created_at desc, p.id desc
       limit v_page_size
    )
    select
      coalesce(
        (select jsonb_agg(private.admin_transaction_payload(p.id) order by p.created_at desc, p.id desc)
           from visible_page p),
        '[]'::jsonb
      ),
      (select count(*) from page_data) > v_page_size,
      (select p.created_at from visible_page p order by p.created_at asc, p.id asc limit 1),
      (select p.id from visible_page p order by p.created_at asc, p.id asc limit 1)
      into v_items, v_has_next, v_next_created_at, v_next_id;

  elsif v_search_uuid is not null then
    if coalesce(p_include_total, true) then
      select count(*)
        into v_total
        from public.transactions t
       where (t.id = v_search_uuid
              or t.sender_user_id = v_search_uuid
              or t.receiver_user_id = v_search_uuid)
         and (p_transaction_type is null or p_transaction_type = '' or t.transaction_type = p_transaction_type)
         and (p_status is null or p_status = '' or t.status = p_status)
         and (p_asset_code is null or p_asset_code = '' or t.asset_code = upper(trim(p_asset_code)))
         and (p_user_id is null or t.sender_user_id = p_user_id or t.receiver_user_id = p_user_id)
         and (p_from_at is null or t.created_at >= p_from_at)
         and (p_to_at is null or t.created_at <= p_to_at);
    end if;

    with page_data as materialized (
      select t.id, t.created_at
        from public.transactions t
       where (t.id = v_search_uuid
              or t.sender_user_id = v_search_uuid
              or t.receiver_user_id = v_search_uuid)
         and (p_transaction_type is null or p_transaction_type = '' or t.transaction_type = p_transaction_type)
         and (p_status is null or p_status = '' or t.status = p_status)
         and (p_asset_code is null or p_asset_code = '' or t.asset_code = upper(trim(p_asset_code)))
         and (p_user_id is null or t.sender_user_id = p_user_id or t.receiver_user_id = p_user_id)
         and (p_from_at is null or t.created_at >= p_from_at)
         and (p_to_at is null or t.created_at <= p_to_at)
         and (p_cursor_created_at is null or (t.created_at, t.id) < (p_cursor_created_at, p_cursor_id))
       order by t.created_at desc, t.id desc
       limit v_page_size + 1
    ), visible_page as (
      select p.id, p.created_at
        from page_data p
       order by p.created_at desc, p.id desc
       limit v_page_size
    )
    select
      coalesce(
        (select jsonb_agg(private.admin_transaction_payload(p.id) order by p.created_at desc, p.id desc)
           from visible_page p),
        '[]'::jsonb
      ),
      (select count(*) from page_data) > v_page_size,
      (select p.created_at from visible_page p order by p.created_at asc, p.id asc limit 1),
      (select p.id from visible_page p order by p.created_at asc, p.id asc limit 1)
      into v_items, v_has_next, v_next_created_at, v_next_id;

  elsif v_exact_member_user_id is not null then
    if coalesce(p_include_total, true) then
      select count(*)
        into v_total
        from public.transactions t
       where (t.sender_user_id = v_exact_member_user_id
              or t.receiver_user_id = v_exact_member_user_id)
         and (p_transaction_type is null or p_transaction_type = '' or t.transaction_type = p_transaction_type)
         and (p_status is null or p_status = '' or t.status = p_status)
         and (p_asset_code is null or p_asset_code = '' or t.asset_code = upper(trim(p_asset_code)))
         and (p_user_id is null or t.sender_user_id = p_user_id or t.receiver_user_id = p_user_id)
         and (p_from_at is null or t.created_at >= p_from_at)
         and (p_to_at is null or t.created_at <= p_to_at);
    end if;

    with page_data as materialized (
      select t.id, t.created_at
        from public.transactions t
       where (t.sender_user_id = v_exact_member_user_id
              or t.receiver_user_id = v_exact_member_user_id)
         and (p_transaction_type is null or p_transaction_type = '' or t.transaction_type = p_transaction_type)
         and (p_status is null or p_status = '' or t.status = p_status)
         and (p_asset_code is null or p_asset_code = '' or t.asset_code = upper(trim(p_asset_code)))
         and (p_user_id is null or t.sender_user_id = p_user_id or t.receiver_user_id = p_user_id)
         and (p_from_at is null or t.created_at >= p_from_at)
         and (p_to_at is null or t.created_at <= p_to_at)
         and (p_cursor_created_at is null or (t.created_at, t.id) < (p_cursor_created_at, p_cursor_id))
       order by t.created_at desc, t.id desc
       limit v_page_size + 1
    ), visible_page as (
      select p.id, p.created_at
        from page_data p
       order by p.created_at desc, p.id desc
       limit v_page_size
    )
    select
      coalesce(
        (select jsonb_agg(private.admin_transaction_payload(p.id) order by p.created_at desc, p.id desc)
           from visible_page p),
        '[]'::jsonb
      ),
      (select count(*) from page_data) > v_page_size,
      (select p.created_at from visible_page p order by p.created_at asc, p.id asc limit 1),
      (select p.id from visible_page p order by p.created_at asc, p.id asc limit 1)
      into v_items, v_has_next, v_next_created_at, v_next_id;

  else
    if coalesce(p_include_total, true) then
      with matched_member_ids as materialized (
        select m.user_id
          from public.member m
         where coalesce(m.mb_id, '') ilike '%' || v_search || '%'
            or coalesce(m.mb_name, '') ilike '%' || v_search || '%'
            or coalesce(m.mb_email, '') ilike '%' || v_search || '%'
      )
      select count(*)
        into v_total
        from public.transactions t
       where (
              t.id::text ilike '%' || v_search || '%'
              or coalesce(t.description, '') ilike '%' || v_search || '%'
              or coalesce(t.idempotency_key, '') ilike '%' || v_search || '%'
              or t.sender_user_id in (select mm.user_id from matched_member_ids mm)
              or t.receiver_user_id in (select mm.user_id from matched_member_ids mm)
             )
         and (p_transaction_type is null or p_transaction_type = '' or t.transaction_type = p_transaction_type)
         and (p_status is null or p_status = '' or t.status = p_status)
         and (p_asset_code is null or p_asset_code = '' or t.asset_code = upper(trim(p_asset_code)))
         and (p_user_id is null or t.sender_user_id = p_user_id or t.receiver_user_id = p_user_id)
         and (p_from_at is null or t.created_at >= p_from_at)
         and (p_to_at is null or t.created_at <= p_to_at);
    end if;

    with matched_member_ids as materialized (
      select m.user_id
        from public.member m
       where coalesce(m.mb_id, '') ilike '%' || v_search || '%'
          or coalesce(m.mb_name, '') ilike '%' || v_search || '%'
          or coalesce(m.mb_email, '') ilike '%' || v_search || '%'
    ), page_data as materialized (
      select t.id, t.created_at
        from public.transactions t
       where (
              t.id::text ilike '%' || v_search || '%'
              or coalesce(t.description, '') ilike '%' || v_search || '%'
              or coalesce(t.idempotency_key, '') ilike '%' || v_search || '%'
              or t.sender_user_id in (select mm.user_id from matched_member_ids mm)
              or t.receiver_user_id in (select mm.user_id from matched_member_ids mm)
             )
         and (p_transaction_type is null or p_transaction_type = '' or t.transaction_type = p_transaction_type)
         and (p_status is null or p_status = '' or t.status = p_status)
         and (p_asset_code is null or p_asset_code = '' or t.asset_code = upper(trim(p_asset_code)))
         and (p_user_id is null or t.sender_user_id = p_user_id or t.receiver_user_id = p_user_id)
         and (p_from_at is null or t.created_at >= p_from_at)
         and (p_to_at is null or t.created_at <= p_to_at)
         and (p_cursor_created_at is null or (t.created_at, t.id) < (p_cursor_created_at, p_cursor_id))
       order by t.created_at desc, t.id desc
       limit v_page_size + 1
    ), visible_page as (
      select p.id, p.created_at
        from page_data p
       order by p.created_at desc, p.id desc
       limit v_page_size
    )
    select
      coalesce(
        (select jsonb_agg(private.admin_transaction_payload(p.id) order by p.created_at desc, p.id desc)
           from visible_page p),
        '[]'::jsonb
      ),
      (select count(*) from page_data) > v_page_size,
      (select p.created_at from visible_page p order by p.created_at asc, p.id asc limit 1),
      (select p.id from visible_page p order by p.created_at asc, p.id asc limit 1)
      into v_items, v_has_next, v_next_created_at, v_next_id;
  end if;

  return jsonb_build_object(
    'items', coalesce(v_items, '[]'::jsonb),
    'page', v_page,
    'pageSize', v_page_size,
    'totalCount', v_total,
    'hasNext', coalesce(v_has_next, false),
    'nextCursor', case
      when v_next_id is null then null
      else jsonb_build_object('createdAt', v_next_created_at, 'id', v_next_id)
    end
  );
end;
$$;

revoke all on function public.rpc_admin_list_transactions_cursor(text, text, text, text, uuid, timestamptz, timestamptz, timestamptz, uuid, boolean, integer, integer) from public, anon;
grant execute on function public.rpc_admin_list_transactions_cursor(text, text, text, text, uuid, timestamptz, timestamptz, timestamptz, uuid, boolean, integer, integer) to authenticated;
