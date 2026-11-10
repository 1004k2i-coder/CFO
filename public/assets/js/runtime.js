import { loadScript } from './utils.js';

export async function initRuntime() {
  const demo = new URLSearchParams(location.search).get('demo') === '1';
  if (demo) return { mode:'demo', client:null, config:{appName:'창진에스씨 재무관리 데모'} };
  const res = await fetch('/api/runtime-config',{cache:'no-store'});
  if (!res.ok) throw new Error('운영 환경설정을 불러오지 못했습니다. Netlify 환경변수를 확인하세요.');
  const config = await res.json();
  if (!window.supabase?.createClient) await loadScript('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js','supabase');
  if (!window.supabase?.createClient) throw new Error('Supabase 라이브러리를 불러오지 못했습니다.');
  const client = window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey, {
    auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true},
  });
  return { mode:'supabase', client, config };
}

export async function callFunction(runtime, name, {method='POST', body, headers={}}={}) {
  if (runtime.mode === 'demo') throw new Error('데모 모드에서는 서버 관리 기능을 실행할 수 없습니다.');
  const {data:{session}} = await runtime.client.auth.getSession();
  const res=await fetch(`/api/${name}`,{
    method,
    headers:{
      ...(session?.access_token?{Authorization:`Bearer ${session.access_token}`} : {}),
      ...(body!==undefined?{'content-type':'application/json'}:{}),
      ...headers,
    },
    body:body===undefined?undefined:JSON.stringify(body),
  });
  const text=await res.text(); let data;
  try{data=text?JSON.parse(text):null}catch{data=text}
  if(!res.ok) throw new Error(data?.error||data?.message||String(data)||`서버 오류 ${res.status}`);
  return data;
}

export function registerServiceWorker() {
  if ('serviceWorker' in navigator && location.protocol === 'https:') {
    navigator.serviceWorker.register('/service-worker.js').catch(err=>console.warn('Service worker registration failed',err));
  }
}
