// Renderiza sidebar + header compartidos
const Layout = {
  NAV: [
    { id:'dashboard',  label:'Inicio',              icon:'📊', href:'/admin/dashboard',      section:'' },
    { id:'vender',     label:'Crear venta',         icon:'🛒', href:'/admin/vender',         section:'Ventas', permiso:'ventas.crear' , claves:'nueva venta cobrar ticket' },
    { id:'caja',       label:'Caja',                icon:'💵', href:'/admin/caja',           section:'Ventas', permiso:'caja.ver', contador:'caja' },
    { id:'ventas',     label:'Ventas',              icon:'🧮', href:'/admin/ventas',         section:'Ventas' },
    { id:'pedidos',    label:'Pedidos web',         icon:'🧾', href:'/admin/pedidos',        section:'Ventas', contador:'pedidos' },
    { id:'entregas',   label:'Retiros y envíos',    icon:'📦', href:'/admin/entregas',       section:'Ventas', permiso:'entregas.ver', contador:'entregas' , claves:'envio retiro despacho' },
    { id:'crm',        label:'Clientes',            icon:'🤝', href:'/admin/crm',            section:'Clientes', permiso:'clientes.gestionar' , claves:'cliente buscar' },
    { id:'cuentas-corrientes', label:'Cuentas corrientes', icon:'📒', href:'/admin/cuentas-corrientes', section:'Clientes', permiso:'cc.ver' },
    { id:'completar',  label:'Completar productos',  icon:'✨', href:'/admin/completar',      section:'Catálogo', permiso:'productos.editar' },
    { id:'fotos-revisar', label:'Fotos para revisar', icon:'🖼️', href:'/admin/fotos-revisar', section:'Catálogo', permiso:'productos.editar' },
    { id:'productos',  label:'Productos',            icon:'🛍️', href:'/admin/productos',      section:'Catálogo' },
    { id:'categorias', label:'Categorías',           icon:'🏷️', href:'/admin/categorias',     section:'Catálogo' },
    { id:'importar',   label:'Importar artículos',   icon:'📥', href:'/admin/importar',       section:'Catálogo', permiso:'productos.editar' },
    { id:'carga-stock',label:'Contar stock',         icon:'🔢', href:'/admin/carga-stock',    section:'Stock', permiso:'stock.contar' , claves:'inventario conteo' },
    { id:'compras',    label:'Compras',             icon:'🚢', href:'/admin/compras',        section:'Stock', permiso:'compras.gestionar' },
    { id:'inventario', label:'Ajuste manual',       icon:'🛠️', href:'/admin/inventario',     section:'Stock', permiso:'stock.ajustar' },
    { id:'movimientos',label:'Movimientos de stock', icon:'📋', href:'/admin/movimientos',    section:'Stock' },
    { id:'cuentas-cobro', label:'Cuentas bancarias',icon:'🏦', href:'/admin/cuentas-cobro',  section:'Administración', adminOnly:true , claves:'alias cbu transferencia' },
    { id:'usuarios',   label:'Usuarios',             icon:'👥', href:'/admin/usuarios',       section:'Administración', adminOnly:true },
    { id:'permisos',   label:'Permisos',             icon:'🔐', href:'/admin/permisos',       section:'Administración', adminOnly:true },
    { id:'historial',  label:'Historial',            icon:'🕵️', href:'/admin/historial',      section:'Administración', permiso:'auditoria.ver' },
    { id:'configuracion', label:'Configuración',     icon:'⚙️', href:'/admin/configuracion',  section:'Administración', adminOnly:true },
  ],

  /* Contadores del menú: lo que espera a alguien. Se piden juntos, en
     paralelo y con "head" (solo la cantidad), y se guardan 60 s para que
     cambiar de módulo no espere a nadie. Si algo falla, no se muestra. */
  CONT_KEY: 'mhMenuCont',
  CONT_TTL: 60000,
  CONTADORES: {
    caja:     { permiso: 'caja.cobrar', titulo: 'ventas esperando cobro en la caja',
                q: () => db.from('ventas').select('id', { count: 'exact', head: true }).eq('estado', 'pendiente_cobro').neq('origen', 'web') },
    entregas: { permiso: 'entregas.ver', titulo: 'retiros y envíos pendientes',
                q: () => db.from('ventas').select('id', { count: 'exact', head: true }).in('entrega_estado', ['pendiente', 'listo']).neq('estado', 'anulada') },
    pedidos:  { titulo: 'pedidos nuevos o con comprobante para revisar',
                q: () => db.from('solicitudes').select('id', { count: 'exact', head: true }).or('estado.eq.nueva,estado_pago.in.(comprobante_recibido,en_revision)').neq('estado', 'cancelado') },
  },
  contCache() {
    try { const c = JSON.parse(sessionStorage.getItem(this.CONT_KEY) || 'null'); return c && Date.now() - c.t < this.CONT_TTL ? c : null; } catch (e) { return null; }
  },
  pintarContadores(n) {
    document.querySelectorAll('#sidebar-nav [data-cont]').forEach(a => {
      const k = a.dataset.cont, v = n?.[k];
      a.querySelector('.nav-badge')?.remove();
      if (v > 0) a.insertAdjacentHTML('beforeend', `<span class="nav-badge" title="${v} ${this.CONTADORES[k].titulo}">${v > 99 ? '99+' : v}</span>`);
    });
  },
  async contar(profile, forzar = false) {
    if (typeof db === 'undefined' || !profile) return;
    const c = !forzar && this.contCache();
    if (c && c.u === profile.id) { this.pintarContadores(c.n); return; }
    const keys = Object.keys(this.CONTADORES).filter(k => {
      const it = this.NAV.find(i => i.contador === k);
      return it && (!it.permiso || Auth.puede(it.permiso, profile)) && (!this.CONTADORES[k].permiso || Auth.puede(this.CONTADORES[k].permiso, profile));
    });
    const res = await Promise.all(keys.map(k => this.CONTADORES[k].q().then(r => r.error ? null : r.count, () => null)));
    const n = Object.fromEntries(keys.map((k, i) => [k, res[i]]));
    try { sessionStorage.setItem(this.CONT_KEY, JSON.stringify({ t: Date.now(), u: profile.id, n })); } catch (e) {}
    this.pintarContadores(n);
  },
  /* Una página que ya tiene el número a mano (Caja, Entregas) lo actualiza sin consultar */
  fijarContador(k, v) {
    if (typeof MH_EMBEBIDO !== 'undefined' && MH_EMBEBIDO) { try { window.top.Layout.fijarContador(k, v); } catch (e) {} return; }
    let c = null; try { c = JSON.parse(sessionStorage.getItem(this.CONT_KEY) || 'null'); } catch (e) {}
    if (!c || c.u !== this._perfil?.id) c = { t: Date.now(), u: this._perfil?.id, n: {} };
    c.n[k] = v;
    try { sessionStorage.setItem(this.CONT_KEY, JSON.stringify(c)); } catch (e) {}
    this.pintarContadores(c.n);
  },
  /* Las páginas que cambian algo contado (cobrar, entregar, pasar un pedido) lo llaman */
  refrescarContadores() {
    if (typeof MH_EMBEBIDO !== 'undefined' && MH_EMBEBIDO) { try { window.top.Layout.refrescarContadores(); } catch (e) {} return; } try { sessionStorage.removeItem(this.CONT_KEY); } catch (e) {} if (this._perfil) this.contar(this._perfil, true); },


  render(pageId, pageTitle, profile) {
    // Construir nav agrupado por sección
    const sections = {};
    this.NAV.forEach(item => {
      if (item.adminOnly && profile?.rol !== 'administrador') return;
      if (item.permiso && !Auth.puede(item.permiso, profile)) return;
      if (!sections[item.section]) sections[item.section] = [];
      sections[item.section].push(item);
    });

    let navHTML = '';
    const link = item => `<a href="${item.href}" class="sidebar-link${item.id===pageId?' active':''}"${item.contador ? ` data-cont="${item.contador}"` : ''}${item.id===pageId ? ' aria-current="page"' : ''}>
          <span class="nav-icon">${item.icon}</span>
          <span class="nav-label">${item.label}</span>
        </a>`;
    Object.entries(sections).forEach(([sec, items]) => {
      // Administración se usa poco: va plegada salvo que se esté adentro
      if (sec === 'Administración') {
        const abierta = items.some(i => i.id === pageId) || localStorage.getItem('sbAdmin') === '1';
        navHTML += `<details class="sidebar-grupo"${abierta ? ' open' : ''}><summary class="sidebar-section-title">${sec}</summary>${items.map(link).join('')}</details>`;
        return;
      }
      navHTML += `<div>${sec ? `<div class="sidebar-section-title">${sec}</div>` : ''}${items.map(link).join('')}</div>`;
    });
    const navEl = document.getElementById('sidebar-nav');
    navEl.innerHTML = navHTML;
    navEl.querySelector('.sidebar-grupo')?.addEventListener('toggle', e => { try { localStorage.setItem('sbAdmin', e.target.open ? '1' : '0'); } catch (x) {} });
    this._navPerfil = profile;
    const cc = this.contCache();
    if (cc && cc.u === profile?.id) this.pintarContadores(cc.n);

    // Título (el dibujado anticipado no lo conoce y deja el del HTML)
    if (pageTitle !== undefined) document.getElementById('page-title').textContent = pageTitle || '';

    // Info usuario
    if (profile) {
      const initials = (profile.nombre||'?').split(' ')
        .map(w=>w[0]).join('').slice(0,2).toUpperCase();
      const roleLabel = { administrador:'Administrador', encargado_stock:'Encargado de Stock', vendedor:'Vendedor', cajero:'Cajero' };
      document.getElementById('user-avatar').textContent = initials;
      document.getElementById('user-name').textContent   = profile.nombre || 'Usuario';
      document.getElementById('user-role').textContent   = roleLabel[profile.rol] || profile.rol;
    }
  },

  /* ── Buscador de pantallas y acciones (Ctrl+K / ⌘K), como Linear o Stripe ──
     Lista las pantallas que el usuario puede abrir y algunas acciones. Escribir
     filtra (sin acentos); ↑/↓ eligen, Enter abre, Escape cierra. Dentro del
     armazón la abre el armazón, para que cubra toda la pantalla. */
  ACCIONES: [
    { label:'Nuevo producto',     icon:'➕', href:'/admin/producto-form', permiso:'productos.editar', claves:'agregar cargar alta' },
    { label:'Cambiar mi contraseña', icon:'🔑', href:'/admin/clave', claves:'clave password' },
    { label:'Modo oscuro / claro', icon:'🌙', run:'tema', claves:'tema noche dark oscuro claro' },
  ],
  /* Tema: claro por defecto; el oscuro se elige a mano y queda guardado en
     este navegador. Se aplica en el armazón y en todos los módulos abiertos. */
  tema(t) {
    if (t === undefined) t = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
    try { localStorage.setItem('mhTema', t); } catch (e) {}
    const aplicar = doc => { try { if (t === 'dark') doc.documentElement.dataset.theme = 'dark'; else delete doc.documentElement.dataset.theme; } catch (e) {} };
    let raiz = window;
    try { if (window.top !== window && window.top.document) raiz = window.top; } catch (e) {}
    aplicar(raiz.document);
    raiz.document.querySelectorAll('iframe').forEach(f => { try { aplicar(f.contentDocument); } catch (e) {} });
    aplicar(document);
    raiz.document.querySelectorAll('#tema-btn').forEach(b => { b.textContent = t === 'dark' ? '☀️' : '🌙'; b.setAttribute('aria-label', t === 'dark' ? 'Pasar a modo claro' : 'Pasar a modo oscuro'); });
  },
  irA(href) {
    try { if (window.top !== window && window.top.MHApp) { window.top.MHApp.ir(href); return; } } catch (e) {}
    if (window.MHApp) { MHApp.ir(href); return; }
    location.href = href;
  },
  abrirPaleta() {
    // En un módulo dentro del armazón, la abre el armazón
    try { if (window.top !== window && window.top.Layout?.abrirPaleta) { window.top.Layout.abrirPaleta(); return; } } catch (e) {}
    if (document.getElementById('mh-paleta')) return;
    const perfil = this._navPerfil || this._perfil || Auth.cachedProfile?.();
    const vale = i => (!i.adminOnly || perfil?.rol === 'administrador') && (!i.permiso || Auth.puede(i.permiso, perfil));
    const items = [
      ...this.ACCIONES.filter(vale).map(a => ({ ...a, tipo: 'Acción' })),
      ...this.NAV.filter(vale).map(i => ({ ...i, tipo: i.section || 'Inicio' })),
    ];
    const norm = t => String(t || '').toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '');
    const esc = t => String(t ?? '').replace(/[&<>"]/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;' }[c]));
    const previo = document.activeElement;
    const bd = document.createElement('div');
    bd.id = 'mh-paleta'; bd.className = 'paleta-bg';
    bd.innerHTML = `<div class="paleta" role="dialog" aria-modal="true" aria-label="Ir a">
      <input type="text" class="paleta-q" placeholder="Ir a… (pantalla o acción)" aria-label="Buscar pantalla o acción" autocomplete="off" role="combobox" aria-controls="paleta-lista" aria-expanded="true">
      <div class="paleta-lista" id="paleta-lista" role="listbox"></div>
      <div class="paleta-pie"><span><kbd>↑</kbd><kbd>↓</kbd> elegir</span><span><kbd>Enter</kbd> abrir</span><span><kbd>Esc</kbd> cerrar</span></div></div>`;
    document.body.appendChild(bd);
    const q = bd.querySelector('.paleta-q'), lista = bd.querySelector('.paleta-lista');
    let vis = [], sel = 0;
    const pintar = () => {
      const ts = norm(q.value).split(/\s+/).filter(Boolean);
      vis = items.filter(i => { const h = norm(`${i.label} ${i.tipo} ${i.claves || ''}`); return ts.every(t => h.includes(t)); });
      sel = Math.min(sel, Math.max(0, vis.length - 1));
      lista.innerHTML = vis.length ? vis.map((i, n) => `<a href="${i.href || '#'}" class="paleta-it${n === sel ? ' sel' : ''}" role="option" aria-selected="${n === sel}" data-n="${n}"><span class="paleta-ic">${i.icon}</span><span class="paleta-lbl">${esc(i.label)}</span><span class="paleta-tipo">${esc(i.tipo)}</span></a>`).join('')
        : '<div class="paleta-vacio">Nada con ese nombre</div>';
      lista.querySelector('.sel')?.scrollIntoView({ block: 'nearest' });
    };
    const cerrar = () => { bd.remove(); previo?.focus?.(); };
    const abrir = i => { if (!i) return; cerrar(); if (i.run === 'tema') this.tema(); else this.irA(i.href); };
    q.addEventListener('input', () => { sel = 0; pintar(); });
    q.addEventListener('keydown', e => {
      if (e.key === 'ArrowDown') { e.preventDefault(); sel = Math.min(vis.length - 1, sel + 1); pintar(); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); sel = Math.max(0, sel - 1); pintar(); }
      else if (e.key === 'Enter') { e.preventDefault(); abrir(vis[sel]); }
      else if (e.key === 'Escape') { e.preventDefault(); cerrar(); }
    });
    lista.addEventListener('click', e => { const a = e.target.closest('[data-n]'); if (!a) return; e.preventDefault(); e.stopPropagation(); abrir(vis[+a.dataset.n]); });
    bd.addEventListener('mousedown', e => { if (e.target === bd) cerrar(); });
    pintar(); q.focus();
  },
  atajoPaleta() {
    if (this._atajo) return; this._atajo = true;
    document.addEventListener('keydown', e => {
      if ((e.ctrlKey || e.metaKey) && !e.altKey && e.key.toLowerCase() === 'k') { e.preventDefault(); this.abrirPaleta(); }
    });
  },

  esMovil: () => window.innerWidth <= 768,

  toggleSidebar(forzarCerrado = false) {
    const sb  = document.getElementById('sidebar');
    const btn = document.getElementById('sidebar-toggle');
    if (this.esMovil()) {
      const abierto = forzarCerrado
        ? (sb.classList.remove('mobile-open'), false)
        : sb.classList.toggle('mobile-open');
      btn?.setAttribute('aria-expanded', String(abierto));
      btn?.setAttribute('aria-label', abierto ? 'Cerrar menú' : 'Abrir menú');
    } else {
      sb.classList.toggle('collapsed');
      localStorage.setItem('sbCollapsed', sb.classList.contains('collapsed'));
    }
  },

  // Dibuja el menú apenas carga el script, con el perfil que guardó la página
  // anterior, para que no quede vacío mientras responde Supabase. Es solo
  // visual: los permisos reales los sigue controlando Auth.init + Supabase.
  prerender() {
    const sb = document.getElementById('sidebar');
    if (!sb || (typeof MH_EMBEBIDO !== 'undefined' && MH_EMBEBIDO)) return;
    if (localStorage.getItem('sbCollapsed') === 'true' && !this.esMovil()) {
      sb.classList.add('collapsed');
    }
    const profile = Auth.cachedProfile();
    if (!profile) return;
    const actual = this.NAV.find(i => location.pathname.replace(/\.html$/, '') === i.href);
    this.render(actual?.id, undefined, profile);
  },

  /* Tablas del panel (todas las .table-wrap, también las que se dibujan después):
     • Celular: pasan a tarjetas sin encabezado; cada celda toma la etiqueta de
       su columna para que un número suelto se entienda.
     • Computadora: el encabezado queda fijo al bajar (como Shopify/Stripe). Si
       la tabla entra en el ancho, se pega arriba de la página; si es más ancha
       (clase "ancha"), conserva el desplazamiento lateral y baja dentro de su
       propio cuadro, con el encabezado fijo arriba. */
  prepararTablas() {
    if (this._tablas) return; this._tablas = true;
    const etiquetar = () => document.querySelectorAll('.table-wrap table').forEach(t => {
      const ths = [...t.querySelectorAll('thead th')].map(th => th.textContent.trim());
      if (!ths.length) return;
      t.querySelectorAll('tbody tr').forEach(tr => {
        // Productos, Compras y Ventas ya traen su tarjeta armada a mano
        if (tr.querySelector(':scope > td[class*="c-"]')) return;
        let col = 0;
        for (const td of tr.children) {
          const span = td.colSpan || 1;
          if (span === 1 && !td.hasAttribute('data-l') && ths[col]) td.setAttribute('data-l', ths[col]);
          col += span;
        }
      });
    });
    const medir = () => document.querySelectorAll('.table-wrap').forEach(w => {
      const t = w.querySelector(':scope > table'); if (!t) return;
      w.classList.toggle('ancha', t.scrollWidth > w.clientWidth + 1);
    });
    const todo = () => { etiquetar(); medir(); };
    let pendiente = false;
    const luego = () => { if (pendiente) return; pendiente = true; requestAnimationFrame(() => { pendiente = false; todo(); }); };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', todo); else todo();
    new MutationObserver(luego).observe(document.body, { childList: true, subtree: true });
    addEventListener('resize', luego);
  },

  async init(pageId, pageTitle) {
    const profile = await Auth.getProfile();
    this.render(pageId, pageTitle, profile);
    // Módulo dentro del armazón: el menú, la barra y los contadores son del armazón
    this.atajoPaleta();
    this.prepararTablas();   // también dentro del armazón (antes quedaba después del return)
    if (typeof MH_EMBEBIDO !== 'undefined' && MH_EMBEBIDO) {
      try { window.top.MHApp.titulo(pageId, pageTitle); } catch (e) {}
      return;
    }
    const acciones = document.querySelector('.main-header .header-actions');
    if (acciones && !document.getElementById('paleta-btn')) {
      const esMac = /Mac|iPhone|iPad/.test(navigator.platform || '');
      acciones.insertAdjacentHTML('afterbegin', `<button type="button" id="paleta-btn" class="btn btn-ghost btn-sm paleta-btn" aria-label="Ir a una pantalla (${esMac ? '⌘' : 'Ctrl'}+K)">🔍 <span class="paleta-btn-txt">Ir a…</span> <kbd>${esMac ? '⌘' : 'Ctrl'} K</kbd></button>`);
      document.getElementById('paleta-btn').addEventListener('click', () => this.abrirPaleta());
      const oscuro = document.documentElement.dataset.theme === 'dark';
      document.getElementById('paleta-btn').insertAdjacentHTML('afterend', `<button type="button" id="tema-btn" class="btn btn-ghost btn-sm" aria-label="${oscuro ? 'Pasar a modo claro' : 'Pasar a modo oscuro'}" title="Modo oscuro / claro">${oscuro ? '☀️' : '🌙'}</button>`);
      document.getElementById('tema-btn').addEventListener('click', () => this.tema());
    }
    this._perfil = profile;
    this.contar(profile);
    setInterval(() => { if (!document.hidden) this.contar(profile); }, this.CONT_TTL);

    const sb = document.getElementById('sidebar');

    const btn = document.getElementById('sidebar-toggle');
    if (btn) {
      btn.setAttribute('aria-controls', 'sidebar');
      btn.setAttribute('aria-expanded', 'false');
      btn.setAttribute('aria-label', 'Abrir menú');
      btn.addEventListener('click', () => this.toggleSidebar());
    }
    document.getElementById('mobile-overlay')
      ?.addEventListener('click', () => this.toggleSidebar(true));

    // Escape cierra el menú: en celular tapa media pantalla y hay que
    // poder salir sin buscar el botón.
    document.addEventListener('keydown', e => {
      if (e.key === 'Escape' && sb.classList.contains('mobile-open')) this.toggleSidebar(true);
    });

    const salir = document.getElementById('logout-btn');
    salir?.addEventListener('click', () => Auth.logout());
    // "Mi contraseña" al lado de Salir, en todas las páginas del panel
    if (salir && !document.getElementById('clave-btn')) {
      salir.insertAdjacentHTML('beforebegin',
        '<a id="clave-btn" href="/admin/clave" class="btn btn-ghost btn-sm" title="Cambiar mi contraseña" aria-label="Cambiar mi contraseña">🔑</a>');
    }
  }
};

Layout.prerender();

// Si otra pestaña cambia el tema, esta lo sigue
window.addEventListener('storage', e => {
  if (e.key !== 'mhTema') return;
  if (e.newValue === 'dark') document.documentElement.dataset.theme = 'dark';
  else delete document.documentElement.dataset.theme;
});
