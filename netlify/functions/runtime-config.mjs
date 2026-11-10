import { corsHeaders, env, response } from './_shared.mjs';

export async function handler(event) {
  const cors = corsHeaders(event);
  if (event.httpMethod === 'OPTIONS') return { statusCode: 204, headers: cors, body: '' };
  try {
    const { supabaseUrl, anonKey } = env();
    return response(200, {
      appName: process.env.APP_NAME || '창진에스씨 재무관리',
      supabaseUrl,
      supabaseAnonKey: anonKey,
      demoAllowed: process.env.DEMO_ALLOWED === 'true',
    }, cors);
  } catch (error) {
    return response(500, { error: error.message }, cors);
  }
}
