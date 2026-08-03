import { createClient } from '@supabase/supabase-js';
import { env, isSupabaseConfigured } from '../config/env.js';

let client = null;

export function getSupabaseClient() {
  if (!isSupabaseConfigured()) {
    throw new Error('SUPABASE_NOT_CONFIGURED');
  }

  if (!client) {
    client = createClient(env.supabaseUrl, env.supabaseAnonKey, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
        flowType: 'pkce',
      },
      realtime: {
        params: { eventsPerSecond: 10 },
      },
    });
  }

  return client;
}
