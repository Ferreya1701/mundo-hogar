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

// ── CRM: lógica pura de admin/crm.html ───────────────────────────
// (la base del CRM se prueba aparte, contra Postgres real: test-crm-sql.mjs)
const CRM = path.join(RAIZ, 'admin', 'crm.html');
const crm = new Function(
  extraer(CRM, /^\/\* ══ LÓGICA PURA DEL CRM/, /^\/\* ══ FIN DE LA LÓGICA PURA/) + `
  return { leerURL, estadoAQuery, telClave, waNumero, parseMonto, hoyISO, sumarDias, diasEntre,
           vencimiento, paraHoy, kpis, coincide, plantillaWA, mensajeError, faltaInstalar,
           ETAPAS, PLANTILLA_POR_ETAPA };`
)();

grupo('CRM · estado en la URL');
t('vacía = "Para hoy"', crm.leerURL(''), { vista:'hoy', q:'', canal:'', etapa:'', arch:'', op:'', c:'' });
t('round-trip', crm.leerURL('?' + crm.estadoAQuery({ vista:'embudo', q:'maría', canal:'instagram', etapa:'cotizado', arch:'', op:'15', c:'' })),
  { vista:'embudo', q:'maría', canal:'instagram', etapa:'cotizado', arch:'', op:'15', c:'' });
t('los valores por defecto no ensucian la URL', crm.estadoAQuery(crm.leerURL('?vista=hoy')), '');
t('vista basura', crm.leerURL('?vista=borrar').vista, 'hoy');
t('etapa basura', crm.leerURL('?etapa=xx').etapa, '');
t('canal basura', crm.leerURL('?canal=tiktok').canal, '');
t('ficha con id no numérico', crm.leerURL('?op=1;drop').op, '');
t('archivados solo "1"', crm.leerURL('?arch=2').arch, '');
t('búsqueda larguísima se recorta', crm.leerURL('?q=' + 'x'.repeat(200)).q.length, 80);

grupo('CRM · teléfonos');
t('celular internacional', crm.telClave('+54 9 342 648-1326'), '3426481326');
t('local con 0 y 15', crm.telClave('0342 15 648-1326'), '3426481326');
t('Buenos Aires con 15', crm.telClave('11 15 1234 5678'), '1112345678');
t('muy corto = sin clave', crm.telClave('1234'), null);
t('WhatsApp desde formato local', crm.waNumero('0342 15 648-1326'), '5493426481326');
t('WhatsApp ya internacional', crm.waNumero('+54 9 342 648-1326'), '5493426481326');
t('WhatsApp de otro país, tal cual', crm.waNumero('+1 305 555 1234'), '13055551234');
t('WhatsApp sin teléfono', crm.waNumero(''), null);

grupo('CRM · montos como se escriben acá');
t('"250.000"', crm.parseMonto('250.000'), '250000');
t('"$ 250.000"', crm.parseMonto('$ 250.000'), '250000');
t('"1.500,50"', crm.parseMonto('1.500,50'), '1500.50');
t('"1.234.567"', crm.parseMonto('1.234.567'), '1234567');
t('"89999"', crm.parseMonto('89999'), '89999');
t('"12.50" es decimal', crm.parseMonto('12.50'), '12.50');
t('vacío', crm.parseMonto('  '), '');
t('negativo = inválido', crm.parseMonto('-5'), null);
t('texto = inválido', crm.parseMonto('abc'), null);

grupo('CRM · fechas del próximo paso');
t('fin de año', crm.sumarDias('2026-12-31', 1), '2027-01-01');
t('marzo hacia atrás', crm.sumarDias('2026-03-01', -1), '2026-02-28');
t('días entre fechas', crm.diasEntre('2026-10-07', '2026-10-20'), 13);
t('hoy en hora local (23:59 sigue siendo hoy)', crm.hoyISO(new Date(2026, 9, 7, 23, 59)), '2026-10-07');
const HOY = '2026-10-07';
t('venció hace 2 días', crm.vencimiento('2026-10-05', HOY), { clase:'vencida', texto:'Venció hace 2 días' });
t('venció ayer', crm.vencimiento('2026-10-06', HOY).texto, 'Venció ayer');
t('hoy', crm.vencimiento(HOY, HOY), { clase:'hoy', texto:'Hoy' });
t('mañana', crm.vencimiento('2026-10-08', HOY).texto, 'Mañana');
t('en 3 días', crm.vencimiento('2026-10-10', HOY).texto, 'En 3 días');
t('más adelante: la fecha', crm.vencimiento('2026-10-20', HOY), { clase:'futura', texto:'20/10' });
t('sin fecha', crm.vencimiento(null, HOY).clase, 'sin');

grupo('CRM · "Para hoy"');
const OPS = [
  { id:'a', etapa:'nueva',      proxima_accion_fecha:null,         created_at:'2026-10-07T10:00:00Z' },
  { id:'b', etapa:'contactado', proxima_accion_fecha:'2026-10-04', created_at:'2026-10-01T10:00:00Z' },
  { id:'c', etapa:'cotizado',   proxima_accion_fecha:HOY,          created_at:'2026-10-02T10:00:00Z' },
  { id:'d', etapa:'cotizado',   proxima_accion_fecha:'2026-10-09', created_at:'2026-10-02T10:00:00Z' },
  { id:'e', etapa:'ganada',     proxima_accion_fecha:null,         created_at:'2026-10-02T10:00:00Z' },
  { id:'f', etapa:'nueva',      proxima_accion_fecha:null,         created_at:'2026-10-06T10:00:00Z' },
  { id:'g', etapa:'contactado', proxima_accion_fecha:null,         created_at:'2026-10-03T10:00:00Z' }
];
t('vencidos, hoy y nuevas sin agendar (la que más espera primero)', crm.paraHoy(OPS, HOY).map(o => o.id), ['b', 'c', 'f', 'a']);
t('lo agendado a futuro y lo cerrado no entra', crm.paraHoy(OPS, HOY).some(o => ['d', 'e', 'g'].includes(o.id)), false);

