/**
 * Pruebas del ticket de compra y del recibo (admin/js/impresion.js) y de los
 * datos fiscales (sql/017-datos-fiscales.sql).
 *
 *   npm i --no-save --prefix scripts @electric-sql/pglite   (una sola vez)
 *   node scripts/test-ticket.mjs
 *
 * El HTML se arma con las funciones REALES de impresion.js (se carga el
 * archivo tal cual en un contexto aislado), sin imprimir nada.
 */
import fs from 'fs';
import path from 'path';
import vm from 'vm';
import { fileURLToPath, pathToFileURL } from 'url';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const leerSQL = f => fs.readFileSync(path.join(RAIZ, 'sql', f), 'utf8');

let ok = 0, fail = 0;
const grupo = n => console.log(`\n— ${n} —`);
const t = (nombre, real, esperado) => {
  const a = JSON.stringify(real), b = JSON.stringify(esperado);
  if (a === b) { ok++; console.log('  OK   ' + nombre); }
  else { fail++; console.log(`  FALLA ${nombre}\n        esperado: ${b}\n        obtenido: ${a}`); }
};
const tiene = (nombre, html, texto) => t(nombre, html.includes(texto) ? 'está' : 'no está', 'está');
const noTiene = (nombre, html, texto) => t(nombre, html.includes(texto) ? 'está' : 'no está', 'no está');

// ── impresion.js en un contexto aislado ──
const ctx = { window: {}, console, Intl, Date };
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(path.join(RAIZ, 'admin/js/impresion.js'), 'utf8') + '\n;this.MHImprimir = MHImprimir;', ctx);
const { ticket, recibo, cuitFmt, fechaHora } = ctx.MHImprimir._html;

const TIENDA = {
  nombre_tienda: 'Mundo Hogar', cuit: '20356530781', domicilio_fiscal: 'Blas Parera 9961',
  ingresos_brutos: '0116724067', inicio_actividades: '2015-07-01', condicion_iva: 'responsable_inscripto',
  horarios: 'Lun a Sáb 9 a 20', _origen: 'https://mundohogarstf.com',
};
const VENTA = {
  codigo: 'VL-261111-0007', fecha: '2026-11-11T16:23:46Z',   // 13:23:46 en Argentina
  cliente_nombre: 'Juan Pérez', retira_nombre: 'María Pérez', vendedor_nombre: 'Vero',
  medio_pago: 'efectivo', subtotal: 57000, descuento: 0, total: 57000,
  items: [{ nombre: 'Freidora de aire 5L', cantidad: 1, precio_unitario: 45000, subtotal: 45000, orden: 0 },
          { nombre: 'Termo <1L>', cantidad: 2, precio_unitario: 6000, subtotal: 12000, orden: 1 }],
};

grupo('Formatos');
t('CUIT con guiones', cuitFmt('20356530781'), '20-35653078-1');
t('fecha y hora de Argentina con segundos', fechaHora('2026-11-11T16:23:46Z'), '11/11/2026 13:23:46');

grupo('Ticket de compra');
const h = ticket(VENTA, TIENDA);
tiene('logo', h, '<img class="logo" src="https://mundohogarstf.com/images/marca/logo-mundo-hogar.png"');
tiene('nombre', h, '<h1>Mundo Hogar</h1>');
tiene('CUIT', h, 'CUIT: 20-35653078-1');
tiene('domicilio', h, 'Blas Parera 9961');
tiene('ingresos brutos', h, 'Ing. Brutos: 0116724067');
tiene('inicio de actividades', h, 'Inicio de actividades: 01/07/2015');
tiene('IVA', h, 'IVA Responsable Inscripto');
tiene('fecha y hora', h, 'Fecha: 11/11/2026 13:23:46');
tiene('cliente', h, 'Cliente: <b>Juan Pérez</b>');
tiene('quién retira', h, 'Retira: <b>María Pérez</b>');
tiene('producto con precio', h, 'Freidora de aire 5L');
tiene('cantidad × precio', h, '2 × $ 6.000');
tiene('total', h, '<tr class="tot"><td>TOTAL</td><td class="r">$ 57.000</td></tr>');
tiene('nombre escapado (no rompe el HTML)', h, 'Termo &lt;1L&gt;');
t('orden: logo → nombre → CUIT → domicilio → IIBB → inicio → IVA → fecha → cliente → productos → total',
  ['logo-mundo-hogar', '<h1>', 'CUIT:', 'Blas Parera', 'Ing. Brutos', 'Inicio de actividades', 'IVA Responsable', 'Fecha:', 'Cliente:', 'Freidora', 'TOTAL']
    .map(x => h.indexOf(x)).every((v, i, a) => v >= 0 && (i === 0 || v > a[i - 1])), true);
