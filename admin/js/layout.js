// Renderiza sidebar + header compartidos
const Layout = {
  NAV: [
    { id:'dashboard',  label:'Inicio',              icon:'📊', href:'/admin/dashboard',      section:'Principal' },
    { id:'vender',     label:'Crear venta',         icon:'🛒', href:'/admin/vender',         section:'Mostrador', permiso:'ventas.crear' },
    { id:'caja',       label:'Caja',                icon:'💵', href:'/admin/caja',           section:'Mostrador', permiso:'caja.ver', contador:'caja' },
    { id:'ventas',     label:'Ventas',              icon:'🧮', href:'/admin/ventas',         section:'Mostrador' },
    { id:'entregas',   label:'Retiros y envíos',    icon:'📦', href:'/admin/entregas',       section:'Entregas', permiso:'entregas.ver', contador:'entregas' },
    { id:'pedidos',    label:'Pedidos web',         icon:'🧾', href:'/admin/pedidos',        section:'Pedidos web', contador:'pedidos' },
    { id:'crm',        label:'Clientes',            icon:'🤝', href:'/admin/crm',            section:'Clientes', permiso:'clientes.gestionar' },
    { id:'cuentas-corrientes', label:'Cuentas corrientes', icon:'📒', href:'/admin/cuentas-corrientes', section:'Clientes', permiso:'cc.ver' },
    { id:'completar',  label:'Completar productos',  icon:'✨', href:'/admin/completar',      section:'Catálogo', permiso:'productos.editar' },
    { id:'productos',  label:'Productos',            icon:'🛍️', href:'/admin/productos',      section:'Catálogo' },
    { id:'categorias', label:'Categorías',           icon:'🏷️', href:'/admin/categorias',     section:'Catálogo' },
    { id:'importar',   label:'Importar artículos',   icon:'📥', href:'/admin/importar',       section:'Catálogo', permiso:'productos.editar' },
    { id:'carga-stock',label:'Contar stock',         icon:'🔢', href:'/admin/carga-stock',    section:'Stock', permiso:'stock.contar' },
    { id:'compras',    label:'Compras',             icon:'🚢', href:'/admin/compras',        section:'Stock', permiso:'compras.gestionar' },
    { id:'inventario', label:'Ajuste manual',       icon:'🛠️', href:'/admin/inventario',     section:'Stock', permiso:'stock.ajustar' },
    { id:'movimientos',label:'Movimientos de stock', icon:'📋', href:'/admin/movimientos',    section:'Stock' },
    { id:'cuentas-cobro', label:'Cuentas bancarias',icon:'🏦', href:'/admin/cuentas-cobro',  section:'Administración', adminOnly:true },
    { id:'usuarios',   label:'Usuarios',             icon:'👥', href:'/admin/usuarios',       section:'Administración', adminOnly:true },
    { id:'permisos',   label:'Permisos',             icon:'🔐', href:'/admin/permisos',       section:'Administración', adminOnly:true },
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
    let c = null; try { c = JSON.parse(sessionStorage.getItem(this.CONT_KEY) || 'null'); } catch (e) {}
    if (!c || c.u !== this._perfil?.id) c = { t: Date.now(), u: this._perfil?.id, n: {} };
    c.n[k] = v;
    try { sessionStorage.setItem(this.CONT_KEY, JSON.stringify(c)); } catch (e) {}
    this.pintarContadores(c.n);
  },
  /* Las páginas que cambian algo contado (cobrar, entregar, pasar un pedido) lo llaman */
  refrescarContadores() { try { sessionStorage.removeItem(this.CONT_KEY); } catch (e) {} if (this._perfil) this.contar(this._perfil, true); },


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
    Object.entries(sections).forEach(([sec, items]) => {
      navHTML += `<div><div class="sidebar-section-title">${sec}</div>`;
      items.forEach(item => {
        navHTML += `<a href="${item.href}" class="sidebar-link${item.id===pageId?' active':''}"${item.contador ? ` data-cont="${item.contador}"` : ''}>
          <span class="nav-icon">${item.icon}</span>
          <span class="nav-label">${item.label}</span>
        </a>`;
      });
      navHTML += '</div>';
    });
    document.getElementById('sidebar-nav').innerHTML = navHTML;
    const cc = this.contCache();
    if (cc && cc.u === profile?.id) this.pintarContadores(cc.n);

    // Título (el dibujado anticipado no lo conoce y deja el del HTML)
    if (pageTitle !== undefined) document.getElementById('page-title').textContent = pageTitle || '';

    // Info usuario
    if (profile) {
      const initials = (profile.nombre||'?').split(' ')
        .map(w=>w[0]).join('').slice(0,2).toUpperCase();
      const roleLabel = { administrador:'Administrador', encargado_stock:'Encargado de Stock', vendedor:'Vendedor' };
      document.getElementById('user-avatar').textContent = initials;
      document.getElementById('user-name').textContent   = profile.nombre || 'Usuario';
      document.getElementById('user-role').textContent   = roleLabel[profile.rol] || profile.rol;
    }
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
    if (!sb) return;
    if (localStorage.getItem('sbCollapsed') === 'true' && !this.esMovil()) {
      sb.classList.add('collapsed');
    }
    const profile = Auth.cachedProfile();
    if (!profile) return;
    const actual = this.NAV.find(i => location.pathname.replace(/\.html$/, '') === i.href);
    this.render(actual?.id, undefined, profile);
  },

  async init(pageId, pageTitle) {
    const profile = await Auth.getProfile();
    this.render(pageId, pageTitle, profile);
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
