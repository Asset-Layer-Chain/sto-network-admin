import React, { useEffect, useMemo, useState } from 'react';
import { searchMembers } from '../api/adminMemberApi.js';
import { useAuth } from '../auth/AuthContext.jsx';
import { useDebouncedValue } from '../utils/hooks.js';
import { Badge, EmptyState, Input, Loading } from './Common.jsx';

export function MemberPicker({ selected = [], onChange, excludeRoomId = null, max = 99 }) {
  const { admin } = useAuth();
  const searchOnly = admin?.permissions?.memberListBrowse === false;
  const [search, setSearch] = useState('');
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const debounced = useDebouncedValue(search, 250);
  const selectedIds = useMemo(() => new Set(selected.map((item) => item.userId)), [selected]);

  useEffect(() => {
    let active = true;
    const query = debounced.trim();

    setError('');
    if (searchOnly && !query) {
      setItems([]);
      setLoading(false);
      return () => { active = false; };
    }

    setLoading(true);
    searchMembers(query, { limit: searchOnly ? 20 : 40, excludeRoomId })
      .then((data) => active && setItems(data))
      .catch((requestError) => active && setError(requestError.message))
      .finally(() => active && setLoading(false));
    return () => { active = false; };
  }, [debounced, excludeRoomId, searchOnly]);

  const toggle = (member) => {
    if (selectedIds.has(member.userId)) {
      onChange(selected.filter((item) => item.userId !== member.userId));
      return;
    }
    if (selected.length >= max) return;
    onChange([...selected, member]);
  };

  return (
    <div className="member-picker">
      <Input value={search} onChange={(e) => setSearch(e.target.value)} placeholder={searchOnly ? '정확한 회원 ID, 이름, 이메일, 전화번호 검색' : '아이디, 이름, 이메일, 전화번호 검색'} />
      {selected.length ? (
        <div className="selected-members">
          {selected.map((member) => (
            <button key={member.userId} onClick={() => toggle(member)}>
              {member.name || member.memberId}<span>×</span>
            </button>
          ))}
        </div>
      ) : null}
      <div className="member-picker-list">
        {loading ? <Loading label="회원 검색 중" /> : null}
        {!loading && error ? <EmptyState title={error} /> : null}
        {!loading && !error && searchOnly && !debounced.trim() ? <EmptyState title="회원 검색이 필요합니다." /> : null}
        {!loading && !error && (!searchOnly || debounced.trim()) && !items.length ? <EmptyState title="검색된 회원이 없습니다." /> : null}
        {!loading && items.map((member) => (
          <label key={member.userId} className="member-picker-item">
            <input type="checkbox" checked={selectedIds.has(member.userId)} onChange={() => toggle(member)} disabled={!selectedIds.has(member.userId) && selected.length >= max} />
            <span className="member-avatar">{String(member.name || member.memberId || 'S').slice(0, 1)}</span>
            <span className="member-picker-info">
              <strong>{member.name || '-'}</strong>
              <small>{member.memberId} · {member.email || '-'}</small>
            </span>
            {member.role !== 'user' ? <Badge tone="info">{member.role}</Badge> : null}
          </label>
        ))}
      </div>
      <small className="helper-text">선택 {selected.length}명 / 최대 {max}명</small>
    </div>
  );
}