tiene('aclara que no es factura', h, 'no válido como factura');
const sinRetira = ticket({ ...VENTA, retira_nombre: '', cliente_nombre: '' }, TIENDA);
noTiene('sin "retira" no se imprime la línea', sinRetira, 'Retira:');
tiene('sin cliente: consumidor final', sinRetira, 'Consumidor final');
tiene('venta anulada marcada', ticket({ ...VENTA, estado: 'anulada' }, TIENDA), 'VENTA ANULADA');
const sinFiscales = ticket(VENTA, { nombre_tienda: 'Mundo Hogar', direccion: 'Santa Fe' });
noTiene('sin sql/017: no imprime "CUIT:" vacío', sinFiscales, 'CUIT:');
tiene('sin sql/017: usa la dirección común', sinFiscales, 'Santa Fe');

grupo('Recibo');
const r = recibo({ numero: 'R-000012', fecha: '2026-11-11T16:23:46Z', cliente_nombre: 'Juan Pérez', monto: 30000,
                   medio_pago: 'transferencia', saldo_anterior: 80000, saldo_actual: 50000, concepto: 'Pago cuenta corriente' }, TIENDA);
tiene('dice RECIBO', r, '<div class="tipo">RECIBO</div>');
tiene('mismo encabezado fiscal', r, 'CUIT: 20-35653078-1');
tiene('de quién', r, 'Recibimos de: <b>Juan Pérez</b>');
tiene('saldo anterior', r, 'Saldo anterior</td><td class="r">$ 80.000');
tiene('saldo actual', r, 'SALDO ACTUAL</td><td class="r">$ 50.000');
tiene('lugar para firmar', r, 'Firma y aclaración');
noTiene('sin saldo no se muestra la cuenta', recibo({ cliente_nombre: 'X', monto: 1 }, TIENDA), 'SALDO ACTUAL');

grupo('Cierre de caja');
const cierre = ctx.MHImprimir._html.cierreCaja({
  sesion: { abierta_en: '2026-11-11T12:00:00Z', abierta_por_nombre: 'Vero', cerrada_en: '2026-11-11T23:00:00Z', cerrada_por_nombre: 'Vero',
            efectivo_contado: 12000, diferencia: -900, retiro: 7000, fondo_siguiente: 5000, notas_cierre: 'faltó un vuelto' },
  efectivo: { inicial: 10000, ingresos: 7500, egresos: 4600, esperado: 12900 },
  por_medio: [{ medio: 'efectivo', neto: 2900 }, { medio: 'transferencia', neto: 3000 }],
  ventas: { cantidad: 3, total: 9500 },
}, [{ origen: 'manual', concepto_nombre: 'Compras menores', descripcion: 'Bolsas', medio_pago: 'efectivo', tipo: 'egreso', monto: 2000 },
    { origen: 'venta', venta_id: 1, concepto_nombre: 'Venta', medio_pago: 'efectivo', tipo: 'ingreso', monto: 5000 },
    { origen: 'cierre', concepto_nombre: 'Retiro al cierre', medio_pago: 'efectivo', tipo: 'egreso', monto: 7000 }], TIENDA);
tiene('título', cierre, 'CIERRE DE CAJA');
tiene('esperado', cierre, 'Esperado</td><td class="r">$ 12.900');
tiene('contado', cierre, 'Contado</td><td class="r">$ 12.000');
tiene('faltante', cierre, 'Diferencia</td><td class="r">−$ 900');
tiene('fondo que queda', cierre, 'Fondo que queda</td><td class="r">$ 5.000');
tiene('otros medios', cierre, 'Transferencia</td><td class="r">$ 3.000');
tiene('egreso manual con detalle', cierre, 'Compras menores · Bolsas');
noTiene('las ventas no se listan una por una', cierre, '<td colspan="2">Venta');
noTiene('el retiro no se repite como egreso', cierre, 'Retiro al cierre');

