import { getSupabaseClient } from './supabaseClient.js';

const ERROR_MESSAGES = {
  AUTH_REQUIRED: '로그인이 필요합니다.',
  ADMIN_PERMISSION_REQUIRED: '관리자 권한이 필요합니다.',
  ADMIN_PROFILE_REQUIRED: '관리자 자산 권한 등급이 설정되지 않았습니다.',
  ADMIN_ASSET_PERMISSION_DENIED: '현재 관리자 등급으로는 이 자산 작업을 수행할 수 없습니다.',
  SUPER_ADMIN_PERMISSION_REQUIRED: '최고 관리자 권한이 필요합니다.',
  MEMBER_NOT_FOUND: '회원을 찾을 수 없습니다.',
  MEMBER_DELETED: '탈퇴 또는 삭제된 회원입니다.',
  INVALID_ADMIN_TRANSACTION_TYPE: '지원하지 않는 자산 처리 유형입니다.',
  INVALID_AMOUNT: '금액은 0보다 커야 합니다.',
  INVALID_AMOUNT_SCALE: '금액은 소수점 8자리 이내로 입력해주세요.',
  ADMIN_AMOUNT_LIMIT_EXCEEDED: '한 번에 처리할 수 있는 최대 금액을 초과했습니다.',
  ADMIN_REASON_REQUIRED: '처리 사유를 입력해주세요.',
  ADMIN_REASON_PRESET_MANAGE_PERMISSION_DENIED: '센터장 이상 관리자만 처리 사유를 관리할 수 있습니다.',
  INVALID_ADMIN_REASON_PRESET_ACTION: '지원하지 않는 처리 사유 유형입니다.',
  ADMIN_REASON_PRESET_LABEL_REQUIRED: '처리 사유 표시명을 입력해주세요.',
  ADMIN_REASON_PRESET_TEXT_REQUIRED: '처리 사유 문구를 입력해주세요.',
  ADMIN_REASON_PRESET_NOT_FOUND: '처리 사유를 찾을 수 없습니다.',

  ADMIN_BULK_DEPOSIT_PERMISSION_DENIED: '본부급 관리자만 POS 일괄 지급을 사용할 수 있습니다.',
  BULK_POS_FILE_ALREADY_COMPLETED: '이미 지급 완료된 엑셀 파일입니다.',
  BULK_POS_ROWS_REQUIRED: '지급 대상 행이 없습니다.',
  BULK_POS_TOO_MANY_ROWS: '한 번에 검증 가능한 행은 최대 2,000건입니다.',
  BULK_POS_INVALID_ROW: '필수값이 비어 있는 행이 있습니다.',
  BULK_POS_DUPLICATED_IN_EXCEL: '엑셀 내 중복 행이 있어 일괄 지급할 수 없습니다.',
  BULK_POS_HAS_REJECTED_ROWS: '검증 제외 건이 있어 일괄 지급할 수 없습니다.',
  BULK_POS_BATCH_NOT_FOUND: '일괄 지급 검증 내역을 찾지 못했습니다.',
  BULK_POS_BATCH_NOT_VALIDATED: '검증 완료 상태의 일괄 지급만 실행할 수 있습니다.',
  BULK_POS_CONFIRM_TEXT_INVALID: '최종 확인 문구가 일치하지 않습니다.',
  BULK_POS_REASON_REQUIRED: '일괄 지급 처리 사유를 입력해주세요.',
  BULK_POS_REASON_TOO_LONG: '일괄 지급 처리 사유는 200자 이내로 입력해주세요.',
  IDEMPOTENCY_KEY_REQUIRED: '요청 식별값이 없습니다.',
  INSUFFICIENT_BALANCE: '회원의 보유 잔액이 부족합니다.',
  CHAT_ROOM_NOT_FOUND: '채팅방을 찾을 수 없습니다.',
  CHAT_ROOM_TITLE_REQUIRED: '채팅방 제목을 입력해주세요.',
  CHAT_ROOM_MEMBER_COUNT_INVALID: '채팅방은 관리자 포함 2명 이상이어야 합니다.',
  CHAT_ROOM_MEMBER_LIMIT_EXCEEDED: '채팅방은 최대 100명까지 참여할 수 있습니다.',
  CHAT_MEMBER_NOT_FOUND: '추가할 수 없는 회원이 포함되어 있습니다.',
  CHAT_LAST_ADMIN_REQUIRED: '채팅방에는 관리자 1명 이상이 남아야 합니다.',
  CHAT_MEMBER_REQUIRED: '채팅방에 참여한 관리자만 메시지를 보낼 수 있습니다.',
  CHAT_MESSAGE_TOO_FAST: '메시지를 너무 빠르게 보내고 있습니다.',
  CHAT_MESSAGE_RATE_LIMITED: '잠시 후 다시 메시지를 보내주세요.',
  CHAT_MESSAGE_DUPLICATED: '동일한 메시지가 반복되었습니다.',
  CHAT_MESSAGE_INVALID: '메시지 내용을 확인해주세요.',
  CHAT_MESSAGE_NOT_FOUND: '메시지를 찾을 수 없습니다.',
  SUPABASE_NOT_CONFIGURED: 'Supabase 환경변수를 설정해주세요.',
};

function readErrorCode(error) {
  const values = [error?.message, error?.details, error?.hint]
    .filter(Boolean)
    .map(String);
  return Object.keys(ERROR_MESSAGES).find((code) => values.some((value) => value.includes(code)))
    || error?.code
    || 'REQUEST_FAILED';
}

export function normalizeError(error) {
  const code = readErrorCode(error);
  const normalized = new Error(ERROR_MESSAGES[code] || '요청을 완료하지 못했습니다. 다시 시도해주세요.');
  normalized.code = code;
  normalized.original = error;
  return normalized;
}

export async function callRpc(name, args = {}) {
  try {
    const { data, error } = await getSupabaseClient().rpc(name, args);
    if (error) throw error;
    return data;
  } catch (error) {
    throw normalizeError(error);
  }
}

export function createIdempotencyKey(prefix = 'admin') {
  const id = globalThis.crypto?.randomUUID?.() || `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  return `${prefix}:${id}`;
}
