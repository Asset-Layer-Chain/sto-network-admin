import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  addChatMembers,
  getChatMessages,
  getChatRoom,
  joinChatRoom,
  markChatRoomRead,
  removeChatMembers,
  sendChatMessage,
  subscribeToChatMessages,
  updateChatRoom,
} from '../api/adminChatApi.js';
import { AdminLayout } from '../components/AdminLayout.jsx';
import { Badge, Button, Card, EmptyState, Input, Loading, Modal, PageHeader, Textarea } from '../components/Common.jsx';
import { MemberPicker } from '../components/MemberPicker.jsx';
import { useToast } from '../components/Toast.jsx';
import { navigate } from '../router.js';
import { formatDateTime } from '../utils/format.js';

function mergeMessage(messages, incoming) {
  if (!incoming?.id) return messages;
  const index = messages.findIndex((item) => String(item.id) === String(incoming.id));
  if (index < 0) return [...messages, incoming];

  const merged = { ...messages[index] };
  Object.entries(incoming).forEach(([key, value]) => {
    if (value !== undefined) merged[key] = value;
  });
  const next = [...messages];
  next[index] = merged;
  return next;
}

function roomWithLatestMessage(room, message) {
  if (!room || !message) return room;
  return {
    ...room,
    lastMessageId: message.id ?? room.lastMessageId,
    lastMessagePreview: message.deletedAt ? '삭제된 메시지입니다.' : (message.content ?? room.lastMessagePreview),
    lastMessageAt: message.createdAt ?? room.lastMessageAt,
  };
}