grupo('Montos escritos a mano (caja.html)');
const cajaHtml = fs.readFileSync(path.join(RAIZ, 'admin/caja.html'), 'utf8');
const fuenteNum = cajaHtml.match(/const num = v => \{[\s\S]*?\n\};/)[0];
const num = new Function(fuenteNum + '; return num;')();
t('"12.500" → 12500', num('12.500'), 12500);
t('"12500,50" → 12500.5', num('12500,50'), 12500.5);
t('"12.500,50" → 12500.5', num('12.500,50'), 12500.5);
t('"12500.5" → 12500.5', num('12500.5'), 12500.5);
t('"$ 1.200.000" → 1200000', num('$ 1.200.000'), 1200000);
t('"0" → 0', num('0'), 0);
t('vacío → no es número', Number.isNaN(num('')), true);
t('texto → no es número', Number.isNaN(num('mil')), true);

// ── sql/017 ──
grupo('sql/017 — datos fiscales');
let PGlite;
try { ({ PGlite } = await import('@electric-sql/pglite')); }
catch (_) {
  if (!process.env.PGLITE_DIR) { console.log('Falta PGlite: npm i --no-save --prefix scripts @electric-sql/pglite'); process.exit(2); }
  ({ PGlite } = await import(pathToFileURL(path.join(process.env.PGLITE_DIR, 'node_modules/@electric-sql/pglite/dist/index.js')).href));
}
const db = new PGlite();
await db.exec(`
CREATE SCHEMA auth;
CREATE TABLE auth.users (id UUID PRIMARY KEY, email TEXT, raw_user_meta_data JSONB DEFAULT '{}'::jsonb);
CREATE FUNCTION auth.uid() RETURNS UUID LANGUAGE sql STABLE AS $f$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $f$;
CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN;
GRANT USAGE ON SCHEMA public, auth TO anon, authenticated;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated;
`);
await db.exec(leerSQL('001-schema.sql').replace(/CREATE EXTENSION[^;]*;/i, '').replace(/CREATE INDEX[^;]*gin_trgm_ops[^;]*;/gi, ''));
await db.exec(leerSQL('012-cobros.sql').split('-- 1)')[0]);   // solo la parte de site_settings
let err = null, fila;
try { await db.exec(leerSQL('017-datos-fiscales.sql')); fila = (await db.exec(leerSQL('017-datos-fiscales.sql'))).at(-1).rows[0]; } catch (e) { err = e.message; }
t('017 corre limpio, dos veces seguidas', err, null);
t('carga los datos del negocio', fila && { ...fila, inicio_actividades: fila.inicio_actividades?.toISOString().slice(0, 10) },
  { nombre_tienda: null, cuit: '20356530781', domicilio_fiscal: 'Blas Parera 9961', ingresos_brutos: '0116724067', inicio_actividades: '2015-07-01', condicion_iva: 'responsable_inscripto' });
await db.exec(`UPDATE site_settings SET domicilio_fiscal = 'Otra 123' WHERE id = 1`);
await db.exec(leerSQL('017-datos-fiscales.sql'));
t('volver a correrlo no pisa lo editado', (await db.query(`SELECT domicilio_fiscal FROM site_settings`)).rows[0].domicilio_fiscal, 'Otra 123');
const rechaza = async (nombre, sql) => { try { await db.exec(sql); t(nombre, 'aceptó', 'rechazó'); } catch (e) { t(nombre, 'rechazó', 'rechazó'); } };
await rechaza('CUIT con dígito verificador mal', `UPDATE site_settings SET cuit = '20356530782'`);
await rechaza('CUIT con guiones (se guarda solo números)', `UPDATE site_settings SET cuit = '20-35653078-1'`);
await rechaza('condición de IVA inventada', `UPDATE site_settings SET condicion_iva = 'consumidor_final'`);
t('fn_cuit_valido con CUITs reales', (await db.query(`SELECT fn_cuit_valido('20356530781') a, fn_cuit_valido('30500010912') b, fn_cuit_valido('2035653078') c`)).rows[0], { a: true, b: true, c: false });

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
