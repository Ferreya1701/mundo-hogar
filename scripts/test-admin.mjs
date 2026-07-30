/**
 * Pruebas de la lógica del panel admin.
 *
 *   node scripts/test-admin.mjs
 *
 * No hay framework de test en el proyecto (es un sitio estático sin build) y
 * agregarlo seria cambiar el stack. En lugar de eso, este script EXTRAE las
 * funciones del HTML real en tiempo de ejecución y las prueba. Nada se copia:
 * si alguien cambia la lógica en admin/productos.html, estas pruebas prueban
 * la versión nueva o fallan al no encontrarla. No pueden quedar desfasadas.
 *
 * Cubre lo que da miedo romper: el estado de los filtros en la URL, el
 * escapado de HTML (bug real del producto id 93) y el cálculo de precios.
 */
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PRODUCTOS = path.join(RAIZ, 'admin', 'productos.html');

/** Extrae las líneas entre dos marcas del archivo real. */
function extraer(archivo, desde, hasta) {
  const lineas = fs.readFileSync(archivo, 'utf8').split(/\r?\n/);
  const i = lineas.findIndex(l => desde.test(l));
  if (i === -1) throw new Error(`No se encontró el bloque ${desde} en ${archivo}`);
  const resto = lineas.slice(i);
  const j = resto.findIndex((l, k) => k > 0 && hasta.test(l));
  return resto.slice(0, j === -1 ? undefined : j).join('\n');
}

let ok = 0, fail = 0;
const grupo = n => console.log(`\n— ${n} —`);
const t = (nombre, real, esperado) => {
  const a = JSON.stringify(real), b = JSON.stringify(esperado);
  if (a === b) { ok++; console.log('  OK   ' + nombre); }
  else { fail++; console.log(`  FALLA ${nombre}\n        esperado: ${b}\n        obtenido: ${a}`); }
};

// ── Bloque de estado del listado ─────────────────────────────────
const controles = {}, chips = [];
globalThis.document = {
  getElementById: id => (controles[id] ??= { value: '' }),
  querySelectorAll: () => chips
};
globalThis.location = { pathname: '/admin/productos.html', search: '' };
globalThis.history = {
  replaceState: (_a, _b, u) => { location.search = u.includes('?') ? '?' + u.split('?')[1] : ''; },
  pushState:    (_a, _b, u) => { location.search = u.includes('?') ? '?' + u.split('?')[1] : ''; }
};

const estado = new Function(
  extraer(PRODUCTOS, /^const DEFAULTS = /, /^function applyFilters/) + `
  return { leerURL, estadoAQuery, filtrosActivos, esc, normExtras, extrasActivos,
           REGLA_EXTRA, EXTRAS, get state(){return state}, set state(v){state=v} };`
)();
const conURL = qs => { location.search = qs; return estado.leerURL(); };

grupo('Escapado de HTML (bug del producto id 93)');
t('comilla doble', estado.esc('Smart TV Enova Google TV 50"'), 'Smart TV Enova Google TV 50&quot;');
t('etiqueta inyectada', estado.esc('<img onerror=x>'), '&lt;img onerror=x&gt;');
t('ampersand y comilla simple', estado.esc(`Ryobi & O'Brien`), 'Ryobi &amp; O&#39;Brien');

grupo('Estado en la URL');
t('vacía = valores por defecto', conURL(''), { q:'', cat:'', estado:'', stock:'', extra:'', orden:'nombre', page:1 });
t('round-trip', (() => {
  const original = { q:'sierra', cat:'5', estado:'inactivo', stock:'bajo', extra:'destacados,oferta', orden:'stock-desc', page:7 };
  estado.state = { ...original };
  location.search = '?' + estado.estadoAQuery();
  return estado.leerURL();
})(), { q:'sierra', cat:'5', estado:'inactivo', stock:'bajo', extra:'destacados,oferta', orden:'stock-desc', page:7 });

grupo('Parámetros inválidos: no deben romper la pantalla');
t('estado basura', conURL('?estado=xxx').estado, '');
t('orden basura', conURL('?orden=DROP+TABLE').orden, 'nombre');
t('categoría no numérica', conURL('?cat=abc').cat, '');
t('página negativa', conURL('?page=-5').page, 1);
t('página cero', conURL('?page=0').page, 1);
t('página texto', conURL('?page=abc').page, 1);
t('búsqueda larguísima se recorta', conURL('?q=' + 'a'.repeat(300)).q.length, 80);

