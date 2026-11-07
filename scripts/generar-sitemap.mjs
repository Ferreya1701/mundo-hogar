// Regenera sitemap.xml con las páginas fijas, las categorías y la ficha de cada producto activo.
// Lee el catálogo público (la misma clave publicable que usa la tienda; no hace falta ninguna credencial).
//
//   node scripts/generar-sitemap.mjs
//
// Correrlo después de sumar o dar de baja productos y subir el resultado a main.
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SITIO = 'https://mundohogarstf.com';

const config = fs.readFileSync(path.join(RAIZ, 'supabase-config.js'), 'utf8');
const url = (config.match(/https:\/\/[a-z0-9]+\.supabase\.co/) || [])[0];
const clave = (config.match(/sb_publishable_[A-Za-z0-9_-]+/) || [])[0];
if (!url || !clave) { console.error('No encontré la URL o la clave pública en supabase-config.js'); process.exit(1); }

const pedir = async ruta => {
  const r = await fetch(`${url}/rest/v1/${ruta}`, { headers: { apikey: clave, Authorization: `Bearer ${clave}` } });
  if (!r.ok) throw new Error(`${ruta}: HTTP ${r.status}`);
  return r.json();
};

const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const fecha = iso => String(iso || '').slice(0, 10);

const [productos, categorias] = await Promise.all([
  pedir('productos?select=slug,updated_at&estado=eq.activo&order=slug&limit=2000'),
  pedir('categorias?select=slug&order=slug&limit=200')
]);

const conSlug = productos.filter(p => p.slug);
if (conSlug.length === 0) { console.error('El catálogo volvió vacío: no piso el sitemap.'); process.exit(1); }

const hoy = new Date().toISOString().slice(0, 10);
const urls = [
  { loc: '/', lastmod: hoy, freq: 'weekly', prio: '1.0' },
  { loc: '/productos', lastmod: hoy, freq: 'weekly', prio: '0.9' },
  { loc: '/categorias', lastmod: hoy, freq: 'weekly', prio: '0.8' },
  ...categorias.filter(c => c.slug).map(c => ({ loc: `/categorias/${c.slug}`, lastmod: hoy, freq: 'weekly', prio: '0.8' })),
  ...conSlug.map(p => ({ loc: `/producto/${p.slug}`, lastmod: fecha(p.updated_at) || hoy, freq: 'monthly', prio: '0.6' }))
];

const repetidas = urls.length - new Set(urls.map(u => u.loc)).size;
if (repetidas) { console.error(`Hay ${repetidas} URLs repetidas: no escribo.`); process.exit(1); }

const xml = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls.map(u => `  <url><loc>${esc(SITIO + u.loc)}</loc><lastmod>${u.lastmod}</lastmod><changefreq>${u.freq}</changefreq><priority>${u.prio}</priority></url>`).join('\n')}
</urlset>
`;
fs.writeFileSync(path.join(RAIZ, 'sitemap.xml'), xml);
console.log(`sitemap.xml: ${urls.length} URLs (${categorias.length} categorías, ${conSlug.length} fichas de producto)`);
