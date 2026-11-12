// Módulo de autenticación y sesión

/* ── El panel como una sola aplicación (admin/app.html + js/app.js) ──
   MH_EMBEBIDO: esta página es un módulo abierto dentro del armazón. Entonces
   esconde su propio menú (lo dibuja el armazón), le pasa los enlaces a otros
   módulos y usa la sesión que el armazón ya tiene.
   Una dirección vieja abierta suelta (/admin/caja) se manda al armazón
   (/admin/app#/caja). Con ?solo=1 se puede abrir un módulo suelto igual. */
const MH_EMBEBIDO = (() => { try { return window.top !== window && !!window.top.MHApp; } catch (e) { return false; } })();
const MH_AL_ARMAZON = (() => {
  const p = location.pathname.replace(/\.html$/, '').replace(/\/+$/, '');
  const modulo = /^\/admin\/[a-z0-9-]+$/.test(p) && !['/admin/app', '/admin/index', '/admin/clave'].includes(p);
  if (MH_EMBEBIDO) {
    document.documentElement.classList.add('mh-embebido');
    // Los estilos van acá (no en admin.css) para no depender de que el navegador ya tenga el admin.css nuevo
    const st = document.createElement('style');
    st.textContent = 'html.mh-embebido .sidebar,html.mh-embebido .main-header,html.mh-embebido .mobile-overlay,html.mh-embebido #mh-asst-fab{display:none!important}html.mh-embebido .main-wrap{margin-left:0!important}';
    document.head.appendChild(st);
    document.addEventListener('click', e => {
      const a = e.target.closest('a[href]');
      if (!a || a.target === '_blank' || a.hasAttribute('download') || e.ctrlKey || e.metaKey || e.shiftKey || e.button !== 0) return;
      let u; try { u = new URL(a.href, location.origin); } catch (x) { return; }
      if (u.origin !== location.origin || !u.pathname.startsWith('/admin/')) return;
      if (u.pathname === location.pathname && u.search === location.search && u.hash) return;   // ancla dentro de la página
      e.preventDefault();
      window.top.MHApp.ir(u.pathname + u.search);
    });
    // El armazón avisa cuando el módulo vuelve a verse: la página puede refrescar sus datos
    window.addEventListener('message', e => {
      if (e.origin === location.origin && e.data?.mh === 'mostrar' && typeof window.MHAlMostrar === 'function') window.MHAlMostrar();
    });
    return false;
  }
  if (modulo && window.top === window && !/[?&]solo=1\b/.test(location.search)) {
    location.replace('/admin/app#/' + p.slice('/admin/'.length) + location.search);
    return true;
  }
  return false;
})();

