// 이전 버전의 캐시를 제거하며 재무자료와 프로그램을 오프라인 저장하지 않습니다.
self.addEventListener('install',()=>self.skipWaiting());
self.addEventListener('activate',event=>event.waitUntil((async()=>{
  for(const key of await caches.keys()) if(key.startsWith('changjin-finance-')) await caches.delete(key);
  await self.clients.claim();
})()));
