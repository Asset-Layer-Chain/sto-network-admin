export const env = {
  supabaseUrl: import.meta.env.VITE_SUPABASE_URL || '',
  supabaseAnonKey: import.meta.env.VITE_SUPABASE_ANON_KEY || '',
  webBaseUrl: import.meta.env.VITE_WEB_BASE_URL || '',
  authRedirectUrl: import.meta.env.VITE_SUPABASE_AUTH_REDIRECT_URL || '',
  appBasePath: import.meta.env.VITE_APP_BASE_PATH || '/',
};

export function isSupabaseConfigured() {
  return Boolean(env.supabaseUrl && env.supabaseAnonKey);
}

export function getBaseUrl() {
  const configured = String(env.webBaseUrl || '').trim().replace(/\/+$/, '');
  if (configured) return configured;
  return typeof window !== 'undefined' ? window.location.origin : '';
}

export function getAuthRedirectUrl() {
  return env.authRedirectUrl || `${getBaseUrl()}/auth/callback`;
}
