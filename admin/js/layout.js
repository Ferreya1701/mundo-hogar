// Renderiza sidebar + header compartidos
const Layout = {
  NAV: [
    { id:'dashboard',  label:'Inicio',              icon:'📊', href:'/admin/dashboard',      section:'Principal' },
    { id:'vender',     label:'Crear venta',         icon:'🛒', href:'/admin/vender',         section:'Ventas', permiso:'ventas.crear' },
    { id:'ventas',     label:'Ventas',              icon:'🧮', href:'/admin/ventas',         section:'Ventas' },
    { id:'caja',       label:'Caja',                icon:'💵', href:'/admin/caja',           section:'Ventas', permiso:'caja.ver' },
    { id:'entregas',   label:'Entregas',            icon:'📦', href:'/admin/entregas',       section:'Ventas', permiso:'entregas.ver' },
    { id:'cuentas-corrientes', label:'Cuentas corrientes', icon:'📒', href:'/admin/cuentas-corrientes', section:'Ventas', permiso:'cc.ver' },
    { id:'pedidos',    label:'Pedidos web',         icon:'🧾', href:'/admin/pedidos',        section:'Ventas' },
    { id:'crm',        label:'Clientes',            icon:'🤝', href:'/admin/crm',            section:'Ventas', permiso:'clientes.gestionar' },
    { id:'cuentas-cobro', label:'Cuentas bancarias',icon:'🏦', href:'/admin/cuentas-cobro',  section:'Ventas', adminOnly:true },
    { id:'completar',  label:'Completar productos',  icon:'✨', href:'/admin/completar',      section:'Catálogo', permiso:'productos.editar' },
    { id:'productos',  label:'Productos',            icon:'🛍️', href:'/admin/productos',      section:'Catálogo' },
    { id:'categorias', label:'Categorías',           icon:'🏷️', href:'/admin/categorias',     section:'Catálogo' },
    { id:'importar',   label:'Importar artículos',   icon:'📥', href:'/admin/importar',       section:'Catálogo', permiso:'productos.editar' },
    { id:'carga-stock',label:'Contar stock',         icon:'📥', href:'/admin/carga-stock',    section:'Stock', permiso:'stock.contar' },
    { id:'compras',    label:'Compras',             icon:'🚢', href:'/admin/compras',        section:'Stock', permiso:'compras.gestionar' },
    { id:'inventario', label:'Ajuste manual',       icon:'📦', href:'/admin/inventario',     section:'Stock', permiso:'stock.ajustar' },
    { id:'movimientos',label:'Movimientos de stock', icon:'📋', href:'/admin/movimientos',    section:'Stock' },
    { id:'usuarios',   label:'Usuarios',             icon:'👥', href:'/admin/usuarios',       section:'Admin', adminOnly:true },
    { id:'permisos',   label:'Permisos',             icon:'🔐', href:'/admin/permisos',       section:'Admin', adminOnly:true },
    { id:'configuracion', label:'Configuración',     icon:'⚙️', href:'/admin/configuracion',  section:'Admin', adminOnly:true },
  ],

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
        navHTML += `<a href="${item.href}" class="sidebar-link${item.id===pageId?' active':''}">
          <span class="nav-icon">${item.icon}</span>
          <span class="nav-label">${item.label}</span>
        </a>`;
      });
      navHTML += '</div>';
    });
    document.getElementById('sidebar-nav').innerHTML = navHTML;

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
