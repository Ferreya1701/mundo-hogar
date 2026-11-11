// Módulo de autenticación y sesión
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

  async getProfile(forceRefresh = false) {
    if (this._profile && !forceRefresh) return this._profile;
    const session = await this.getSession();
    if (!session) return null;
    const { data, error } = await db
      .from('profiles')
      .select('*')
      .eq('id', session.user.id)
      .single();
    if (error || !data) return null;
    data.permisos = await this._cargarPermisos(data.rol);
    this._profile = data;
    try { sessionStorage.setItem('mhPerfil', JSON.stringify(data)); } catch (e) {}
    return data;
  },

  // Permisos del usuario (sql/016). La base los controla igual: esto solo
  // decide qué menús y botones mostrar.
  async _cargarPermisos(rol) {
    const { data, error } = await db.rpc('fn_mis_permisos');
    if (!error && Array.isArray(data)) return data;
    // Todavía no se corrió sql/016: lo que cada rol podía hacer antes
    if (/could not find the function|schema cache/i.test(error?.message || '')) {
      return this.PERMISOS_ANTERIORES[rol] || [];
    }
    return [];
  },

  PERMISOS_ANTERIORES: {
    administrador: ['ventas.crear','ventas.ver_todas','ventas.anular_propias','ventas.anular_todas',
                    'pedidos.gestionar','pedidos.cobrar','pedidos.anular_pago','clientes.gestionar',
                    'productos.editar','categorias.editar','stock.contar','stock.ajustar','compras.gestionar'],
    vendedor:        ['ventas.crear','ventas.anular_propias','pedidos.gestionar','pedidos.cobrar','clientes.gestionar'],
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
    window.location.href = '/admin/';
  },

  // Llamar al inicio de cada página protegida
  async init() {
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

    // Actualizar último acceso (non-blocking)
    db.from('profiles')
      .update({ ultimo_acceso: new Date().toISOString() })
      .eq('id', profile.id)
      .then(() => {});

    return profile;
  }
};
