/* ============================================================
   Alertas de cobros en el panel (sql/032).

   Cada minuto busca las alertas abiertas que nadie marcó como vistas
   (comprobante sin aviso del banco a los 7 minutos, comprobante que no
   coincide, plata que entró sin pedido, reenvío caído…) y las muestra en
   un recuadro fijo abajo a la derecha, en cualquier módulo. Si el navegador
   lo permite, también como notificación del sistema.

   "Ver" abre el pedido; "Listo" la marca vista (sigue en el pedido hasta que
   se resuelva). Las mismas alertas llegan por mail (worker/index.js).
   ============================================================ */
const AlertasCobros = (() => {
  const CADA = 60000;
  const VISTAS_KEY = 'mhAlertasNotificadas';
  let caja = null;
  let timer = null;

  const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const enlace = a => a.solicitud_id ? `/admin/pedidos?ver=${a.solicitud_id}` : '/admin/cuentas-cobro?tab=avisos';

  function estilos() {
    if (document.getElementById('ac-estilos')) return;
    const st = document.createElement('style');
    st.id = 'ac-estilos';
    st.textContent = `
      .ac-caja{position:fixed;right:16px;bottom:16px;z-index:9000;width:min(380px,calc(100vw - 32px));display:flex;flex-direction:column;gap:8px}
      .ac-item{background:var(--surface);border:1px solid #F4C38F;border-left:5px solid var(--gold);border-radius:var(--r);box-shadow:0 8px 24px rgba(10,46,99,.18);padding:10px 12px;font-size:var(--fs-base);line-height:1.4}
      .ac-item.urgente{border-left-color:var(--danger-ink);border-color:#F0B4AE}
      .ac-tit{font-weight:700;color:var(--night);margin-bottom:2px}
      .ac-det{color:#555;font-size:var(--fs-base)}
      .ac-acc{display:flex;gap:6px;margin-top:8px;justify-content:flex-end}
      .ac-mas{font-size:var(--fs-sm);text-align:right;color:var(--warning-ink)}
      .ac-mas button{background:none;border:0;color:var(--night);font-weight:700;cursor:pointer;padding:0}`;
    document.head.appendChild(st);
  }

  function ir(href) {
    if (window.MHApp) window.MHApp.ir(href); else location.href = href;
  }

  async function marcar(id) {
    await db.rpc('cobros_alerta_vista', { p_id: id ?? null });
    revisar();
  }

  function notificarSistema(lista) {
    if (!('Notification' in window) || Notification.permission !== 'granted') return;
    let ya = [];
    try { ya = JSON.parse(sessionStorage.getItem(VISTAS_KEY) || '[]'); } catch (e) {}
    for (const a of lista.filter(x => !ya.includes(x.id)).slice(0, 3)) {
      try {
        const n = new Notification(a.titulo, { body: a.detalle || '', tag: 'cobro-' + a.id, icon: '/images/marca/icon-192.png' });
        n.onclick = () => { window.focus(); ir(enlace(a)); n.close(); };
      } catch (e) {}
      ya.push(a.id);
    }
    try { sessionStorage.setItem(VISTAS_KEY, JSON.stringify(ya.slice(-200))); } catch (e) {}
  }

  function pintar(lista) {
    if (!caja) { caja = document.createElement('div'); caja.className = 'ac-caja'; caja.setAttribute('role', 'status'); document.body.appendChild(caja); }
    if (!lista.length) { caja.innerHTML = ''; return; }
    const urg = t => ['aviso_sin_pedido', 'reenvio_caido', 'no_se_pudo_confirmar'].includes(t);
    const pedirPermiso = 'Notification' in window && Notification.permission === 'default';
    caja.innerHTML = lista.slice(0, 3).map(a => `<div class="ac-item${urg(a.tipo) ? ' urgente' : ''}">
        <div class="ac-tit">🔔 ${esc(a.titulo)}</div>
        ${a.detalle ? `<div class="ac-det">${esc(a.detalle)}</div>` : ''}
        <div class="ac-acc">
          <button class="btn btn-ghost btn-sm" data-ac-listo="${a.id}">Listo</button>
          <button class="btn btn-primary btn-sm" data-ac-ver="${a.id}">Ver</button>
        </div>
      </div>`).join('')
      + (lista.length > 3 || pedirPermiso ? `<div class="ac-mas">${lista.length > 3 ? `y ${lista.length - 3} más · <button data-ac-todas>marcar todas</button>` : ''}${pedirPermiso ? `${lista.length > 3 ? ' · ' : ''}<button data-ac-permiso>avisarme también fuera del panel</button>` : ''}</div>` : '');
    caja.onclick = async e => {
      const b = e.target.closest('button'); if (!b) return;
      if (b.dataset.acVer) { const a = lista.find(x => x.id === Number(b.dataset.acVer)); ir(enlace(a)); marcar(a.id); }
      else if (b.dataset.acListo) marcar(Number(b.dataset.acListo));
      else if (b.dataset.acTodas !== undefined) marcar(null);
      else if (b.dataset.acPermiso !== undefined) { await Notification.requestPermission(); pintar(lista); notificarSistema(lista); }
    };
  }

  async function revisar() {
    const { data, error } = await db.from('cobros_alertas')
      .select('id, tipo, titulo, detalle, solicitud_id, creada_en')
      .is('resuelta_en', null).is('vista_en', null)
      .order('creada_en', { ascending: false }).limit(20);
    if (error) return;   // sin sql/032 o sin permiso: no se muestra nada
    pintar(data || []);
    notificarSistema(data || []);
  }

  function iniciar(perfil) {
    if (!perfil || !['administrador', 'vendedor'].includes(perfil.rol) || timer) return;
    estilos();
    revisar();
    timer = setInterval(() => { if (!document.hidden) revisar(); }, CADA);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) revisar(); });
  }

  return { iniciar, revisar };
})();
window.AlertasCobros = AlertasCobros;
