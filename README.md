# STO Network Product Admin

`sto-network-admin.stodev.xyz`에서 사용할 별도 관리자 React/Vite 프로젝트입니다.
기존 STO Network와 동일한 Supabase 프로젝트 및 Auth를 사용하며, 중요 변경은 관리자 전용 PostgreSQL RPC로만 수행합니다.

## 포함 기능

- `member` 전체 컬럼 조회
- 회원 검색, 필터, 정렬, 서버 페이지네이션
- 회원 상세: 지갑, 최근 거래, 기기, 동의, 유입 정보, 탈퇴 요청, 채팅방
- `STOC_INT` 지급(`deposit`), 차감(`withdrawal`), 에어드랍(`airdrop`)
- 잔액 행 잠금, 거래 멱등성, 음수 잔액 방지
- 전체 거래 내역 조회
- 그룹 채팅방 생성 및 제목 변경
- 채팅방 회원 일괄 추가/제외
- 채팅방 활성 인원 최대 100명 하드 제한
- 관리자 채팅 및 Supabase Realtime 신규 메시지 반영
- 관리자 작업 감사 로그

## 제외 범위

- EC2, Nginx, DNS 설정
- GitHub Actions 및 CI/CD
- 회원 정보 수정, 회원 정지/삭제
- 대량 에어드랍
- 채팅 메시지 삭제
- 관리자 계정/권한 생성 UI

## 실행 준비

```bash
cp .env.example .env.local
npm install
npm run dev
```

`.env.local`:

```env
VITE_SUPABASE_URL=https://<project-ref>.supabase.co
VITE_SUPABASE_ANON_KEY=<publishable-or-anon-key>
VITE_WEB_BASE_URL=https://sto-network-admin.stodev.xyz
VITE_SUPABASE_AUTH_REDIRECT_URL=https://sto-network-admin.stodev.xyz/auth/callback
VITE_APP_BASE_PATH=/
```

브라우저 프로젝트에 `service_role`, secret key, DB 비밀번호를 넣지 않습니다.

## DB 마이그레이션

기존 STO Network 마이그레이션이 모두 반영된 DB에 다음 파일을 적용합니다.

```text
supabase/migrations/202608010050_product_admin_console.sql
```

Supabase CLI를 사용하는 경우:

```bash
supabase link --project-ref <project-ref>
supabase db push
```

SQL Editor로 적용할 수도 있습니다. 이 마이그레이션은 아래 객체를 생성합니다.

- `public.admin_action_logs`
- `private.require_admin()`
- `private.require_super_admin()`
- 관리자 회원/거래/채팅 payload helper
- 관리자 전용 `rpc_admin_*` 함수
- 관리자 채팅 Realtime 조회 RLS 정책
- 채팅방 활성 인원 100명 제한 트리거

## 관리자 계정

로그인하려는 Auth 사용자의 `public.member.role`이 `admin` 또는 `super_admin`이어야 합니다.
또한 `status = 'active'`, `is_del = false`여야 합니다.

관리자 역할은 운영 DB에서 승인 절차에 따라 직접 설정합니다.

```sql
update public.member
set role = 'admin', updated_at = now()
where mb_id = '<관리자 회원 ID>';
```

## 자산 처리 규칙

| UI | transaction_type | 잔액 변화 |
|---|---|---:|
| 지급 | `deposit` | 증가 |
| 차감 | `withdrawal` | 감소 |
| 에어드랍 | `airdrop` | 증가 |

- 대상 지갑: `asset_code = 'STOC_INT'`, `account_type = 'internal'`
- `transactions.amount`는 항상 양수
- 차감은 `sender_user_id`에 대상 회원 저장
- 지급/에어드랍은 `receiver_user_id`에 대상 회원 저장
- 모든 처리는 `completed`, `processed_at = now()`로 기록
- 브라우저 재시도 및 중복 클릭은 `idempotency_key`로 차단
- 모든 처리 사유와 변경 전후 잔액은 거래 metadata 및 `admin_action_logs`에 기록

## 주요 관리자 RPC

```text
rpc_admin_get_session
rpc_admin_list_members
rpc_admin_search_members
rpc_admin_get_member
rpc_admin_adjust_stoc
rpc_admin_list_transactions
rpc_admin_list_chat_rooms
rpc_admin_get_chat_room
rpc_admin_create_chat_room
rpc_admin_update_chat_room
rpc_admin_add_chat_members
rpc_admin_remove_chat_members
rpc_admin_join_chat_room
rpc_admin_get_chat_messages
rpc_admin_get_chat_message
rpc_admin_list_action_logs
```

메시지 전송은 기존 `rpc_send_chat_message`를 재사용합니다. 해당 관리자 계정이 방에 없으면 첫 전송 직전에 `rpc_admin_join_chat_room`으로 참여합니다.

## 1차 통합 확인 순서

1. 마이그레이션 적용
2. 관리자 계정 로그인
3. 회원 목록 및 상세 전체 컬럼 조회
4. 테스트 회원에게 `deposit` 1 STOC
5. 동일 화면에서 `withdrawal` 1 STOC
6. `airdrop` 1 STOC
7. 거래 내역 및 관리자 로그 확인
8. 관리자 + 테스트 회원으로 그룹 채팅방 생성
9. 회원 추가/제외
10. 서로 다른 브라우저에서 실시간 채팅 확인
11. 100명 초과 추가 요청 차단 확인

상세 점검표는 `docs/INTEGRATION_CHECKLIST.md`를 참고합니다.
