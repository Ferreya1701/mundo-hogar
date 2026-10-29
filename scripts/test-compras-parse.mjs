/**
 * Pruebas del parseo de listas de compra (admin/compras.html): separadores,
 * listas simples, detección de columnas y números en formato argentino.
 * Extrae las funciones del HTML real (como test-admin.mjs): si cambia la
 * lógica, se prueba la versión nueva.
 *
 *   node scripts/test-compras-parse.mjs
 */
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const html = fs.readFileSync(path.join(RAIZ, 'admin', 'compras.html'), 'utf8');
function bloque(desde, hasta) {
  const i = html.indexOf(desde); if (i < 0) throw new Error('No se encontró ' + desde);
  const j = html.indexOf(hasta, i); return html.slice(i, j);
}
const src = [
  "const norm = s => String(s||'').toLowerCase().normalize('NFD').replace(/[\\u0300-\\u036f]/g,'');",
  bloque('function parsearTexto(txt)', 'const ROLES ='),
  bloque('const ROLES =', 'function mostrarMapa()'),
].join('\n');
const api = new Function(src + '\nreturn { parsearTexto, splitCSV, num, detectarMapa, pareceEncabezado };')();

let ok = 0, fail = 0;
const t = (n, real, esperado) => { const a = JSON.stringify(real), b = JSON.stringify(esperado); if (a === b) { ok++; console.log('  OK   ' + n); } else { fail++; console.log(`  FALLA ${n}\n        esperado: ${b}\n        obtenido: ${a}`); } };

console.log('— Números —');
t('1.234,56 → 1234.56', api.num('1.234,56'), 1234.56);
t('1,234.56 → 1234.56', api.num('1,234.56'), 1234.56);
t('12,5 → 12.5', api.num('12,5'), 12.5);
t('$ 25.50 → 25.5', api.num('$ 25.50'), 25.5);
t('USD 1,200 → 1200', api.num('USD 1,200'), 1200);
t('texto → null', api.num('abc'), null);
t('vacío → null', api.num(''), null);

console.log('\n— Texto pegado —');
t('tabulado (Excel)', api.parsearTexto('Air fryer 5L\t20\t25.50\nTaladro 20V\t10\t30'), [['Air fryer 5L','20','25.50'],['Taladro 20V','10','30']]);
t('CSV con comillas', api.parsearTexto('"Freidora, 5L",20,25.5\nTaladro,10,30'), [['Freidora, 5L','20','25.5'],['Taladro','10','30']]);
t('punto y coma', api.parsearTexto('Freidora;20;25,5\nTaladro;10;30'), [['Freidora','20','25,5'],['Taladro','10','30']]);
t('lista simple "x"', api.parsearTexto('Freidora de aire 5L x 20\n10 x Taladro 20V\nTermo 1L - 6'), [['Freidora de aire 5L','20',''],['Taladro 20V','10',''],['Termo 1L','6','']]);
t('nombre cantidad costo con espacios', api.parsearTexto('Freidora de aire 5L 20 25.50'), [['Freidora de aire 5L','20','25.50']]);
t('solo nombres', api.parsearTexto('Freidora\nTaladro'), [['Freidora','',''],['Taladro','','']]);
t('líneas vacías se ignoran', api.parsearTexto('\nFreidora x 2\n\n').length, 1);

console.log('\n— Encabezado y columnas —');
const conHead = [['Item No.','Description','Qty','Unit Price (USD)'],['YW-AF5','Air fryer 5L',' 20','25.50'],['YW-DR20','Cordless drill 20V','10','30']];
t('detecta encabezado en inglés', api.pareceEncabezado(conHead), true);
t('mapa por encabezado: sku, desc, cant, costo', api.detectarMapa(conHead, true), ['sku','desc','cant','costo']);
const esp = [['Artículo','Cantidad','Costo'],['Freidora 5L','20','38250'],['Taladro','10','45000']];
t('"Artículo" es descripción (no código)', api.detectarMapa(esp, true), ['desc','cant','costo']);
const sinHead = [['Freidora de aire 5L','20','25.5'],['Taladro percutor 20V','10','30'],['Termo acero 1L','6','4.2']];
t('sin encabezado: no lo inventa', api.pareceEncabezado(sinHead), false);
t('mapa por contenido: desc, cant, costo', api.detectarMapa(sinHead, false), ['desc','cant','costo']);
const conBarras = [['7791234567890','Taladro INGCO 20V','4'],['7798888888888','Parlante BT','50']];
t('columna de 13 dígitos = código de barras', api.detectarMapa(conBarras, false), ['barras','desc','cant']);
const chino = [['货号','品名','数量','单价'],['A1','空气炸锅 5L','20','25.5']];
t('encabezados en chino', api.detectarMapa(chino, true), ['sku','desc','cant','costo']);

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
