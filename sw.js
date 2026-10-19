/* Offline shell + cached libraries. Live data (Supabase) is never cached. Bump V to force an update. */
const V='cde-v2', SHELL=['./','index.html','manifest.webmanifest','icon-192.png','icon-512.png'];
self.addEventListener('install',e=>{ e.waitUntil(caches.open(V).then(c=>c.addAll(SHELL)).then(()=>self.skipWaiting())); });
self.addEventListener('activate',e=>{ e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==V).map(k=>caches.delete(k)))).then(()=>self.clients.claim())); });
self.addEventListener('fetch',e=>{
  const r=e.request; if(r.method!=='GET') return;
  const u=new URL(r.url);
  if(u.hostname.endsWith('supabase.co')||u.hostname.endsWith('supabase.in')) return;
  if(u.origin===location.origin&&r.mode==='navigate'){
    e.respondWith(fetch(r).then(res=>{ if(res.ok){ const c=res.clone(); caches.open(V).then(x=>x.put('index.html',c)); } return res; }).catch(()=>caches.match('index.html')));
    return;
  }
  e.respondWith(caches.match(r).then(hit=>{
    const net=fetch(r).then(res=>{ if(res&&(res.ok||res.type==='opaque')){ const c=res.clone(); caches.open(V).then(x=>x.put(r,c)); } return res; }).catch(()=>hit);
    return hit||net;
  }));
});
