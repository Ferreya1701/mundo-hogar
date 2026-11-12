/* ============================================================
   El panel como UNA SOLA APLICACIÓN (2026-11).

   Antes cada módulo era una página aparte: al cambiar de módulo se
   descargaba y arrancaba todo de nuevo (librerías, sesión, datos) y se
   perdía lo que había en pantalla. Ahora:

   • Esta página (/admin/app) es el armazón: el menú y la barra de arriba se
     dibujan una sola vez y quedan fijos.
   • Cada módulo se abre en su propio marco (iframe) la primera vez y QUEDA
     ABIERTO al irse a otro: volver es instantáneo y conserva lo que tenía
     (un ticket a medio armar, un filtro, la posición de la lista).
   • Los marcos están aislados entre sí: el código de un módulo no puede
     pisar la pantalla de otro.
   • Se guardan hasta MAX_MARCOS módulos abiertos; el que hace más tiempo que
     no se usa se cierra. Un módulo que estuvo oculto más de VENCE ms se
     recarga al volver, para no mostrar datos viejos.

   La dirección es /admin/app#/caja?ver=12. Las direcciones viejas
   (/admin/caja?ver=12) siguen andando: auth.js las manda acá.
   ============================================================ */
const MHApp = (() => {
  const MAX_MARCOS = 8;
  const VENCE = 10 * 60 * 1000;
  const cont = document.getElementById('app-marcos');
  const barra = document.getElementById('app-cargando');
  const marcos = new Map();   // ruta → { el, usado, oculto, titulo, id }
  let actual = null;
  let perfil = null;

  // '/admin/caja.html/' → '/admin/caja'
  const normal = p => {
    let x = String(p || '').replace(/\.html$/, '').replace(/\/+$/, '');
    if (!x.startsWith('/admin/')) x = '/admin/' + x.replace(/^\/+/, '');
    return x;
  };
  const esModulo = p => /^\/admin\/[a-z0-9-]+$/.test(p) && !['/admin/app', '/admin/index'].includes(p);

  function inicio() {
    return perfil?.rol === 'cajero' ? '/admin/caja' : '/admin/dashboard';
  }

  // '#/caja?ver=12' → { ruta: '/admin/caja', busca: '?ver=12' }
  function leerHash() {
    const h = decodeURIComponent(location.hash.replace(/^#/, ''));
    if (!h || h === '/') return { ruta: inicio(), busca: '' };
    const i = h.indexOf('?');
    const ruta = normal(i >= 0 ? h.slice(0, i) : h);
    return esModulo(ruta) ? { ruta, busca: i >= 0 ? h.slice(i) : '' } : { ruta: inicio(), busca: '' };
  }
  const hashDe = (ruta, busca) => '#/' + ruta.replace(/^\/admin\//, '') + (busca || '');

  function cargando(si) { barra.classList.toggle('si', !!si); }

  function cerrarMasViejo() {
    if (marcos.size <= MAX_MARCOS) return;
    const viejo = [...marcos.entries()].filter(([r]) => r !== actual).sort((a, b) => a[1].usado - b[1].usado)[0];
    if (viejo) { viejo[1].el.remove(); marcos.delete(viejo[0]); }
  }

  function crearMarco(ruta, busca) {
    const el = document.createElement('iframe');
    el.title = 'Módulo';
    el.src = ruta + (busca || '');
    const m = { el, usado: Date.now(), oculto: 0, titulo: '', id: '', busca: busca || '' };
    el.addEventListener('load', () => alCargar(m));
    marcos.set(ruta, m);
    cont.appendChild(el);
    cargando(true);
    cerrarMasViejo();
    return m;
  }

  // El módulo se movió solo (un enlace, un "volver", un permiso que falta):
  // el marco ahora muestra otra ruta. Se la reconoce y se actualiza la dirección.
  function alCargar(m) {
    let loc;
    try { loc = m.el.contentWindow.location; } catch (e) { return; }
    const ruta = normal(loc.pathname);
    if (ruta === '/admin' || ruta === '/admin/index') { location.href = '/admin/'; return; }   // sesión vencida
    const vieja = [...marcos.entries()].find(([, x]) => x === m)?.[0];
    if (vieja && vieja !== ruta && esModulo(ruta)) {
      marcos.delete(vieja);
      const otro = marcos.get(ruta);
      if (otro && otro !== m) otro.el.remove();
      marcos.set(ruta, m);
      if (actual === vieja) actual = ruta;
    }
    m.busca = loc.search;
    if (m.el.classList.contains('activo')) {
      cargando(false);
      history.replaceState(null, '', hashDe(ruta, loc.search));
    }
  }

  function mostrar(ruta, busca) {
    let m = marcos.get(ruta);
    const otraBusqueda = m && (busca || '') !== (m.busca || '') && busca;
    if (m && (otraBusqueda || (m.oculto && Date.now() - m.oculto > VENCE))) {
      m.el.src = ruta + (busca || '');   // pidieron otra cosa (?ver=…) o estaba viejo: se recarga
      m.busca = busca || '';
      cargando(true);
    }
    if (!m) m = crearMarco(ruta, busca);
    for (const [r, x] of marcos) {
      const activo = r === ruta;
      if (!activo && x.el.classList.contains('activo')) x.oculto = Date.now();
      x.el.classList.toggle('activo', activo);
    }
    m.usado = Date.now(); m.oculto = 0;
    actual = ruta;
    if (m.titulo) titulo(m.id, m.titulo, m);
    else Layout.render(ruta.replace('/admin/', ''), '', perfil);
    try { m.el.contentWindow.postMessage({ mh: 'mostrar' }, location.origin); } catch (e) {}
    if (Layout.esMovil()) Layout.toggleSidebar(true);
    m.el.focus?.();
  }

  // Ir a un módulo (desde el menú, desde un enlace de otro módulo, o desde la dirección)
  function ir(href, { reemplazar = false } = {}) {
    let u;
    try { u = new URL(href, location.origin); } catch (e) { return; }
    if (u.origin !== location.origin) { location.href = href; return; }
    const ruta = normal(u.pathname);
    if (ruta === '/admin' || ruta === '/admin/index') { location.href = '/admin/'; return; }
    if (ruta === '/admin/app') { ir(u.hash.replace(/^#/, '/admin') || inicio(), { reemplazar }); return; }
    if (!esModulo(ruta)) { location.href = href; return; }
    const h = hashDe(ruta, u.search);
    if (location.hash !== h) history[reemplazar ? 'replaceState' : 'pushState'](null, '', h);
    mostrar(ruta, u.search);
  }

  // Los módulos avisan su título (Layout.init dentro del marco)
  function titulo(id, texto, m = marcos.get(actual)) {
    if (m) { m.titulo = texto; m.id = id; }
    if (m && m !== marcos.get(actual)) return;
    document.getElementById('page-title').textContent = texto || '';
    document.title = (texto ? texto + ' — ' : '') + 'Mundo Hogar Admin';
    Layout.render(id, texto, perfil);
  }

  // Enlaces del menú y de la barra de arriba
  document.addEventListener('click', e => {
    const a = e.target.closest('a[href]');
    if (!a || a.target === '_blank' || e.ctrlKey || e.metaKey || e.shiftKey || e.button !== 0) return;
    const u = new URL(a.href, location.origin);
    if (u.origin !== location.origin || !u.pathname.startsWith('/admin/')) return;
    e.preventDefault();
    ir(u.pathname + u.search);
  });
  window.addEventListener('popstate', () => { const { ruta, busca } = leerHash(); mostrar(ruta, busca); });
  window.addEventListener('hashchange', () => { const { ruta, busca } = leerHash(); if (ruta !== actual) mostrar(ruta, busca); });

  async function arrancar() {
    perfil = await Auth.init();
    if (!perfil) return;
    await Layout.init('', '');
    const { ruta, busca } = leerHash();
    history.replaceState(null, '', hashDe(ruta, busca));
    mostrar(ruta, busca);
  }
  arrancar();

  return { ir, titulo, get actual() { return actual; } };
})();
window.MHApp = MHApp;
