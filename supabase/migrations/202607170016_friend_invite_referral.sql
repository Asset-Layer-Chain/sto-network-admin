-- Friend tab = referral relationship UX support.
-- UI에서는 친구로 표시하되, 가입 화면에서만 추천인 용어를 사용한다.

create or replace function public.rpc_list_friend_members(
  p_limit integer default 100
)
returns table (
  user_id uuid,
  mb_no bigint,
  mb_id text,
  mb_name text,
  mb_email text,
  mb_profile text,
  relation_type text,
  referral_status text,
  joined_at timestamptz,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 200);
begin
  v_member := private.require_active_member();

  return query
  with friends as (
    -- 나를 추천한 사람: 1명만 존재해야 하며 친구 목록 최상단에 표시한다.
    select
      referrer.user_id,
      referrer.mb_no,
      referrer.mb_id,
      referrer.mb_name,
      referrer.mb_email,
      referrer.mb_profile,
      'referrer'::text as relation_type,
      'active'::text as referral_status,
      coalesce(rn.joined_at, v_member.created_at) as joined_at,
      referrer.created_at,
      0 as relation_order
    from public.member referrer
    left join public.referral_network rn
      on rn.referrer_user_id = referrer.user_id
     and rn.referred_user_id = v_member.user_id
     and rn.depth = 1
     and rn.status = 'active'
    where referrer.user_id = v_member.referrer_user_id
      and referrer.status = 'active'
      and not coalesce(referrer.is_del, false)

    union all

    -- 내가 추천한 사람들.
    select
      referred.user_id,
      referred.mb_no,
      referred.mb_id,
      referred.mb_name,
      referred.mb_email,
      referred.mb_profile,
      'referred'::text as relation_type,
      rn.status as referral_status,
      rn.joined_at,
      referred.created_at,
      1 as relation_order
    from public.referral_network rn
    join public.member referred on referred.user_id = rn.referred_user_id
    where rn.referrer_user_id = v_member.user_id
      and rn.depth = 1
      and rn.status = 'active'
      and referred.status = 'active'
      and not coalesce(referred.is_del, false)
  )
  select
    f.user_id,
    f.mb_no,
    f.mb_id,
    f.mb_name,
    f.mb_email,
    f.mb_profile,
    f.relation_type,
    f.referral_status,
    f.joined_at,
    f.created_at
  from friends f
  order by f.relation_order asc, f.joined_at desc nulls last, f.created_at desc
  limit v_limit;
end;
$$;
create or replace function public.rpc_resolve_referral_code(
  p_referral_code text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_input text := trim(coalesce(p_referral_code, ''));
  v_referrer public.member%rowtype;
begin
  if v_input = '' then
    return jsonb_build_object('valid', false, 'referrer', null);
  end if;

  select * into v_referrer
    from public.member m
   where m.status = 'active'
     and not coalesce(m.is_del, false)
     and (
       lower(m.referral_code) = lower(v_input)
       or lower(m.mb_id) = lower(v_input)
     )
   order by case when lower(m.referral_code) = lower(v_input) then 0 else 1 end
   limit 1;

  if not found then
    return jsonb_build_object('valid', false, 'referrer', null);
  end if;

  return jsonb_build_object(
    'valid', true,
    'referrer', jsonb_build_object(
      'user_id', v_referrer.user_id,
      'mb_id', v_referrer.mb_id,
      'mb_name', v_referrer.mb_name,
      'referral_code', v_referrer.referral_code
    )
  );
end;
$$;
create or replace function private.prevent_referrer_user_id_change()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
begin
  if old.referrer_user_id is not null
     and new.referrer_user_id is distinct from old.referrer_user_id then
    raise exception using errcode = 'P0001', message = 'REFERRER_ALREADY_FIXED';
  end if;

  return new;
end;
$$;
drop trigger if exists member_referrer_immutable_trg on public.member;
create trigger member_referrer_immutable_trg
before update of referrer_user_id on public.member
for each row
execute function private.prevent_referrer_user_id_change();
revoke all on function public.rpc_list_friend_members(integer) from public, anon;
grant execute on function public.rpc_list_friend_members(integer) to authenticated;
revoke all on function public.rpc_resolve_referral_code(text) from public;
grant execute on function public.rpc_resolve_referral_code(text) to anon, authenticated;
