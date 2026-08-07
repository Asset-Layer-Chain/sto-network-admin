import React, { useEffect } from 'react';
import { useAuth } from './auth/AuthContext.jsx';
import { Button, Loading } from './components/Common.jsx';
import { LoginPage } from './pages/LoginPage.jsx';
import { MemberListPage } from './pages/MemberListPage.jsx';
import { MemberDetailPage } from './pages/MemberDetailPage.jsx';
import { TransactionListPage } from './pages/TransactionListPage.jsx';
import { ChatRoomListPage } from './pages/ChatRoomListPage.jsx';
import { ChatRoomDetailPage } from './pages/ChatRoomDetailPage.jsx';
import { AdminLogPage } from './pages/AdminLogPage.jsx';
import { ReasonPresetPage } from './pages/ReasonPresetPage.jsx';
import { BulkPosDepositPage } from './pages/BulkPosDepositPage.jsx';
import { navigate, useLocation } from './router.js';

function AccessDenied() {
  const { signOut } = useAuth();
  return <div className="center-page"><div className="center-card"><span className="brand-mark">S</span><h1>접근 권한이 없습니다.</h1><p>member.role이 admin 또는 super_admin인 계정만 사용할 수 있습니다.</p><Button onClick={signOut}>다른 계정으로 로그인</Button></div></div>;
}

function NotFound() {
  return <div className="center-page"><div className="center-card"><h1>페이지를 찾을 수 없습니다.</h1><Button onClick={() => navigate('/members')}>회원 관리로 이동</Button></div></div>;
}

export function App() {
  const { pathname } = useLocation();
  const { loading, session, admin, accessDenied } = useAuth();

  useEffect(() => {
    if (pathname === '/auth/callback' && admin) navigate('/members', { replace: true });
    if (pathname === '/' && admin) navigate('/members', { replace: true });
  }, [pathname, admin]);

  if (loading) return <div className="center-page"><Loading label="관리자 세션을 확인하는 중입니다." /></div>;
  if (accessDenied) return <AccessDenied />;
  if (!session || !admin) return <LoginPage />;
  if (pathname === '/' || pathname === '/auth/callback') return <div className="center-page"><Loading /></div>;
  if (pathname === '/members') return <MemberListPage />;
  if (pathname === '/transactions') return <TransactionListPage />;
  if (pathname === '/transaction-reasons') return <ReasonPresetPage />;
  if (pathname === '/bulk-pos-deposit') return <BulkPosDepositPage />;
  if (pathname === '/chats') return <ChatRoomListPage />;
  if (pathname === '/admin-logs') return <AdminLogPage />;

  const memberMatch = pathname.match(/^\/members\/([0-9a-f-]{36})$/i);
  if (memberMatch) return <MemberDetailPage userId={memberMatch[1]} />;
  const chatMatch = pathname.match(/^\/chats\/([0-9a-f-]{36})$/i);
  if (chatMatch) return <ChatRoomDetailPage roomId={chatMatch[1]} />;

  return <NotFound />;
}