export function ChatRoomDetailPage({ roomId }) {
  const [room, setRoom] = useState(null);
  const [messages, setMessages] = useState([]);
  const [loading, setLoading] = useState(true);
  const [loadingOlder, setLoadingOlder] = useState(false);
  const [error, setError] = useState('');
  const [content, setContent] = useState('');
  const [sending, setSending] = useState(false);
  const [realtimeStatus, setRealtimeStatus] = useState('CLOSED');
  const [addOpen, setAddOpen] = useState(false);
  const [selectedToAdd, setSelectedToAdd] = useState([]);
  const [removeOpen, setRemoveOpen] = useState(false);
  const [selectedToRemove, setSelectedToRemove] = useState([]);
  const [removeReason, setRemoveReason] = useState('');
  const [editOpen, setEditOpen] = useState(false);
  const [editTitle, setEditTitle] = useState('');
  const [modalError, setModalError] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const messageEndRef = useRef(null);
  const roomRef = useRef(null);
  const markReadTimerRef = useRef(null);
  const { showToast } = useToast();

  const commitRoom = useCallback((nextRoom) => {
    roomRef.current = nextRoom;
    setRoom(nextRoom);
    setEditTitle(nextRoom?.title || '');
    return nextRoom;
  }, []);


  const scheduleMarkRead = useCallback((lastMessageId = null) => {
    if (document.visibilityState !== 'visible' || !roomRef.current?.currentAdminActive) return;
    window.clearTimeout(markReadTimerRef.current);
    markReadTimerRef.current = window.setTimeout(() => {
      markChatRoomRead(roomId, lastMessageId).catch(() => {});
    }, 700);
  }, [roomId]);

  const applyLatestMessage = useCallback((message) => {
    setMessages((previous) => mergeMessage(previous, message));
    setRoom((previous) => {
      const next = roomWithLatestMessage(previous, message);
      roomRef.current = next;
      return next;
    });
    scheduleMarkRead(message?.id || null);
  }, [scheduleMarkRead]);

  const load = useCallback(async () => {
    setLoading(true);
    setError('');
    try {
      const [nextRoom, nextMessages] = await Promise.all([
        getChatRoom(roomId),
        getChatMessages({ roomId, limit: 50 }),
      ]);
      commitRoom(nextRoom);
      setMessages(nextMessages);
      const latestMessageId = nextMessages.at(-1)?.id ?? nextRoom?.lastMessageId ?? null;
      scheduleMarkRead(latestMessageId);
      window.setTimeout(() => messageEndRef.current?.scrollIntoView({ block: 'end' }), 30);
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setLoading(false);
    }
  }, [commitRoom, roomId, scheduleMarkRead]);

  useEffect(() => { load(); }, [load]);

  useEffect(() => subscribeToChatMessages(roomId, (message) => {
    applyLatestMessage(message);
    window.setTimeout(() => messageEndRef.current?.scrollIntoView({ behavior: 'smooth', block: 'end' }), 30);
  }, setRealtimeStatus), [applyLatestMessage, roomId]);

  useEffect(() => {
    const handleVisibility = () => {
      if (document.visibilityState === 'visible') {
        scheduleMarkRead(roomRef.current?.lastMessageId || null);
      }
    };
    document.addEventListener('visibilitychange', handleVisibility);
    return () => {
      document.removeEventListener('visibilitychange', handleVisibility);
      window.clearTimeout(markReadTimerRef.current);
    };
  }, [scheduleMarkRead]);


  const loadOlder = async () => {
    if (!messages.length) return;
    setLoadingOlder(true);
    try {
      const older = await getChatMessages({ roomId, beforeMessageId: messages[0].id, limit: 50 });
      setMessages((previous) => [...older.filter((item) => !previous.some((current) => String(current.id) === String(item.id))), ...previous]);
    } catch (requestError) {
      showToast(requestError.message, 'error');
    } finally {
      setLoadingOlder(false);
    }
  };

  const send = async (event) => {
    event.preventDefault();
    const normalized = content.trim();
    if (!normalized || sending) return;
    setSending(true);
    try {
      if (!roomRef.current?.currentAdminActive) {
        commitRoom(await joinChatRoom(roomId));
      }
      const message = await sendChatMessage({ roomId, content: normalized });
      applyLatestMessage(message);
      setContent('');
      window.setTimeout(() => messageEndRef.current?.scrollIntoView({ behavior: 'smooth', block: 'end' }), 30);
    } catch (requestError) {
      showToast(requestError.message, 'error');
    } finally {
      setSending(false);
    }
  };

  const addMembers = async () => {
    if (!selectedToAdd.length) return;
    setSubmitting(true);
    setModalError('');
    try {
      commitRoom(await addChatMembers({ roomId, memberIds: selectedToAdd.map((member) => member.userId) }));
      showToast(`${selectedToAdd.length}명이 추가되었습니다.`);
      setAddOpen(false);
      setSelectedToAdd([]);
    } catch (requestError) {
      setModalError(requestError.message);
    } finally {
      setSubmitting(false);
    }
  };

  const removeMembers = async () => {
    if (!selectedToRemove.length) return;
    setSubmitting(true);
    setModalError('');
    try {
      commitRoom(await removeChatMembers({ roomId, memberIds: selectedToRemove, reason: removeReason }));
      showToast(`${selectedToRemove.length}명이 제외되었습니다.`);
      setRemoveOpen(false);
      setSelectedToRemove([]);
      setRemoveReason('');
    } catch (requestError) {
      setModalError(requestError.message);
    } finally {
      setSubmitting(false);
    }
  };

  const saveTitle = async () => {
    if (editTitle.trim().length < 2) {
      setModalError('제목을 2자 이상 입력해주세요.');
      return;
    }
    setSubmitting(true);
    setModalError('');
    try {
      commitRoom(await updateChatRoom({ roomId, title: editTitle.trim() }));
      showToast('채팅방 제목이 변경되었습니다.');
      setEditOpen(false);
    } catch (requestError) {
      setModalError(requestError.message);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <AdminLayout active="chats">
      <PageHeader title={room?.title || '채팅방 상세'} description={roomId} actions={<><Button variant="secondary" onClick={() => navigate('/chats')}>목록</Button><Button variant="secondary" onClick={() => setEditOpen(true)}>제목 변경</Button><Button onClick={() => setAddOpen(true)} disabled={(room?.memberCount || 0) >= 100}>회원 추가</Button><Button variant="danger" onClick={() => setRemoveOpen(true)}>회원 제외</Button></>} />
      {loading ? <Loading /> : null}
      {!loading && error ? <EmptyState title={error} /> : null}
      {!loading && room ? (
        <div className="chat-admin-grid">
          <Card className="chat-card">
            <div className="chat-status-row"><span>{room.memberCount} / 100명</span><Badge tone={realtimeStatus === 'SUBSCRIBED' ? 'success' : 'neutral'}>Realtime {realtimeStatus}</Badge>{!room.currentAdminActive ? <Badge tone="warning">메시지 전송 시 관리자 참여</Badge> : null}</div>
            <div className="chat-message-list">
              <div className="load-older"><Button variant="ghost" size="sm" onClick={loadOlder} disabled={loadingOlder}>{loadingOlder ? '불러오는 중' : '이전 메시지 50개'}</Button></div>
              {!messages.length ? <EmptyState title="메시지가 없습니다." /> : messages.map((message) => (
                <div key={message.id} className={`chat-message ${message.senderRole === 'admin' || message.senderRole === 'super_admin' ? 'admin-message' : ''}`}>
                  <div className="chat-avatar">{String(message.senderName || 'S').slice(0, 1)}</div>
                  <div><div className="chat-message-meta"><strong>{message.senderName}</strong>{message.senderRole && message.senderRole !== 'user' ? <Badge tone="info">{message.senderRole}</Badge> : null}<span>{formatDateTime(message.createdAt)}</span></div><p>{message.deletedAt ? '삭제된 메시지입니다.' : message.content}</p></div>
                </div>
              ))}
              <div ref={messageEndRef} />
            </div>
            <form className="chat-composer" onSubmit={send}><textarea value={content} onChange={(e) => setContent(e.target.value)} maxLength="1000" placeholder="메시지를 입력하세요." onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); e.currentTarget.form?.requestSubmit(); } }} /><Button type="submit" disabled={sending || !content.trim()}>{sending ? '전송 중' : '전송'}</Button></form>
          </Card>
          <Card title={`참여 회원 (${room.memberCount}/100)`} className="chat-members-card">
            <div className="chat-member-list">{room.members.map((member) => (
              <label key={member.userId} className="chat-member-item"><input type="checkbox" checked={selectedToRemove.includes(member.userId)} onChange={(e) => setSelectedToRemove((previous) => e.target.checked ? [...previous, member.userId] : previous.filter((id) => id !== member.userId))} /><span className="member-avatar">{String(member.name || member.memberId).slice(0, 1)}</span><span><strong>{member.name}</strong><small>{member.memberId}</small></span><Badge tone={member.chatRole === 'admin' ? 'info' : 'neutral'}>{member.chatRole}</Badge></label>
            ))}</div>
          </Card>
        </div>
      ) : null}

      <Modal open={addOpen} title="채팅방 회원 추가" width="720px" onClose={() => !submitting && setAddOpen(false)} footer={<><Button variant="secondary" onClick={() => setAddOpen(false)}>취소</Button><Button onClick={addMembers} disabled={submitting || !selectedToAdd.length}>선택 {selectedToAdd.length}명 추가</Button></>}><MemberPicker selected={selectedToAdd} onChange={setSelectedToAdd} excludeRoomId={roomId} max={Math.max(0, 100 - (room?.memberCount || 0))} />{modalError ? <p className="form-error">{modalError}</p> : null}</Modal>
      <Modal open={removeOpen} title="채팅방 회원 제외" onClose={() => !submitting && setRemoveOpen(false)} footer={<><Button variant="secondary" onClick={() => setRemoveOpen(false)}>취소</Button><Button variant="danger" onClick={removeMembers} disabled={submitting || !selectedToRemove.length}>선택 {selectedToRemove.length}명 제외</Button></>}><p className="modal-description">오른쪽 참여 회원 목록에서 제외 대상을 선택하세요. 마지막 채팅방 관리자는 제외할 수 없습니다.</p><Textarea label="제외 사유" value={removeReason} onChange={(e) => setRemoveReason(e.target.value)} rows="3" maxLength="300" />{modalError ? <p className="form-error">{modalError}</p> : null}</Modal>
      <Modal open={editOpen} title="채팅방 제목 변경" onClose={() => !submitting && setEditOpen(false)} footer={<><Button variant="secondary" onClick={() => setEditOpen(false)}>취소</Button><Button onClick={saveTitle} disabled={submitting}>저장</Button></>}><Input label="제목" value={editTitle} onChange={(e) => setEditTitle(e.target.value)} maxLength="80" />{modalError ? <p className="form-error">{modalError}</p> : null}</Modal>
    </AdminLayout>
  );
}