grupo('Filtros rápidos combinables');
t('dos a la vez', conURL('?extra=sin-precio,destacados').extra, 'destacados,sin-precio');
t('se normaliza el orden', conURL('?extra=oferta,destacados').extra, 'destacados,oferta');
t('descarta desconocidos', conURL('?extra=sin-precio,inventado').extra, 'sin-precio');
t('quita repetidos', conURL('?extra=oferta,oferta').extra, 'oferta');
t('todo basura = vacío', conURL('?extra=,,, ,xx').extra, '');
t('cada uno cuenta por separado',
  (() => { estado.state = { ...conURL('?q=x&cat=2&extra=sin-precio,oferta') }; return estado.filtrosActivos(); })(), 4);
t('orden y página no son filtros',
  (() => { estado.state = { ...conURL('?orden=recientes&page=4') }; return estado.filtrosActivos(); })(), 0);

grupo('Compatibilidad: links viejos del dashboard y del asistente');
t('?precio=sin', conURL('?precio=sin').extra, 'sin-precio');
t('?imagen=sin', conURL('?imagen=sin').extra, 'sin-imagen');
t('?destacados=1', conURL('?destacados=1').extra, 'destacados');
t('?incompletos=1', conURL('?incompletos=1').extra, 'incompletos');
t('?cat=sin', conURL('?cat=sin').extra, 'sin-cat');
t('?cat=3 (link de categorías)', conURL('?cat=3').cat, '3');

grupo('Reglas de los filtros rápidos');
const R = estado.REGLA_EXTRA;
const prod = o => ({ precio_minorista:null, imagen_principal_url:null, categoria_id:null, destacado:false, en_oferta:false, ...o });
t('sin-precio: cero cuenta como sin precio', R['sin-precio'](prod({ precio_minorista:0 })), true);
t('sin-precio: con precio no cuenta', R['sin-precio'](prod({ precio_minorista:1500 })), false);
t('sin-imagen', R['sin-imagen'](prod({ imagen_principal_url:'/x.jpg' })), false);
t('sin-cat', R['sin-cat'](prod({ categoria_id:3 })), false);
t('destacados', R['destacados'](prod({ destacado:true })), true);
t('oferta', R['oferta'](prod({ en_oferta:true })), true);
t('completo no es incompleto', R['incompletos'](prod({ precio_minorista:100, imagen_principal_url:'/x.jpg', categoria_id:1 })), false);
t('falta la imagen → incompleto', R['incompletos'](prod({ precio_minorista:100, categoria_id:1 })), true);
t('todos los chips tienen su regla', estado.EXTRAS.every(e => typeof R[e] === 'function'), true);

// ── Cálculo de precios ───────────────────────────────────────────
const precioAjustado = new Function(
  extraer(PRODUCTOS, /^function precioAjustado/, /^}/) + '\n}\nreturn precioAjustado;'
)();

grupo('Ajuste de precios: sin precio de partida se salta');
t('null', precioAjustado(null, 'pct', 15, 0), null);
t('cero', precioAjustado(0, 'pct', 15, 0), null);
t('undefined', precioAjustado(undefined, 'pct', 15, 0), null);

grupo('Ajuste de precios: cálculo');
t('+15% sobre 1000', precioAjustado(1000, 'pct', 15, 0), 1150);
t('-10% sobre 1000', precioAjustado(1000, 'pct', -10, 0), 900);
t('+500 fijo sobre 1000', precioAjustado(1000, 'fijo', 500, 0), 1500);
t('nunca queda negativo (%)', precioAjustado(1000, 'pct', -200, 0), 0);
t('nunca queda negativo (fijo)', precioAjustado(1000, 'fijo', -1500, 0), 0);

grupo('Ajuste de precios: redondeo');
t('+15% de 12345 a $100', precioAjustado(12345, 'pct', 15, 100), 14200);
t('+15% de 12345 a $1.000', precioAjustado(12345, 'pct', 15, 1000), 14000);
t('+30% de 8990 a $100', precioAjustado(8990, 'pct', 30, 100), 11700);
t('sin redondear mantiene decimales', precioAjustado(999.99, 'pct', 10, 0), 1099.99);
t('redondear es idempotente',
  precioAjustado(precioAjustado(12345, 'pct', 15, 100), 'pct', 0, 100), 14200);

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