grupo('CRM · indicadores');
const AHORA = Date.parse('2026-10-07T12:00:00Z');
const K = crm.kpis([
  ...OPS.map(o => ({ ...o, monto: o.id === 'c' ? 100000 : null })),
  { id:'h', etapa:'ganada',  monto:250000, cerrada_at:'2026-10-01T10:00:00Z' },
  { id:'i', etapa:'ganada',  monto:50000,  cerrada_at:'2026-08-01T10:00:00Z' },   // hace más de 30 días
  { id:'j', etapa:'perdida', monto:null,   cerrada_at:'2026-10-05T10:00:00Z' }
], HOY, AHORA);
t('para hoy', K.paraHoy, 4);
t('vencidos', K.vencidas, 1);
t('sin responder', K.sinResponder, 2);
t('en curso (las 6 abiertas)', K.enCurso, 6);
t('monto en curso', K.montoEnCurso, 100000);
t('ganadas en 30 días (la vieja no cuenta)', [K.ganadas30, K.montoGanado30], [1, 250000]);
t('tasa de cierre', K.tasa30, 50);
t('sin cierres = sin tasa (no 0%)', crm.kpis([], HOY, AHORA).tasa30, null);

grupo('CRM · búsqueda');
const JUAN = { nombre:'Juan Pérez', telefono:'+54 9 342 648-1326', instagram:'juancho', comercio:null };
t('sin tildes', crm.coincide(null, { nombre:'María Gómez' }, 'maria'), true);
t('por teléfono escrito distinto', crm.coincide(null, JUAN, '648-1326'), true);
t('3 dígitos no alcanzan para buscar por teléfono', crm.coincide(null, JUAN, '342'), false);
t('por código de pedido', crm.coincide({ titulo:'Pedido', solicitudes:{ codigo:'MH-261007-AB12' } }, JUAN, 'mh-261007'), true);
t('por qué busca', crm.coincide({ titulo:'Freidora de aire' }, JUAN, 'FREIDORA'), true);
t('por Instagram', crm.coincide(null, JUAN, 'juancho'), true);
t('búsqueda vacía = todo', crm.coincide(null, JUAN, '  '), true);

grupo('CRM · mensajes sugeridos de WhatsApp');
const msgs = ['saludo', 'cotizacion', 'seguimiento', 'gracias'].map(tp => crm.plantillaWA(tp, { nombre:'Juan Pérez', titulo:'Freidora de aire', monto:null }));
t('nunca dicen "undefined" ni "null"', msgs.some(m => /undefined|null|NaN/.test(m)), false);
t('saludan por el primer nombre', msgs.every(m => m.startsWith('¡Hola Juan!')), true);
t('precio con formato', crm.plantillaWA('cotizacion', { nombre:'Ana', titulo:'Mesa', monto:250000 }).includes('$'), true);
t('sin precio pide completarlo', crm.plantillaWA('cotizacion', { nombre:'Ana', titulo:'Mesa' }).includes('(completá el precio)'), true);
t('pedido web: habla del pedido', crm.plantillaWA('saludo', { nombre:'Ana', titulo:'Pedido MH-261007-AB12 · consulta mayorista' }).includes('tu pedido *MH-261007-AB12*'), true);
t('sin nombre', crm.plantillaWA('saludo', { nombre:'', titulo:'' }).startsWith('¡Hola!'), true);
t('cada etapa tiene su mensaje por defecto', Object.keys(crm.ETAPAS).every(k => crm.PLANTILLA_POR_ETAPA[k]), true);

grupo('CRM · errores en criollo (nunca el mensaje técnico)');
t('pedido vinculado: la pista de la base', crm.mensajeError({ message:'etapa_por_pedido', hint:'Esta oportunidad viene de un pedido.' }), 'Esta oportunidad viene de un pedido.');
t('teléfono duplicado', crm.mensajeError({ code:'23505', message:'duplicate key value violates unique constraint "uq_crm_contactos_tel"' }).startsWith('Ya hay otro contacto'), true);
t('sin permiso', crm.mensajeError({ code:'42501', message:'new row violates row-level security policy' }), 'No tenés permiso para hacer esto.');
t('sin conexión', crm.mensajeError({ message:'TypeError: Failed to fetch' }).startsWith('Sin conexión'), true);
t('dato inválido', crm.mensajeError({ code:'23514', message:'new row for relation "crm_contactos" violates check constraint' }).includes('relation'), false);
t('cualquier otro', crm.mensajeError({ message:'XX000 internal' }), 'No se pudo guardar. Probá de nuevo en un momento.');
t('falta instalar: tabla inexistente', crm.faltaInstalar({ code:'PGRST205', message:"Could not find the table 'public.crm_contactos' in the schema cache" }), true);
t('falta instalar: función inexistente', crm.faltaInstalar({ code:'PGRST202', message:'Could not find the function public.crm_nueva_consulta(p)' }), true);
t('otro error no es "falta instalar"', crm.faltaInstalar({ code:'42501', message:'permission denied' }), false);

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
