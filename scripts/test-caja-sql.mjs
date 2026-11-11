/**
 * Pruebas de la caja diaria (sql/018-caja.sql) contra un Postgres REAL en
 * memoria (PGlite), sin tocar Supabase.
 *
 *   npm i --no-save --prefix scripts @electric-sql/pglite   (una sola vez)
 *   node scripts/test-caja-sql.mjs
 *
 * Corre 001..018 y prueba apertura, ventas que entran solas (efectivo y
 * otros medios), anulaciones, ingresos/egresos manuales, anulación de
 * movimientos, cierre con diferencia y fondo, permisos y que nada se edite.
 */
import fs from 'fs';
import path from 'path';
import { fileURLToPath, pathToFileURL } from 'url';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const leerSQL = f => fs.readFileSync(path.join(RAIZ, 'sql', f), 'utf8');

async function cargarPGlite() {
  try {
    const m = await import('@electric-sql/pglite');
    const t = await import('@electric-sql/pglite/contrib/pg_trgm');
    return { PGlite: m.PGlite, pg_trgm: t.pg_trgm };
  } catch (_) { /* sigue */ }
  if (process.env.PGLITE_DIR) {
    const base = path.join(process.env.PGLITE_DIR, 'node_modules', '@electric-sql', 'pglite', 'dist');
    const m = await import(pathToFileURL(path.join(base, 'index.js')).href);
    const t = await import(pathToFileURL(path.join(base, 'contrib', 'pg_trgm.js')).href);
    return { PGlite: m.PGlite, pg_trgm: t.pg_trgm };
  }
  console.log('Falta PGlite. Instalalo una vez con:\n  npm i --no-save --prefix scripts @electric-sql/pglite');
  process.exit(2);
}

let ok = 0, fail = 0;
const grupo = n => console.log(`\n— ${n} —`);
const t = (nombre, real, esperado) => {
  const a = JSON.stringify(real), b = JSON.stringify(esperado);
  if (a === b) { ok++; console.log('  OK   ' + nombre); }
  else { fail++; console.log(`  FALLA ${nombre}\n        esperado: ${b}\n        obtenido: ${a}`); }
};

const { PGlite, pg_trgm } = await cargarPGlite();
const db = new PGlite({ extensions: { pg_trgm } });

await db.exec(`
CREATE SCHEMA auth;
CREATE SCHEMA extensions;
CREATE TABLE auth.users (id UUID PRIMARY KEY, email TEXT, raw_user_meta_data JSONB DEFAULT '{}'::jsonb);
CREATE FUNCTION auth.uid() RETURNS UUID LANGUAGE sql STABLE AS
  $f$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $f$;
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
GRANT USAGE ON SCHEMA public, auth, extensions TO anon, authenticated;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated;
`);
await db.exec(leerSQL('001-schema.sql').replace(/CREATE EXTENSION[^;]*;/i, ''));
for (const f of ['002-rls-policies.sql', '005-solicitudes.sql', '007-nucleo-stock.sql', '008-blindaje-stock.sql',
                 '009-crm.sql', '010-bot-whatsapp.sql', '011-crm-conversacion.sql', '012-cobros.sql',
                 '013-local-compras-stock.sql']) {
  await db.exec(leerSQL(f));
}

const ADMIN = '00000000-0000-0000-0000-00000000000a';
const VEND  = '00000000-0000-0000-0000-00000000000b';
const STOCK = '00000000-0000-0000-0000-00000000000c';
const VEND2 = '00000000-0000-0000-0000-00000000000d';
const EX    = '00000000-0000-0000-0000-00000000000e';
await db.exec(`
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('${ADMIN}', 'ana@mh.test',    '{"nombre":"Ana Admin","rol":"administrador"}'),
  ('${VEND}',  'vero@mh.test',   '{"nombre":"Vero Ventas","rol":"vendedor"}'),
  ('${STOCK}', 'sergio@mh.test', '{"nombre":"Sergio Stock","rol":"encargado_stock"}'),
  ('${VEND2}', 'vale@mh.test',   '{"nombre":"Vale Ventas","rol":"vendedor"}'),
  ('${EX}',    'ex@mh.test',     '{"nombre":"Ex Vendedor","rol":"vendedor"}');
INSERT INTO categorias (nombre, slug) VALUES ('Electrodomésticos','electrodomesticos');
INSERT INTO productos (nombre, slug, categoria_id, precio_minorista, seguimiento_inventario, estado) VALUES
  ('Freidora de aire 5L', 'freidora', 1, 45000, true,  'activo'),
  ('Termo 1L',            'termo',    1, 12000, false, 'activo');
`);
await db.exec(leerSQL('014-accesos.sql'));
await db.exec(leerSQL('015-permisos-por-rol.sql'));
await db.exec(leerSQL('016-permisos-tildables.sql'));
await db.exec(leerSQL('017-datos-fiscales.sql'));

