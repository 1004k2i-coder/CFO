const CACHE='changjin-finance-shell-v1';
const SHELL=['/','/index.html','/assets/app.css','/assets/js/app.js','/assets/js/utils.js','/assets/js/runtime.js','/assets/js/api.js','/assets/js/excel.js','/assets/js/finance.js','/assets/js/charts.js','/manifest.webmanifest'];
self.addEventListener('install',event=>event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(SHELL)).then(()=>self.skipWaiting())));
self.addEventListener('activate',event=>event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener('fetch',event=>{
  const url=new URL(event.request.url);
  if(event.request.method!=='GET'||url.pathname.startsWith('/api/')||url.hostname.includes('supabase.co'))return;
  if(event.request.mode==='navigate'){
    event.respondWith(fetch(event.request).then(r=>{const c=r.clone();caches.open(CACHE).then(x=>x.put('/index.html',c));return r}).catch(()=>caches.match('/index.html')));return;
  }
  if(url.origin===location.origin)event.respondWith(caches.match(event.request).then(c=>c||fetch(event.request).then(r=>{const copy=r.clone();caches.open(CACHE).then(x=>x.put(event.request,copy));return r})));
});
