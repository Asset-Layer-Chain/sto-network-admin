import { callRpc } from './rpcClient.js';
import { getSupabaseClient } from './supabaseClient.js';

function createClientMessageId() {
  try {
    if (globalThis.crypto?.randomUUID) {
      return globalThis.crypto.randomUUID();
    }
    if (globalThis.crypto?.getRandomValues) {
      const bytes = new Uint8Array(16);
      globalThis.crypto.getRandomValues(bytes);
      bytes[6] = (bytes[6] & 0x0f) | 0x40;
      bytes[8] = (bytes[8] & 0x3f) | 0x80;
      const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0'));
      return `${hex.slice(0, 4).join('')}-${hex.slice(4, 6).join('')}-${hex.slice(6, 8).join('')}-${hex.slice(8, 10).join('')}-${hex.slice(10, 16).join('')}`;
    }
  } catch {
    // Fall through to the timestamp fallback.
  }

  return `chat-${Date.now()}-${Math.random().toString(36).slice(2, 12)}`;
}

function normalizeChatMessage(message) {
  if (!message) return null;
  return {
    id: message.id,
    roomId: message.roomId ?? message.room_id,
    senderId: message.senderId ?? message.sender_id,
    senderName: message.senderName ?? message.sender_name,
    senderMemberId: message.senderMemberId ?? message.sender_member_id,
    senderAvatar: message.senderAvatar ?? message.sender_avatar,
    senderRole: message.senderRole ?? message.sender_role,
    clientMessageId: message.clientMessageId ?? message.client_message_id,
    content: message.content,
    deletedAt: message.deletedAt ?? message.deleted_at,
    createdAt: message.createdAt ?? message.created_at,
  };
}

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
  return Array.isArray(result) ? result.map(normalizeChatMessage).filter(Boolean) : [];
}

export async function getChatMessage(messageId) {
  return normalizeChatMessage(await callRpc('rpc_admin_get_chat_message', { p_message_id: messageId }));
}

export async function sendChatMessage({ roomId, content, clientMessageId = null }) {
  const resolvedClientMessageId = String(clientMessageId || createClientMessageId()).trim();

  const message = normalizeChatMessage(await callRpc('rpc_send_chat_message', {
    p_room_id: roomId,
    p_client_message_id: resolvedClientMessageId,
    p_content: content,
  }));
  if (!message?.id || message.senderRole) return message;
  try {
    return await getChatMessage(message.id);
  } catch {
    return message;
  }
}

export function markChatRoomRead(roomId, lastMessageId = null) {
  return callRpc('rpc_mark_chat_room_read', {
    p_room_id: roomId,
    p_last_message_id: lastMessageId,
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
        const fallback = normalizeChatMessage(payload?.new);
        if (fallback) onMessage?.(fallback);
      }
    })
    .subscribe((status) => onStatus?.(status));

  return () => supabase.removeChannel(channel);
}