async function como(rol, uid, sql, params = []) {
  return db.transaction(async tx => {
    await tx.exec(`SET LOCAL ROLE ${rol}`);
    await tx.query(`SELECT set_config('request.jwt.claim.sub', $1, true)`, [uid ?? '']);
    const r = await tx.query(sql, params);
    return Object.assign(r.rows, { afectadas: r.affectedRows });
  });
}
const usuario = uid => (sql, p) => como('authenticated', uid, sql, p);
const anon  = (sql, p) => como('anon', '', sql, p);
const admin = usuario(ADMIN), vend = usuario(VEND), vend2 = usuario(VEND2), stock = usuario(STOCK), ex = usuario(EX);
const q = async (sql, p) => (await db.query(sql, p)).rows;
const cuantos = async (quien, tabla) => (await quien(`SELECT count(*)::int AS n FROM ${tabla}`))[0].n;

async function falla(nombre, fn, patron) {
  try { await fn(); t(nombre, 'no falló', 'falla con ' + patron); }
  catch (e) { t(nombre, patron.test(e.message) ? 'falló bien' : e.message, 'falló bien'); }
}
// "Pasa el control de acceso": anda, o falla por otra cosa que no es permiso
async function pasa(nombre, fn) {
  try { await fn(); t(nombre, 'pasa', 'pasa'); }
  catch (e) { t(nombre, /sin_permiso|permission denied|row-level security/.test(e.message) ? 'bloqueado: ' + e.message : 'pasa', 'pasa'); }
}


const vender = (quien, total, medio = 'efectivo', extra = {}) => quien(`SELECT venta_registrar($1::jsonb) AS r`,
  [JSON.stringify({ items: [{ producto_id: 2, cantidad: 1, precio_unitario: total }], medio_pago: medio, ...extra })]).then(r => r[0].r);
const resumen = (quien = admin, id = null) => quien(`SELECT caja_resumen($1) AS r`, [id]).then(r => r[0].r);
const esperado = async () => Number((await resumen()).efectivo.esperado);
const concepto = async nombre => (await q(`SELECT id FROM caja_conceptos WHERE nombre = $1`, [nombre]))[0].id;
const mov = (quien, tipo, concepto_id, monto, extra = {}) => quien(`SELECT caja_movimiento_registrar($1::jsonb) AS r`,
  [JSON.stringify({ tipo, concepto_id, monto, ...extra })]).then(r => r[0].r);
const movsVenta = async id => (await q(`SELECT tipo, monto::float AS monto, medio_pago, origen, sesion_id IS NOT NULL AS en_caja FROM caja_movimientos WHERE venta_id = $1 ORDER BY id`, [id]));

grupo('Migración');
let err = null, res = null;
const SQL018 = leerSQL('018-caja.sql');
try { await db.exec(SQL018); res = (await db.exec(SQL018)).at(-1).rows[0]; } catch (e) { err = e.message; }
t('018 corre limpio, dos veces seguidas', err, null);
if (err) { console.log(`\n${ok} pasadas, ${fail} fallidas\n`); process.exit(1); }
t('conceptos y permisos cargados, ninguna caja abierta', res, { conceptos: 14, permisos_caja: 6, cajas_abiertas: 0 });
t('vendedor: ver, abrir/cerrar y cargar movimientos', (await vend(`SELECT fn_mis_permisos() p`))[0].p.filter(x => x.startsWith('caja.')),
  ['caja.ver', 'caja.abrir_cerrar', 'caja.movimientos']);
t('encargado: solo ver', (await stock(`SELECT fn_mis_permisos() p`))[0].p.filter(x => x.startsWith('caja.')), ['caja.ver']);

