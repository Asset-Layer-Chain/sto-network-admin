import { callRpc } from './rpcClient.js';
import { getSupabaseClient } from './supabaseClient.js';

export async function listChatRooms(filters = {}) {
  const result = await callRpc('rpc_admin_list_chat_rooms', {
    p_search: filters.search || null,
    p_page: Number(filters.page || 1),
    p_page_size: Number(filters.pageSize || 30),
  });
  return {
    items: Array.isArray(result?.items) ? result.items : [],
    page: Number(result?.page || 1),
    pageSize: Number(result?.pageSize || result?.page_size || 30),
    totalCount: Number(result?.totalCount || result?.total_count || 0),
  };
}

export function getChatRoom(roomId) {
  return callRpc('rpc_admin_get_chat_room', { p_room_id: roomId });
}

export function createChatRoom({ title, memberIds }) {
  return callRpc('rpc_admin_create_chat_room', {
    p_title: title,
    p_member_ids: memberIds,
  });
}

export function updateChatRoom({ roomId, title }) {
  return callRpc('rpc_admin_update_chat_room', {
    p_room_id: roomId,
    p_title: title,
  });
}

export function addChatMembers({ roomId, memberIds }) {
  return callRpc('rpc_admin_add_chat_members', {
    p_room_id: roomId,
    p_member_ids: memberIds,
  });
}

export function removeChatMembers({ roomId, memberIds, reason }) {
  return callRpc('rpc_admin_remove_chat_members', {
    p_room_id: roomId,
    p_member_ids: memberIds,
    p_reason: reason || null,
  });
}

export function joinChatRoom(roomId) {
  return callRpc('rpc_admin_join_chat_room', { p_room_id: roomId });
}

export async function getChatMessages({ roomId, beforeMessageId = null, limit = 50 }) {
  const result = await callRpc('rpc_admin_get_chat_messages', {
    p_room_id: roomId,
    p_before_message_id: beforeMessageId,
    p_limit: limit,
  });
  return Array.isArray(result) ? result : [];
}

export function getChatMessage(messageId) {
  return callRpc('rpc_admin_get_chat_message', { p_message_id: messageId });
}

export function sendChatMessage({ roomId, content, clientMessageId = null }) {
  return callRpc('rpc_send_chat_message', {
    p_room_id: roomId,
    p_client_message_id: clientMessageId || globalThis.crypto?.randomUUID?.(),
    p_content: content,
  });
}

export function subscribeToChatMessages(roomId, onMessage, onStatus) {
  const supabase = getSupabaseClient();
  const channel = supabase
    .channel(`admin-chat-room:${roomId}`)
    .on('postgres_changes', {
      event: 'INSERT',
      schema: 'public',
      table: 'chat_messages',
      filter: `room_id=eq.${roomId}`,
    }, async (payload) => {
      try {
        const message = await getChatMessage(payload?.new?.id);
        if (message) onMessage?.(message);
      } catch {
        if (payload?.new) onMessage?.(payload.new);
      }
    })
    .subscribe((status) => onStatus?.(status));

  return () => supabase.removeChannel(channel);
}
