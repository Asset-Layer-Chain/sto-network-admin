-- ============================================================================
-- STO Network - pgcrypto / roulette repair migration
-- 이미 202607170002_core_rpc.sql이 적용된 프로젝트에서 실행한다.
-- ============================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
-- pgcrypto가 과거 public 등 다른 스키마에 설치됐다면 Supabase 표준 extensions로 이동한다.
do $migration$
declare
  v_extension_schema text;
begin
  select n.nspname
    into v_extension_schema
    from pg_extension e
    join pg_namespace n on n.oid = e.extnamespace
   where e.extname = 'pgcrypto';

  if v_extension_schema is distinct from 'extensions' then
    execute 'alter extension pgcrypto set schema extensions';
  end if;
end;
$migration$;
create or replace function public.rpc_spin_daily_roulette(
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_today date := private.kst_date();
  v_spin public.roulette_spins%rowtype;
  v_spin_id uuid;
  v_transaction_id uuid;
  v_prize_id smallint;
  v_prize_value numeric;
  v_balance numeric;
begin
  v_member := private.require_active_member();

  perform pg_advisory_xact_lock(
    hashtextextended('roulette:' || v_member.user_id::text || ':' || v_today::text, 0)
  );

  select * into v_spin
    from public.roulette_spins
   where user_id = v_member.user_id
     and spin_date = v_today;

  if found then
    return jsonb_build_object(
      'alreadySpun', true,
      'spinDate', v_today,
      'spin', to_jsonb(v_spin),
      'memberInitialAidas', private.wallet_balance(v_member.user_id, 'STOC_INT'),
      'transaction', case
        when v_spin.transaction_id is null then null
        else private.transaction_json(v_spin.transaction_id)
      end
    );
  end if;

  -- 256은 8과 4로 나누어떨어지므로 modulo bias 없음
  v_prize_id := ((get_byte(extensions.gen_random_bytes(1), 0) % 8) + 1)::smallint;
  v_prize_value := ((get_byte(extensions.gen_random_bytes(1), 0) % 4) + 1)::numeric;

  v_spin_id := gen_random_uuid();
  v_transaction_id := gen_random_uuid();
  v_balance := private.credit_wallet(v_member.user_id, 'STOC_INT', v_prize_value);

  insert into public.transactions (
    id,
    sender_user_id,
    receiver_user_id,
    asset_code,
    amount,
    fee_amount,
    transaction_type,
    status,
    description,
    reference_type,
    reference_id,
    idempotency_key,
    metadata,
    processed_at
  ) values (
    v_transaction_id,
    null,
    v_member.user_id,
    'STOC_INT',
    v_prize_value,
    0,
    'roulette_reward',
    'completed',
    '돌림판',
    'roulette',
    v_spin_id,
    'roulette:' || v_member.user_id::text || ':' || v_today::text,
    jsonb_build_object(
      'request_id', p_idempotency_key,
      'spin_date', v_today,
      'prize_id', v_prize_id,
      'timezone', 'Asia/Seoul'
    ),
    now()
  );

  insert into public.roulette_spins (
    id,
    user_id,
    spin_date,
    prize_id,
    prize_value,
    transaction_id,
    result_meta
  ) values (
    v_spin_id,
    v_member.user_id,
    v_today,
    v_prize_id,
    v_prize_value,
    v_transaction_id,
    jsonb_build_object('generated_by', 'database', 'timezone', 'Asia/Seoul')
  )
  returning * into v_spin;

  return jsonb_build_object(
    'alreadySpun', false,
    'spinDate', v_today,
    'spin', to_jsonb(v_spin),
    'memberInitialAidas', v_balance,
    'transaction', private.transaction_json(v_transaction_id)
  );
end;
$$;
revoke all on function public.rpc_spin_daily_roulette(text) from public, anon, authenticated;
grant execute on function public.rpc_spin_daily_roulette(text) to authenticated;
