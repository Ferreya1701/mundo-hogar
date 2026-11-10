// Worker de Cloudflare: completa los metadatos de cada ficha de producto (/producto/<slug>)
// ANTES de entregar el HTML, para que WhatsApp, Facebook, Google y similares (que no corren
// JavaScript) vean el nombre, la foto y la descripción reales del producto.
//
// Solo actúa sobre /producto/* (ver "run_worker_first" en wrangler.jsonc). Todo lo demás lo sirve
// Cloudflare directo, sin pasar por acá.
//
// A prueba de fallos: si algo sale mal (slug raro, producto inexistente, Supabase lento o caído),
// entrega la página tal cual, que igual arma sus metadatos con JavaScript como siempre.
//
// La URL y la clave de Supabase son PÚBLICAS por diseño (las mismas de supabase-config.js):
// los datos se protegen con RLS. Acá no va ningún secreto.

const SITIO = 'https://mundohogarstf.com';
const SUPABASE_URL = 'https://zydotmaolgddwenwywyc.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_8mXhNbUrp3wiWeHuZBVkVA_mFAihF_t';
const IMAGEN_POR_DEFECTO = `${SITIO}/images/marca/logo-mundo-hogar.png`;

const esc = s => String(s).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const recortar = (s, n) => {
  const t = String(s || '').replace(/\s+/g, ' ').trim();
  return t.length <= n ? t : t.slice(0, n - 1).trimEnd() + '…';
};
const absoluta = u => {
  if (!u) return IMAGEN_POR_DEFECTO;
  if (/^https?:\/\//i.test(u)) return u;
  return SITIO + (u.startsWith('/') ? '' : '/') + u;
};

async function buscarProducto(slug) {
  const ruta = 'productos?select=slug,nombre,descripcion,descripcion_corta,imagen_principal_url'
    + `&estado=eq.activo&slug=eq.${encodeURIComponent(slug)}&limit=1`;
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${ruta}`, {
    headers: { apikey: SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${SUPABASE_PUBLISHABLE_KEY}` },
    signal: AbortSignal.timeout(2500),
    cf: { cacheEverything: true, cacheTtl: 300 }
  });
  if (!r.ok) return null;
  const filas = await r.json();
  return Array.isArray(filas) && filas.length ? filas[0] : null;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const pagina = () => env.ASSETS.fetch(new Request(new URL('/producto', url), request));

    try {
      if (request.method !== 'GET' && request.method !== 'HEAD') return pagina();
      const crudo = url.pathname.replace(/^\/producto\//, '').replace(/\/+$/, '');
      let slug;
      try { slug = decodeURIComponent(crudo); } catch (e) { return pagina(); }
      if (!/^[A-Za-z0-9_-]{1,160}$/.test(slug)) return pagina();

      const [respuesta, p] = await Promise.all([pagina(), buscarProducto(slug).catch(() => null)]);
      if (!p || !p.nombre || !respuesta.ok) return respuesta;

      const titulo = `${p.nombre} — Mundo Hogar`;
      const descripcion = recortar(p.descripcion_corta || p.descripcion || p.nombre, 155);
      const enlace = `${SITIO}/producto/${p.slug}`;
      const imagen = absoluta(p.imagen_principal_url);

      const etiquetas = [
        `<link rel="canonical" href="${esc(enlace)}">`,
        '<meta property="og:type" content="product">',
        '<meta property="og:site_name" content="Mundo Hogar">',
        '<meta property="og:locale" content="es_AR">',
        `<meta property="og:title" content="${esc(titulo)}">`,
        `<meta property="og:description" content="${esc(descripcion)}">`,
        `<meta property="og:url" content="${esc(enlace)}">`,
        `<meta property="og:image" content="${esc(imagen)}">`,
        '<meta name="twitter:card" content="summary_large_image">',
        `<meta name="twitter:title" content="${esc(titulo)}">`,
        `<meta name="twitter:description" content="${esc(descripcion)}">`,
        `<meta name="twitter:image" content="${esc(imagen)}">`
      ].join('\n');

      return new HTMLRewriter()
        .on('title', { element(e) { e.setInnerContent(titulo); } })
        .on('meta[name="description"]', { element(e) { e.setAttribute('content', descripcion); } })
        .on('head', { element(e) { e.append(etiquetas, { html: true }); } })
        .transform(respuesta);
    } catch (e) {
      return pagina();
    }
  }
};
