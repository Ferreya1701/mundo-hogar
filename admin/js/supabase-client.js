// Inicialización del cliente Supabase
// Requiere que supabase-config.js esté cargado antes

(function () {
  if (typeof SUPABASE_URL === 'undefined' || SUPABASE_URL.startsWith('REEMPLAZAR')) {
    document.body.innerHTML = `
      <div style="display:flex;align-items:center;justify-content:center;min-height:100vh;
        font-family:sans-serif;padding:24px;text-align:center;background:#1A1A2E;">
        <div style="background:#fff;border-radius:12px;padding:40px;max-width:440px">
          <div style="font-size:40px;margin-bottom:16px">⚙️</div>
          <h2 style="color:#1A1A2E;margin-bottom:8px">Configuración requerida</h2>
          <p style="color:#6B6560;margin-bottom:16px">
            Completá el archivo <code style="background:#F5F2EE;padding:2px 6px;border-radius:4px">supabase-config.js</code>
            con las credenciales de tu proyecto Supabase.
          </p>
          <p style="color:#6B6560;font-size:13px">
            Seguí las instrucciones en <strong>ADMINISTRADOR-MUNDO-HOGAR.md</strong>
          </p>
        </div>
      </div>`;
    throw new Error('supabase-config.js no configurado');
  }

  const { createClient } = window.supabase;
  window.db = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
})();
