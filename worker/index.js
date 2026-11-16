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
//
// Además (sql/032, verificación de pagos con el aviso del banco):
//   • email(): recibe los avisos "Recibiste $X" que cada titular reenvía a
//     c-<token>@mundohogarstf.com y se los pasa a la Edge Function
//     "avisos-banco", que los empareja con el pedido.
//   • scheduled(): cada minuto pide la revisión (alertas a los N minutos sin
//     aviso) y manda los mails de alerta.
//   Secreto del Worker: AVISOS_CLAVE (la misma que en Supabase). Sin él, no hace nada.
//   Mails de alerta: binding send_email "MAIL_ALERTAS" (ver GUIA-COBROS.md §8).

const SITIO = 'https://mundohogarstf.com';
const SUPABASE_URL = 'https://vduinkzeneokkqzdgxig.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_IN3Qtb5Jtf1izUGRD9KKCw_FGB41b6v';
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

// ── Avisos del banco ─────────────────────────────────────
const AVISOS_FN = `${SUPABASE_URL}/functions/v1/avisos-banco`;
const MAIL_DE = 'alertas@mundohogarstf.com';

function aBase64(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(s);
}
const utf8b64 = t => aBase64(new TextEncoder().encode(t));

async function llamarAvisos(env, cuerpo) {
  const r = await fetch(AVISOS_FN, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-avisos-clave': env.AVISOS_CLAVE },
    body: JSON.stringify(cuerpo),
    signal: AbortSignal.timeout(45000)
  });
  const datos = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`avisos-banco ${r.status}: ${datos.error || ''}`);
  return datos;
}

function armarMail(para, alerta) {
  const cuerpo = `${alerta.detalle || ''}\n\nAbrir en el panel: ${alerta.link}\n\n— Mundo Hogar (aviso automático de cobros)`;
  return [
    `From: Mundo Hogar Cobros <${MAIL_DE}>`,
    `To: ${para}`,
    `Subject: =?UTF-8?B?${utf8b64('⚠️ ' + alerta.titulo)}?=`,
    `Date: ${new Date().toUTCString()}`,
    `Message-ID: <alerta-${alerta.id}-${Date.now()}@mundohogarstf.com>`,
    'MIME-Version: 1.0',
    'Content-Type: text/plain; charset=utf-8',
    'Content-Transfer-Encoding: base64',
    '',
    utf8b64(cuerpo).replace(/.{76}/g, '$&\r\n')
  ].join('\r\n');
}

async function revisarCobros(env) {
  const r = await llamarAvisos(env, { accion: 'revisar' });
  const mails = Array.isArray(r.mails) ? r.mails : [];
  if (!mails.length || !r.para || !env.MAIL_ALERTAS) return;
  const { EmailMessage } = await import('cloudflare:email');
  const bien = [], mal = [];
  for (const m of mails) {
    try {
      await env.MAIL_ALERTAS.send(new EmailMessage(MAIL_DE, r.para, armarMail(r.para, m)));
      bien.push(m.id);
    } catch (e) {
      console.error('mail de alerta', m.id, e.message);
      mal.push(m.id);
    }
  }
  if (bien.length) await llamarAvisos(env, { accion: 'mail_resultado', ids: bien, ok: true });
  if (mal.length) await llamarAvisos(env, { accion: 'mail_resultado', ids: mal, ok: false });
}

export default {
  async email(message, env) {
    const m = String(message.to || '').toLowerCase().match(/^c-([0-9a-f]{12})@mundohogarstf\.com$/);
    if (!m) { message.setReject('Dirección desconocida'); return; }
    if (!env.AVISOS_CLAVE) { message.setReject('Los avisos de cobro todavía no están activados'); return; }
    if (message.rawSize > 3 * 1024 * 1024) { message.setReject('Mail demasiado grande'); return; }
    const raw = new Uint8Array(await new Response(message.raw).arrayBuffer());
    // Si Supabase falla, la excepción hace que el servidor que reenvía reintente más tarde
    const r = await llamarAvisos(env, { accion: 'aviso', token: m[1], envelope_from: message.from, raw_b64: aBase64(raw) });
    if (r.error === 'direccion_desconocida') message.setReject('Dirección desconocida');
  },

  async scheduled(event, env, ctx) {
    if (!env.AVISOS_CLAVE) return;
    ctx.waitUntil(revisarCobros(env).catch(e => console.error('revisar cobros:', e.message)));
  },

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
