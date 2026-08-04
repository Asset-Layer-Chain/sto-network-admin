import { callRpc } from './rpcClient.js';

function normalizePreset(item = {}) {
  return {
    id: item.id,
    action: item.action,
    label: item.label,
    reasonText: item.reasonText || item.reason_text || '',
    sortOrder: Number(item.sortOrder ?? item.sort_order ?? 0),
    isDefault: Boolean(item.isDefault ?? item.is_default),
    isActive: item.isActive ?? item.is_active ?? true,
    createdAt: item.createdAt || item.created_at || null,
    updatedAt: item.updatedAt || item.updated_at || null,
    createdBy: item.createdBy || item.created_by || null,
    updatedBy: item.updatedBy || item.updated_by || null,
  };
}

export async function listReasonPresets({ action = null, includeInactive = false } = {}) {
  const result = await callRpc('rpc_admin_list_transaction_reason_presets', {
    p_action: action || null,
    p_include_inactive: Boolean(includeInactive),
  });
  return Array.isArray(result) ? result.map(normalizePreset) : [];
}

export async function createReasonPreset({ action, label, reasonText, sortOrder = 0, isDefault = false }) {
  const result = await callRpc('rpc_admin_create_transaction_reason_preset', {
    p_action: action,
    p_label: label,
    p_reason_text: reasonText,
    p_sort_order: Number(sortOrder || 0),
    p_is_default: Boolean(isDefault),
  });
  return normalizePreset(result);
}

export async function updateReasonPreset({ id, action, label, reasonText, sortOrder = 0, isDefault = false, isActive = true }) {
  const result = await callRpc('rpc_admin_update_transaction_reason_preset', {
    p_id: id,
    p_action: action,
    p_label: label,
    p_reason_text: reasonText,
    p_sort_order: Number(sortOrder || 0),
    p_is_default: Boolean(isDefault),
    p_is_active: Boolean(isActive),
  });
  return normalizePreset(result);
}

export async function deleteReasonPreset(id) {
  const result = await callRpc('rpc_admin_delete_transaction_reason_preset', { p_id: id });
  return normalizePreset(result);
}