grupo('Con la caja cerrada la venta no se frena');
t('caja_esta_abierta() = false', (await vend(`SELECT caja_esta_abierta() a`))[0].a, false);
const vPrev = await vender(vend, 1500);
t('la venta se registró', !!vPrev.codigo, true);
t('su ingreso queda pendiente (sin caja)', await movsVenta(vPrev.id), [{ tipo: 'ingreso', monto: 1500, medio_pago: 'efectivo', origen: 'venta', en_caja: false }]);
t('el resumen avisa los pendientes', (await resumen(vend)).pendientes, { cantidad: 1, efectivo: 1500 });
await falla('no se cargan egresos con la caja cerrada', async () => mov(vend, 'egreso', await concepto('Compras menores'), 100), /caja_cerrada/);

grupo('Abrir');
await falla('el encargado no abre (no tiene el permiso)', () => stock(`SELECT caja_abrir(10000)`), /sin_permiso/);
await falla('monto negativo', () => vend(`SELECT caja_abrir(-1)`), /monto_invalido/);
const ab = (await vend(`SELECT caja_abrir(10000) r`))[0].r;
t('abre con 10.000 y suma la venta pendiente', [ab.monto_inicial, ab.pendientes_sumados], [10000, 1]);
await falla('no se abre dos veces', () => vend(`SELECT caja_abrir(5000)`), /caja_ya_abierta/);
t('esperado = 10.000 + 1.500', await esperado(), 11500);

grupo('Las ventas entran solas');
const vEf = await vender(vend, 5000);
const vTr = await vender(vend, 3000, 'transferencia');
const vCC = await vender(vend, 7000, 'cuenta_corriente');
t('efectivo → ingreso en efectivo', await movsVenta(vEf.id), [{ tipo: 'ingreso', monto: 5000, medio_pago: 'efectivo', origen: 'venta', en_caja: true }]);
t('transferencia → ingreso por transferencia', await movsVenta(vTr.id), [{ tipo: 'ingreso', monto: 3000, medio_pago: 'transferencia', origen: 'venta', en_caja: true }]);
t('cuenta corriente → nada en caja', await movsVenta(vCC.id), []);
t('esperado suma solo el efectivo: 16.500', await esperado(), 16500);
const r1 = await resumen(vend);
t('resumen por medio', r1.por_medio.map(x => [x.medio, Number(x.ingresos)]), [['efectivo', 6500], ['transferencia', 3000]]);
t('resumen de ventas: 3 ventas, 9.500', [r1.ventas.cantidad, Number(r1.ventas.total)], [3, 9500]);

grupo('Anular una venta devuelve la plata por el mismo medio');
await vend(`SELECT venta_anular($1, 'se arrepintió')`, [vEf.id]);
t('egreso de devolución en efectivo', (await movsVenta(vEf.id)).map(m => [m.tipo, m.monto, m.medio_pago, m.origen]),
  [['ingreso', 5000, 'efectivo', 'venta'], ['egreso', 5000, 'efectivo', 'anulacion']]);
await vend(`SELECT venta_anular($1, 'otra vez')`, [vEf.id]);
t('anularla de nuevo no duplica la devolución', (await movsVenta(vEf.id)).length, 2);
await vend(`SELECT venta_anular($1, 'error')`, [vTr.id]);
t('la de transferencia se devuelve por transferencia', (await movsVenta(vTr.id)).at(-1).medio_pago, 'transferencia');
await vend(`SELECT venta_anular($1, 'error')`, [vCC.id]);
t('anular la de cuenta corriente no toca la caja', (await movsVenta(vCC.id)), []);
t('esperado vuelve a 11.500', await esperado(), 11500);

grupo('Ingresos y egresos manuales');
const cCompras = await concepto('Compras menores'), cOtrosE = await concepto('Otros egresos'), cVenta = await concepto('Venta');
const e1 = await mov(vend, 'egreso', cCompras, 2000, { descripcion: 'Bolsas' });
t('egreso cargado', e1.ok, true);
t('esperado 9.500', await esperado(), 9500);
await mov(vend, 'ingreso', await concepto('Aporte de efectivo'), 1000);
t('ingreso: esperado 10.500', await esperado(), 10500);
await mov(vend, 'egreso', cCompras, 800, { medio_pago: 'transferencia' });
t('un egreso por transferencia no toca el efectivo', await esperado(), 10500);
await falla('el encargado no carga movimientos', () => mov(stock, 'egreso', cCompras, 100), /sin_permiso/);
await falla('un concepto del sistema no se elige a mano', () => mov(vend, 'ingreso', cVenta, 100), /concepto_invalido/);
await falla('concepto de egreso usado como ingreso', () => mov(vend, 'ingreso', cCompras, 100), /concepto_invalido/);
await falla('"Otros" exige descripción', () => mov(vend, 'egreso', cOtrosE, 100), /descripcion_requerida/);
await falla('monto cero', () => mov(vend, 'egreso', cCompras, 0), /monto_invalido/);
await falla('monto con texto', () => mov(vend, 'egreso', cCompras, 'mil'), /monto_invalido/);

