import { callRpc } from './rpcClient.js';

function normalizeValidationResult(result) {
  return {
    batch: result?.batch || null,
    items: Array.isArray(result?.items) ? result.items : [],
    summary: result?.summary || {},
    canExecute: Boolean(result?.canExecute ?? result?.can_execute),
    confirmText: result?.confirmText || result?.confirm_text || '',
  };
}

export async function validateBulkPosDeposit({ fileName, fileHash, rows }) {
  const result = await callRpc('rpc_admin_validate_bulk_pos_deposit', {
    p_file_name: fileName,
    p_file_hash: fileHash,
    p_rows: rows,
  });
  return normalizeValidationResult(result);
}

export async function executeBulkPosDeposit({ batchId, confirmText }) {
  const result = await callRpc('rpc_admin_execute_bulk_pos_deposit', {
    p_batch_id: batchId,
    p_confirm_text: confirmText,
  });
  return {
    batch: result?.batch || null,
    items: Array.isArray(result?.items) ? result.items : [],
    summary: result?.summary || {},
  };
}
