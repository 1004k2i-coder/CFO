const JSON_HEADERS = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store',
};

export function response(statusCode, body, extraHeaders = {}) {
  return {
    statusCode,
    headers: { ...JSON_HEADERS, ...extraHeaders },
    body: JSON.stringify(body),
  };
}

export function corsHeaders(event) {
  const allowed = (process.env.ALLOWED_ORIGINS || '').split(',').map(v => v.trim()).filter(Boolean);
  const origin = event.headers?.origin || event.headers?.Origin || '';
  const allowOrigin = allowed.length === 0 || allowed.includes(origin) ? (origin || '*') : allowed[0];
  return {
    'access-control-allow-origin': allowOrigin,
    'access-control-allow-headers': 'authorization,content-type,x-confirm-restore',
    'access-control-allow-methods': 'GET,POST,PUT,PATCH,DELETE,OPTIONS',
    'vary': 'Origin',
  };
}

export function env() {
  const supabaseUrl = process.env.SUPABASE_URL;
  const anonKey = process.env.SUPABASE_ANON_KEY;
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabaseUrl || !anonKey) throw new Error('SUPABASE_URL and SUPABASE_ANON_KEY are required.');
  return { supabaseUrl: supabaseUrl.replace(/\/$/, ''), anonKey, serviceKey };
}

export async function verifyUser(event, { roles = [] } = {}) {
  const { supabaseUrl, anonKey, serviceKey } = env();
  const auth = event.headers?.authorization || event.headers?.Authorization || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  if (!token) throw Object.assign(new Error('로그인이 필요합니다.'), { statusCode: 401 });

  const userRes = await fetch(`${supabaseUrl}/auth/v1/user`, {
    headers: { apikey: anonKey, Authorization: `Bearer ${token}` },
  });
  if (!userRes.ok) throw Object.assign(new Error('유효하지 않은 로그인입니다.'), { statusCode: 401 });
  const user = await userRes.json();

  const profileRes = await fetch(`${supabaseUrl}/rest/v1/profiles?id=eq.${encodeURIComponent(user.id)}&select=*`, {
    headers: serviceHeaders(serviceKey),
  });
  if (!profileRes.ok) throw Object.assign(new Error('사용자 프로필을 확인할 수 없습니다.'), { statusCode: 403 });
  const profiles = await profileRes.json();
  const profile = profiles[0];
  if (!profile?.active) throw Object.assign(new Error('비활성 사용자입니다.'), { statusCode: 403 });
  if (roles.length && !roles.includes(profile.role)) {
    throw Object.assign(new Error('요청 권한이 없습니다.'), { statusCode: 403 });
  }
  return { user, profile, token };
}

export function serviceHeaders(serviceKey, prefer = '') {
  if (!serviceKey) throw new Error('SUPABASE_SERVICE_ROLE_KEY is required for this function.');
  return {
    apikey: serviceKey,
    Authorization: `Bearer ${serviceKey}`,
    'content-type': 'application/json',
    ...(prefer ? { Prefer: prefer } : {}),
  };
}

export async function rest(path, { method = 'GET', body, prefer = '', query = '' } = {}) {
  const { supabaseUrl, serviceKey } = env();
  const url = `${supabaseUrl}/rest/v1/${path}${query}`;
  const res = await fetch(url, {
    method,
    headers: serviceHeaders(serviceKey, prefer),
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  if (!res.ok) {
    const msg = typeof data === 'object' ? (data.message || data.error_description || JSON.stringify(data)) : String(data);
    throw Object.assign(new Error(msg), { statusCode: res.status });
  }
  return data;
}

export function parseBody(event) {
  if (!event.body) return {};
  try { return JSON.parse(event.body); } catch {
    throw Object.assign(new Error('요청 본문이 올바른 JSON이 아닙니다.'), { statusCode: 400 });
  }
}

export function safeName(value = '') {
  return String(value).replace(/[^a-zA-Z0-9가-힣._-]/g, '_').slice(0, 120);
}