const Auth = {
  _profile: null,

  async getSession() {
    const { data: { session } } = await db.auth.getSession();
    return session;
  },

  async requireAuth() {
    const session = await this.getSession();
    if (!session) {
      window.location.href = '/admin/';
      return null;
    }
    return session;
  },

  // Perfil y permisos se recuerdan 5 minutos entre páginas: cambiar de módulo no
  // vuelve a preguntarlos (eran 2 consultas en fila antes de mostrar nada). Es solo
  // para dibujar menús y botones: lo que cada uno puede hacer lo controla la base.
  // Un cambio de rol o permisos se ve, como mucho, 5 minutos después (o al volver a entrar).
  PERFIL_TTL: 5 * 60 * 1000,

  async getProfile(forceRefresh = false) {
    if (this._profile && !forceRefresh) return this._profile;
    // Dentro del armazón: el perfil ya lo tiene él (sin consultas al abrir un módulo)
    if (MH_EMBEBIDO && !forceRefresh) {
      try { const p = window.top.Auth?._profile; if (p) { this._profile = p; return p; } } catch (e) {}
    }
    const session = await this.getSession();
    if (!session) return null;
    if (!forceRefresh) {
      const c = this.cachedProfile();
      if (c && c.id === session.user.id && Array.isArray(c.permisos) && c._ts && Date.now() - c._ts < this.PERFIL_TTL) {
        this._profile = c;
        return c;
      }
    }
    const [{ data, error }, permisos] = await Promise.all([
      db.from('profiles').select('*').eq('id', session.user.id).single(),
      this._cargarPermisos(null),
    ]);
    if (error || !data) return null;
    data.permisos = permisos === null ? (this.PERMISOS_ANTERIORES[data.rol] || []) : permisos;
    data._ts = Date.now();
    this._profile = data;
    this._fresco = true;
    try { sessionStorage.setItem('mhPerfil', JSON.stringify(data)); } catch (e) {}
    return data;
  },

  // Permisos del usuario (sql/016). La base los controla igual: esto solo
  // decide qué menús y botones mostrar.
  async _cargarPermisos(rol) {
    const { data, error } = await db.rpc('fn_mis_permisos');
    if (!error && Array.isArray(data)) return data;
    // Todavía no se corrió sql/016: lo que cada rol podía hacer antes (null = usar esa tabla)
    if (/could not find the function|schema cache/i.test(error?.message || '')) return null;
    return [];
  },

  PERMISOS_ANTERIORES: {
    administrador: ['ventas.crear','ventas.ver_todas','ventas.anular_propias','ventas.anular_todas',
                    'pedidos.gestionar','pedidos.cobrar','pedidos.anular_pago','clientes.gestionar',
                    'productos.editar','categorias.editar','stock.contar','stock.ajustar','compras.gestionar'],
    vendedor:        ['ventas.crear','ventas.anular_propias','pedidos.gestionar','pedidos.cobrar','clientes.gestionar'],
    cajero:          [],   // existe desde sql/029, que viene después del 016
    encargado_stock: ['ventas.crear','ventas.ver_todas','ventas.anular_propias','productos.editar',
                      'stock.contar','stock.ajustar','compras.gestionar'],
  },

  // ¿El usuario puede hacer esto? El administrador siempre puede.
  puede(clave, perfil = this._profile || this.cachedProfile()) {
    if (!perfil) return false;
    if (perfil.rol === 'administrador') return true;
    return Array.isArray(perfil.permisos) && perfil.permisos.includes(clave);
  },

  // Para el inicio de una página: sin el permiso, vuelve al inicio.
  requirePermiso(clave, perfil = this._profile) {
    if (this.puede(clave, perfil)) return true;
    try { Utils.toast('No tenés permiso para entrar a esta sección', 'error'); } catch (e) {}
    window.location.href = '/admin/dashboard';
    return false;
  },

  // Perfil de la última página (solo para dibujar el menú sin esperar)
  cachedProfile() {
    try { return JSON.parse(sessionStorage.getItem('mhPerfil')); } catch (e) { return null; }
  },

  async requireRole(roles) {
    const profile = await this.getProfile();
    if (!profile || !roles.includes(profile.rol)) {
      alert('No tenés permiso para acceder a esta sección.');
      window.location.href = '/admin/dashboard';
      return null;
    }
    return profile;
  },

  async logout() {
    try { sessionStorage.removeItem('mhPerfil'); } catch (e) {}
    await db.auth.signOut();
    (MH_EMBEBIDO ? window.top : window).location.href = '/admin/';
  },

  // Llamar al inicio de cada página protegida
  async init() {
    if (MH_AL_ARMAZON) return null;   // se está yendo al armazón
    const session = await this.requireAuth();
    if (!session) return null;

    const profile = await this.getProfile();
    if (!profile) { await this.logout(); return null; }
    if (!profile.activo) {
      alert('Tu cuenta está desactivada. Contactá al administrador.');
      try { sessionStorage.removeItem('mhPerfil'); } catch (e) {}
      await db.auth.signOut();
      window.location.href = '/admin/';
      return null;
    }

    // Entró con una contraseña temporal (alta o restablecida desde Usuarios):
    // antes de usar el panel tiene que elegir una propia.
    if (profile.debe_cambiar_clave === true && !location.pathname.startsWith('/admin/clave')) {
      window.location.href = '/admin/clave';
      return null;
    }

    // Actualizar último acceso (sin esperar, y solo cuando el perfil se pidió de verdad: cada 5 min)
    if (this._fresco) db.from('profiles')
      .update({ ultimo_acceso: new Date().toISOString() })
      .eq('id', profile.id)
      .then(() => {});

    return profile;
  }
};
