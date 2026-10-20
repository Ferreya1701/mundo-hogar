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
    this._profile = data;
    try { sessionStorage.setItem('mhPerfil', JSON.stringify(data)); } catch (e) {}
    return data;
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

    // Actualizar último acceso (non-blocking)
    db.from('profiles')
      .update({ ultimo_acceso: new Date().toISOString() })
      .eq('id', profile.id)
      .then(() => {});

    return profile;
  }
};
