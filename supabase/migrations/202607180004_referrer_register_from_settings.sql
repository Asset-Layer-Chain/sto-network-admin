-- Allow users without a registered referrer to add one later from the settings/all-menu flow.

create or replace function public.rpc_register_referrer_by_code(
  p_referral_code text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_referrer public.member%rowtype;
  v_input text := trim(coalesce(p_referral_code, ''));
  v_existing_referrer uuid;
begin
  v_member := private.require_active_member();

  if v_input = '' then
    return jsonb_build_object(
      'ok', false,
      'code', 'empty_referral_code',
      'message', '추천인 ID를 입력해주세요.'
    );
  end if;

  select rn.referrer_user_id
    into v_existing_referrer
    from public.referral_network rn
   where rn.referred_user_id = v_member.user_id
     and rn.depth = 1
     and rn.status = 'active'
   order by rn.joined_at desc nulls last, rn.created_at desc nulls last
   limit 1;

  if v_member.referrer_user_id is not null or v_existing_referrer is not null then
    return jsonb_build_object(
      'ok', false,
      'code', 'already_has_referrer',
      'message', '이미 추천인 ID가 등록되어 있습니다.'
    );
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
    return jsonb_build_object(
      'ok', false,
      'code', 'not_found',
      'message', '추천인 ID를 찾을 수 없습니다.'
    );
  end if;

  if v_referrer.user_id = v_member.user_id then
    return jsonb_build_object(
      'ok', false,
      'code', 'self_referral',
      'message', '본인의 추천인 ID는 입력할 수 없습니다.'
    );
  end if;

  update public.member
     set referrer_user_id = v_referrer.user_id,
         updated_at = now()
   where user_id = v_member.user_id
     and referrer_user_id is null;

  insert into public.referral_network(
    referrer_user_id,
    referred_user_id,
    depth,
    status,
    joined_at
  ) values (
    v_referrer.user_id,
    v_member.user_id,
    1,
    'active',
    now()
  )
  on conflict (referrer_user_id, referred_user_id, depth)
  do update set status = 'active', joined_at = coalesce(public.referral_network.joined_at, excluded.joined_at);

  return jsonb_build_object(
    'ok', true,
    'message', '추천인 ID가 등록되었습니다.',
    'referrer', jsonb_build_object(
      'user_id', v_referrer.user_id,
      'mb_id', v_referrer.mb_id,
      'mb_name', v_referrer.mb_name,
      'referral_code', v_referrer.referral_code
    )
  );
end;
$$;
revoke all on function public.rpc_register_referrer_by_code(text) from public, anon;
grant execute on function public.rpc_register_referrer_by_code(text) to authenticated;
