// Renderiza sidebar + header compartidos
const Layout = {
  NAV: [
    { id:'dashboard',  label:'Dashboard',           icon:'📊', href:'/admin/dashboard.html',      section:'Principal' },
    { id:'productos',  label:'Productos',            icon:'🛍️', href:'/admin/productos.html',      section:'Catálogo' },
    { id:'categorias', label:'Categorías',           icon:'🏷️', href:'/admin/categorias.html',     section:'Catálogo' },
    { id:'inventario', label:'Registrar Movimiento', icon:'📦', href:'/admin/inventario.html',     section:'Stock' },
    { id:'movimientos',label:'Historial',            icon:'📋', href:'/admin/movimientos.html',    section:'Stock' },
    { id:'alertas',    label:'Alertas de Stock',     icon:'🔔', href:'/admin/alertas.html',        section:'Stock' },
    { id:'usuarios',   label:'Usuarios',             icon:'👥', href:'/admin/usuarios.html',       section:'Admin', adminOnly:true },
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

  toggleSidebar() {
    const sb = document.getElementById('sidebar');
    if (window.innerWidth <= 768) {
      sb.classList.toggle('mobile-open');
    } else {
      sb.classList.toggle('collapsed');
      localStorage.setItem('sbCollapsed', sb.classList.contains('collapsed'));
    }
  },

  async init(pageId, pageTitle) {
    const profile = await Auth.getProfile();
    this.render(pageId, pageTitle, profile);

    const sb = document.getElementById('sidebar');
    if (localStorage.getItem('sbCollapsed') === 'true' && window.innerWidth > 768) {
      sb.classList.add('collapsed');
    }

    document.getElementById('sidebar-toggle')
      ?.addEventListener('click', () => this.toggleSidebar());
    document.getElementById('mobile-overlay')
      ?.addEventListener('click', () => this.toggleSidebar());
    document.getElementById('logout-btn')
      ?.addEventListener('click', () => Auth.logout());
  }
};
