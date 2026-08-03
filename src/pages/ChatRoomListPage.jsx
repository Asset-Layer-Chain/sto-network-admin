import React, { useCallback, useEffect, useState } from 'react';
import { createChatRoom, listChatRooms } from '../api/adminChatApi.js';
import { AdminLayout } from '../components/AdminLayout.jsx';
import { Button, Card, EmptyState, Input, Loading, Modal, PageHeader, Pagination } from '../components/Common.jsx';
import { MemberPicker } from '../components/MemberPicker.jsx';
import { useToast } from '../components/Toast.jsx';
import { navigate } from '../router.js';
import { formatDateTime } from '../utils/format.js';

export function ChatRoomListPage() {
  const [search, setSearch] = useState('');
  const [applied, setApplied] = useState({ search: '', page: 1, pageSize: 30 });
  const [result, setResult] = useState({ items: [], totalCount: 0, page: 1, pageSize: 30 });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [createOpen, setCreateOpen] = useState(false);
  const [title, setTitle] = useState('');
  const [selected, setSelected] = useState([]);
  const [submitting, setSubmitting] = useState(false);
  const [formError, setFormError] = useState('');
  const { showToast } = useToast();

  const load = useCallback(async () => {
    setLoading(true); setError('');
    try { setResult(await listChatRooms(applied)); }
    catch (requestError) { setError(requestError.message); }
    finally { setLoading(false); }
  }, [applied]);
  useEffect(() => { load(); }, [load]);

  const create = async () => {
    if (title.trim().length < 2) { setFormError('채팅방 제목을 2자 이상 입력해주세요.'); return; }
    if (!selected.length) { setFormError('관리자 외 참여 회원을 1명 이상 선택해주세요.'); return; }
    setSubmitting(true); setFormError('');
    try {
      const room = await createChatRoom({ title: title.trim(), memberIds: selected.map((member) => member.userId) });
      showToast('채팅방이 생성되었습니다.');
      setCreateOpen(false); setTitle(''); setSelected([]);
      navigate(`/chats/${room.roomId || room.id}`);
    } catch (requestError) { setFormError(requestError.message); }
    finally { setSubmitting(false); }
  };

  const changePage = (page) => setApplied((prev) => ({ ...prev, page }));

  return (
    <AdminLayout active="chats">
      <PageHeader title="채팅 관리" description="그룹 채팅방을 생성하고 최대 100명의 참여자를 관리합니다." actions={<Button onClick={() => setCreateOpen(true)}>새 채팅방</Button>} />
      <Card><form className="toolbar" onSubmit={(e) => { e.preventDefault(); setApplied((prev) => ({ ...prev, search, page: 1 })); }}><Input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="방 제목, 방 UUID 검색" /><Button type="submit">조회</Button></form></Card>
      <Card className="table-card">
        {loading ? <Loading /> : null}
        {!loading && error ? <EmptyState title={error} /> : null}
        {!loading && !error && !result.items.length ? <EmptyState title="생성된 그룹 채팅방이 없습니다." /> : null}
        {!loading && !error && result.items.length ? <div className="table-wrap"><table><thead><tr><th>채팅방</th><th>참여 인원</th><th>최근 메시지</th><th>최근 활동</th><th>생성자</th><th>생성일</th></tr></thead><tbody>{result.items.map((room) => <tr key={room.roomId} className="clickable-row" onClick={() => navigate(`/chats/${room.roomId}`)}><td><strong>{room.title}</strong><small>{room.roomId}</small></td><td><strong>{room.memberCount} / 100</strong></td><td>{room.lastMessagePreview || '-'}</td><td>{formatDateTime(room.lastMessageAt)}</td><td>{room.createdBy?.memberId || '-'}</td><td>{formatDateTime(room.createdAt)}</td></tr>)}</tbody></table></div> : null}
        <Pagination page={result.page} pageSize={result.pageSize} totalCount={result.totalCount} onChange={changePage} />
      </Card>
      <Modal open={createOpen} title="그룹 채팅방 생성" width="720px" onClose={() => !submitting && setCreateOpen(false)} footer={<><Button variant="secondary" onClick={() => setCreateOpen(false)} disabled={submitting}>취소</Button><Button onClick={create} disabled={submitting}>{submitting ? '생성 중' : `채팅방 생성 (${selected.length + 1}/100)`}</Button></>}>
        <Input label="채팅방 제목" value={title} maxLength="80" onChange={(e) => setTitle(e.target.value)} placeholder="운영 공지방" />
        <div className="field"><span className="field-label">참여 회원</span><MemberPicker selected={selected} onChange={setSelected} max={99} /></div>
        {formError ? <p className="form-error">{formError}</p> : null}
      </Modal>
    </AdminLayout>
  );
}