grupo('Anular un movimiento manual');
await falla('el vendedor no anula (permiso del admin)', () => vend(`SELECT caja_movimiento_anular($1, 'x')`, [e1.id]), /sin_permiso/);
await falla('sin motivo no se anula', () => admin(`SELECT caja_movimiento_anular($1, '  ')`, [e1.id]), /motivo_requerido/);
await admin(`SELECT caja_movimiento_anular($1, 'se cargó dos veces')`, [e1.id]);
t('el original queda marcado y aparece el inverso',
  await q(`SELECT tipo, monto::float m, anulado, revierte_a_id IS NOT NULL AS inverso FROM caja_movimientos WHERE id = $1 OR revierte_a_id = $1 ORDER BY id`, [e1.id]),
  [{ tipo: 'egreso', m: 2000, anulado: true, inverso: false }, { tipo: 'ingreso', m: 2000, anulado: false, inverso: true }]);
t('esperado 12.500', await esperado(), 12500);
const movVenta = (await q(`SELECT id FROM caja_movimientos WHERE venta_id = $1 LIMIT 1`, [vEf.id]))[0].id;
await falla('un movimiento de venta no se anula desde la caja', () => admin(`SELECT caja_movimiento_anular($1, 'x')`, [movVenta]), /no_anulable/);

grupo('Nada se edita ni se borra');
await falla('UPDATE directo desde el panel', () => admin(`UPDATE caja_movimientos SET monto = 1 WHERE id = $1`, [e1.id]), /permission denied|caja_inmutable/);
await falla('DELETE directo desde el panel', () => admin(`DELETE FROM caja_movimientos WHERE id = $1`, [e1.id]), /permission denied|caja_inmutable/);
await falla('ni siquiera el dueño de la base sin pasar por las funciones', () => q(`UPDATE caja_movimientos SET monto = 1 WHERE id = $1`, [e1.id]), /caja_inmutable/);
await falla('ni borrar una sesión', () => q(`DELETE FROM caja_sesiones`), /caja_inmutable/);
await falla('INSERT directo desde el panel', () => vend(`INSERT INTO caja_movimientos (tipo, concepto_id, concepto_nombre, monto, origen) VALUES ('ingreso', 1, 'x', 1, 'manual')`), /permission denied|row-level/);

grupo('Quién ve la caja');
t('vendedor y encargado ven la caja del día', [await cuantos(vend, 'caja_sesiones'), await cuantos(stock, 'caja_sesiones')], [1, 1]);
t('y sus movimientos', (await cuantos(stock, 'caja_movimientos')) > 0, true);
await admin(`SELECT permisos_rol_guardar('encargado_stock', ARRAY['ventas.crear'])`);
t('sin "ver la caja", el encargado no ve nada', [await cuantos(stock, 'caja_sesiones'), await cuantos(stock, 'caja_movimientos')], [0, 0]);
await falla('ni el resumen', () => resumen(stock), /sin_permiso/);
t('pero sus ventas siguen entrando a la caja', (await movsVenta((await vender(stock, 400)).id)).length, 1);
await q(`UPDATE profiles SET activo = false WHERE id = $1`, [EX]);
await falla('cuenta desactivada no ve nada', () => resumen(ex), /sin_permiso/);
await falla('anónimo tampoco', () => anon(`SELECT * FROM caja_movimientos`), /permission denied/);

