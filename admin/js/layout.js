// Renderiza sidebar + header compartidos
const Layout = {
  NAV: [
    { id:'dashboard',  label:'Dashboard',           icon:'📊', href:'/admin/dashboard.html',      section:'Principal' },
    { id:'solicitudes',label:'Solicitudes WhatsApp', icon:'💬', href:'/admin/solicitudes.html',    section:'Ventas' },
    { id:'productos',  label:'Productos',            icon:'🛍️', href:'/admin/productos.html',      section:'Catálogo' },
    { id:'categorias', label:'Categorías',           icon:'🏷️', href:'/admin/categorias.html',     section:'Catálogo' },
    { id:'carga-stock',label:'Carga de Stock',       icon:'📥', href:'/admin/carga-stock.html',    section:'Stock' },
    { id:'inventario', label:'Registrar Movimiento', icon:'📦', href:'/admin/inventario.html',     section:'Stock' },
    { id:'movimientos',label:'Historial',            icon:'📋', href:'/admin/movimientos.html',    section:'Stock' },
    { id:'alertas',    label:'Alertas de Stock',     icon:'🔔', href:'/admin/alertas.html',        section:'Stock' },
    { id:'usuarios',   label:'Usuarios',             icon:'👥', href:'/admin/usuarios.html',       section:'Admin', adminOnly:true },
    { id:'configuracion', label:'Configuración',     icon:'⚙️', href:'/admin/configuracion.html',  section:'Admin', adminOnly:true },
  ],

  render(pageId, pageTitle, profile) {
    // Construir nav agrupado por sección
    const sections = {};
    this.NAV.forEach(item => {
      if (item.adminOnly && profile?.rol !== 'administrador') return;
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

    // Título
    document.getElementById('page-title').textContent = pageTitle || '';

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

  async init(pageId, pageTitle) {
    const profile = await Auth.getProfile();
    this.render(pageId, pageTitle, profile);

    const sb = document.getElementById('sidebar');
    if (localStorage.getItem('sbCollapsed') === 'true' && !this.esMovil()) {
      sb.classList.add('collapsed');
    }

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

    document.getElementById('logout-btn')
      ?.addEventListener('click', () => Auth.logout());
  }
};
