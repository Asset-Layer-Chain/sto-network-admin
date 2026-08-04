import React from 'react';
import { useAuth } from '../auth/AuthContext.jsx';
import { navigate } from '../router.js';
import { Button, StatusBadge } from './Common.jsx';

const menus = [
  { path: '/members', label: '회원 관리', key: 'members' },
  { path: '/transactions', label: '거래 내역', key: 'transactions' },
  { path: '/transaction-reasons', label: '처리 사유', key: 'reason-presets', permission: 'reasonPresetManage' },
  { path: '/chats', label: '채팅 관리', key: 'chats' },
  { path: '/admin-logs', label: '관리자 로그', key: 'admin-logs' },
];

export function AdminLayout({ active, children }) {
  const { admin, signOut } = useAuth();

  return (
    <div className="admin-shell">
      <aside className="sidebar">
        <div className="brand" onClick={() => navigate('/members')} role="button" tabIndex={0}>
          <span className="brand-mark">S</span>
          <div><strong>STO Network</strong><small>Product Admin</small></div>
        </div>
        <nav className="sidebar-nav">
          {menus.filter((menu) => !menu.permission || admin?.permissions?.[menu.permission]).map((menu) => (
            <button key={menu.key} className={active === menu.key ? 'active' : ''} onClick={() => navigate(menu.path)}>
              {menu.label}
            </button>
          ))}
        </nav>
        <div className="sidebar-user">
          <div><strong>{admin?.name || admin?.mbName || admin?.memberId || '관리자'}</strong><StatusBadge value={admin?.role} /></div>
          <div className="sidebar-grade">{admin?.adminGrade ? <StatusBadge value={admin.adminGrade} /> : <span>자산 권한 미설정</span>}</div>
          <small>{admin?.email || admin?.mbEmail || ''}</small>
          <Button variant="ghost" size="sm" onClick={signOut}>로그아웃</Button>
        </div>
      </aside>
      <main className="main-content">{children}</main>
    </div>
  );
}