grupo('Cerrar');
const esp = await esperado();   // 12.900
t('esperado antes de cerrar 12.900', esp, 12900);
await falla('falta plata y no explica → no cierra', () => vend(`SELECT caja_cerrar(12000, 5000)`), /nota_requerida/);
await falla('fondo mayor que lo contado', () => vend(`SELECT caja_cerrar(12900, 13000)`), /fondo_invalido/);
await falla('el encargado no cierra', () => stock(`SELECT caja_cerrar(12900, 5000)`), /sin_permiso/);
const c1 = (await vend(`SELECT caja_cerrar(12000, 5000, 'faltó un vuelto') r`))[0].r;
t('cierra: esperado, contado, diferencia, retiro, fondo', [c1.esperado, c1.contado, c1.diferencia, c1.retiro, c1.fondo], [12900, 12000, -900, 7000, 5000]);
t('el faltante y el retiro quedan como movimientos de cierre',
  await q(`SELECT tipo, concepto_nombre c, monto::float m FROM caja_movimientos WHERE origen = 'cierre' ORDER BY id`),
  [{ tipo: 'egreso', c: 'Faltante de caja', m: 900 }, { tipo: 'egreso', c: 'Retiro al cierre', m: 7000 }]);
t('la sesión queda cerrada con quién y cuándo', (await q(`SELECT estado, cerrada_por_nombre, notas_cierre FROM caja_sesiones WHERE id = $1`, [ab.sesion_id]))[0],
  { estado: 'cerrada', cerrada_por_nombre: 'Vero Ventas', notas_cierre: 'faltó un vuelto' });
await falla('no se cierra dos veces', () => vend(`SELECT caja_cerrar(1, 0)`), /caja_cerrada/);
t('queda en el historial', (await q(`SELECT count(*)::int n FROM historial_actividad WHERE entidad = 'caja'`))[0].n, 2);

grupo('Al día siguiente');
const vNoche = await vender(vend, 600);
t('venta después del cierre: pendiente', (await movsVenta(vNoche.id))[0].en_caja, false);
t('el resumen sugiere el fondo que quedó', Number((await resumen(vend)).ultimo_fondo), 5000);
await falla('abrir con otro monto sin explicar', () => vend(`SELECT caja_abrir(4000)`), /nota_requerida/);
const ab2 = (await vend(`SELECT caja_abrir(5000) r`))[0].r;
t('abre con el fondo y suma la venta de la noche', [ab2.fondo_anterior, ab2.pendientes_sumados], [5000, 1]);
t('esperado 5.600', await esperado(), 5600);
// la caja de ayer pasa a ser "de otro día"
await q(`SELECT set_config('mh.caja','1',false)`);
await q(`UPDATE caja_sesiones SET abierta_en = abierta_en - interval '1 day', cerrada_en = cerrada_en - interval '1 day' WHERE id = $1`, [ab.sesion_id]);
await q(`SELECT set_config('mh.caja','',false)`);
t('el vendedor ya no ve la caja de ayer (solo la de hoy)', (await vend(`SELECT array_agg(id) ids FROM caja_sesiones`))[0].ids, [ab2.sesion_id]);
await falla('ni su resumen', () => resumen(vend, ab.sesion_id), /sin_permiso/);
t('el admin ve las dos', await cuantos(admin, 'caja_sesiones'), 2);
await admin(`SELECT permisos_rol_guardar('vendedor', (SELECT array_agg(permiso) FROM rol_permisos WHERE rol = 'vendedor') || ARRAY['caja.historial'])`);
t('con "ver cajas anteriores" el vendedor ve las dos', await cuantos(vend, 'caja_sesiones'), 2);
t('y el resumen de ayer', Number((await resumen(vend, ab.sesion_id)).sesion.diferencia), -900);

grupo('Conceptos');
await falla('el vendedor no crea conceptos', () => vend(`INSERT INTO caja_conceptos (nombre, tipo) VALUES ('Café', 'egreso')`), /row-level/);
await pasa('el admin sí', () => admin(`INSERT INTO caja_conceptos (nombre, tipo) VALUES ('Café', 'egreso')`));
await falla('ni el admin toca uno del sistema', () => admin(`UPDATE caja_conceptos SET nombre = 'x' WHERE clave = 'venta'`).then(r => { if (!r.afectadas) throw new Error('row-level: 0 filas'); }), /row-level/);
await admin(`UPDATE caja_conceptos SET nombre = 'Compras chicas' WHERE id = $1`, [cCompras]);
t('renombrar un concepto no cambia los movimientos viejos', (await q(`SELECT concepto_nombre FROM caja_movimientos WHERE id = $1`, [e1.id]))[0].concepto_nombre, 'Compras menores');

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
