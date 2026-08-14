-- STO Network Product Admin - 거래 내역 회원/UUID 검색 timeout hotfix
--
-- 문제:
--   rpc_admin_list_transactions()가 회원 ID/UUID 검색에서도 transactions 전체에
--   sender/receiver member를 LEFT JOIN한 뒤 여러 ILIKE '%search%' 조건을 수행하고,
--   동일한 filtered 쿼리를 count/page 조회로 두 번 실행해 statement timeout이 발생할 수 있었다.
--
-- 개선:
--   1) 완전한 UUID 검색은 거래 ID / sender_user_id / receiver_user_id exact match fast-path 사용
--   2) 완전한 mb_id 검색은 member에서 user_id를 먼저 찾은 뒤 transactions를 exact match
--   3) 일반 문자열 검색은 member를 먼저 검색해 user_id 집합을 만든 뒤 transactions에 적용
--   4) count/page가 동일한 filtered 결과를 공유하도록 MATERIALIZED CTE 사용
--   5) sender/receiver + created_at 인덱스 추가

create index if not exists transactions_admin_sender_created_idx
  on public.transactions (sender_user_id, created_at desc, id desc);

create index if not exists transactions_admin_receiver_created_idx
  on public.transactions (receiver_user_id, created_at desc, id desc);

create index if not exists transactions_admin_created_id_idx
  on public.transactions (created_at desc, id desc);

create index if not exists member_admin_mb_id_lower_idx
  on public.member (lower(mb_id));

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
  v_search_uuid uuid;
  v_exact_member_user_id uuid;
  v_total bigint := 0;
  v_items jsonb := '[]'::jsonb;
begin
  v_admin := private.require_admin();
  v_offset := (v_page - 1) * v_page_size;

  -- UUID 형식이면 문자열 ILIKE 검색으로 보내지 않는다.
  if v_search is not null
     and v_search ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
    v_search_uuid := v_search::uuid;
  end if;

  -- UUID가 아닌 검색어가 실제 mb_id와 완전히 일치하면 회원 UUID를 먼저 확보한다.
  -- 기존 ILIKE 특성에 맞춰 대소문자는 무시한다.
  if v_search is not null and v_search_uuid is null then
    select m.user_id
      into v_exact_member_user_id
      from public.member m
     where lower(m.mb_id) = lower(v_search)
     limit 1;
  end if;

  if v_search is null then
    -- 검색어가 없을 때는 member JOIN 없이 거래 테이블만 필터링한다.
    with filtered as materialized (
      select t.id, t.created_at
        from public.transactions t
       where (p_transaction_type is null or p_transaction_type = '' or t.transaction_type = p_transaction_type)
         and (p_status is null or p_status = '' or t.status = p_status)
         and (p_asset_code is null or p_asset_code = '' or t.asset_code = upper(trim(p_asset_code)))
         and (p_user_id is null or t.sender_user_id = p_user_id or t.receiver_user_id = p_user_id)
         and (p_from_at is null or t.created_at >= p_from_at)
         and (p_to_at is null or t.created_at <= p_to_at)
    ), page_data as (
      select f.id, f.created_at
        from filtered f
       order by f.created_at desc, f.id desc
       offset v_offset
       limit v_page_size
    )
    select
      (select count(*) from filtered),
      coalesce(
        (select jsonb_agg(private.admin_transaction_payload(p.id) order by p.created_at desc, p.id desc)
           from page_data p),
        '[]'::jsonb
      )
      into v_total, v_items;

  elsif v_search_uuid is not null then
    -- UUID fast-path: 거래 ID 또는 송/수신 회원 UUID exact match만 수행한다.
    with filtered as materialized (
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
    ), page_data as (
      select f.id, f.created_at
        from filtered f
       order by f.created_at desc, f.id desc
       offset v_offset
       limit v_page_size
    )
    select
      (select count(*) from filtered),
      coalesce(
        (select jsonb_agg(private.admin_transaction_payload(p.id) order by p.created_at desc, p.id desc)
           from page_data p),
        '[]'::jsonb
      )
      into v_total, v_items;

  elsif v_exact_member_user_id is not null then
    -- 완전한 회원 ID fast-path: member를 먼저 찾고 거래 테이블은 UUID로만 조회한다.
    with filtered as materialized (
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
    ), page_data as (
      select f.id, f.created_at
        from filtered f
       order by f.created_at desc, f.id desc
       offset v_offset
       limit v_page_size
    )
    select
      (select count(*) from filtered),
      coalesce(
        (select jsonb_agg(private.admin_transaction_payload(p.id) order by p.created_at desc, p.id desc)
           from page_data p),
        '[]'::jsonb
      )
      into v_total, v_items;

  else
    -- 일반 문자열 검색: 거래마다 member를 2번 JOIN하지 않고,
    -- member 검색 결과 UUID 집합을 먼저 만든 뒤 transactions에 적용한다.
    with matched_member_ids as materialized (
      select m.user_id
        from public.member m
       where coalesce(m.mb_id, '') ilike '%' || v_search || '%'
          or coalesce(m.mb_name, '') ilike '%' || v_search || '%'
          or coalesce(m.mb_email, '') ilike '%' || v_search || '%'
    ), filtered as materialized (
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
    ), page_data as (
      select f.id, f.created_at
        from filtered f
       order by f.created_at desc, f.id desc
       offset v_offset
       limit v_page_size
    )
    select
      (select count(*) from filtered),
      coalesce(
        (select jsonb_agg(private.admin_transaction_payload(p.id) order by p.created_at desc, p.id desc)
           from page_data p),
        '[]'::jsonb
      )
      into v_total, v_items;
  end if;

  return jsonb_build_object(
    'items', coalesce(v_items, '[]'::jsonb),
    'page', v_page,
    'pageSize', v_page_size,
    'totalCount', coalesce(v_total, 0)
  );
end;
$$;

revoke all on function public.rpc_admin_list_transactions(text, text, text, text, uuid, timestamptz, timestamptz, integer, integer) from public, anon;
grant execute on function public.rpc_admin_list_transactions(text, text, text, text, uuid, timestamptz, timestamptz, integer, integer) to authenticated;
