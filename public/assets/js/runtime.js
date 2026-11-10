import { loadScript } from './utils.js';

export function validateConfig(config) {
  if (!config || !/^https:\/\/[a-z0-9-]+\.supabase\.co\/?$/i.test(config.supabaseUrl || '') || /YOUR_/.test(config.supabaseUrl)) throw new Error('public/config.js에 Supabase Project URL을 입력하세요.');
  const key = config.supabaseAnonKey || '';
  let anon = false;
  try { anon = JSON.parse(atob(key.split('.')[1].replace(/-/g,'+').replace(/_/g,'/'))).role === 'anon'; } catch {}
  if (!key.startsWith('sb_publishable_') && !anon) throw new Error('config.js에는 공개용 Publishable key 또는 anon key만 입력하세요. 비밀키는 사용할 수 없습니다.');
  return config;
}

export async function initRuntime() {
  const config = validateConfig(window.FINANCE_CONFIG);
  const storeKey = 'finance_device_v2:' + new URL(config.supabaseUrl).hostname;
  let deviceToken = localStorage.getItem(storeKey);
  if (!/^[a-f0-9]{64}$/.test(deviceToken || '')) {
    deviceToken = Array.from(crypto.getRandomValues(new Uint8Array(32)), b => b.toString(16).padStart(2,'0')).join('');
    localStorage.setItem(storeKey, deviceToken);
  }
  if (!window.supabase?.createClient) await loadScript('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js','supabase');
  if (!window.supabase?.createClient) throw new Error('Supabase 연결 모듈을 불러오지 못했습니다. 인터넷 연결을 확인하세요.');
  const client = window.supabase.createClient(config.supabaseUrl, config.supabaseAnonKey, {
    auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true},
    global:{headers:{'x-device-token':deviceToken}}
  });
  return { mode:'supabase', client, config };
}

export async function callFunction(runtime, name, {body}={}) {
  const map = {'admin-users':'admin_users','full-backup':'export_finance_backup','restore-backup':'restore_finance_backup'};
  if (name === 'exchange-rates') {
    const res=await fetch('/api/exchange-rates',{cache:'no-store'});
    const data=await res.json(); if(!res.ok)throw new Error(data.error || '환율 조회 실패'); return data;
  }
  if(!map[name])throw new Error('지원하지 않는 요청입니다.');
  const args = name==='admin-users'?{p_payload:body||{action:'list'}}:name==='restore-backup'?{p_backup:body}:{};
  const {data,error}=await runtime.client.rpc(map[name],args);
  if(error)throw error;
  return data;
}

export function registerServiceWorker() {
  if ('serviceWorker' in navigator && location.protocol === 'https:') navigator.serviceWorker.register('/service-worker.js').catch(()=>{});
}
