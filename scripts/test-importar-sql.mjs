/**
 * Pruebas del importador de artículos del sistema anterior
 * (sql/021-importar-articulos.sql) contra un Postgres REAL en memoria (PGlite).
 *
 *   npm i --no-save --prefix scripts @electric-sql/pglite   (una sola vez)
 *   node scripts/test-importar-sql.mjs
 *
 * Prueba: alta inactiva con SKU = código viejo, stock de referencia sin
 * contar (negativos → 0), reimportar sin duplicar, vincular a un producto que
 * ya existía, choque de SKU, lista de precios posterior, errores por renglón
 * y permisos.
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
await db.exec(leerSQL('018-caja.sql'));
await db.exec(leerSQL('019-cuentas-corrientes.sql'));
await db.exec(leerSQL('020-editar-venta.sql'));
await db.exec(`INSERT INTO categorias (nombre, slug) VALUES ('Celulares','celulares');
               INSERT INTO productos (nombre, slug, categoria_id, precio_minorista, seguimiento_inventario, estado)
               VALUES ('Celular X', 'celular-x', 2, 300000, false, 'activo');`);

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





const imp = (quien, items) => quien(`SELECT productos_importar($1::jsonb) r`, [JSON.stringify({ items })]).then(r => r[0].r);
const prod = async cod => (await q(`SELECT p.id, p.nombre, p.sku, p.estado, p.marca, p.categoria_id, p.precio_minorista::float precio, p.stock_actual, p.stock_controlado, c.proveedor
  FROM productos p LEFT JOIN producto_costos c ON c.producto_id = p.id WHERE lower(p.codigo_anterior) = lower($1)`, [cod]))[0];

grupo('Migración');
let err = null;
const SQL021 = leerSQL('021-importar-articulos.sql');
try { await db.exec(SQL021); await db.exec(SQL021); } catch (e) { err = e.message; }
t('021 corre limpio, dos veces seguidas', err, null);
if (err) { console.log(`\n${ok} pasadas, ${fail} fallidas\n`); process.exit(1); }

grupo('Permisos');
await falla('el vendedor no importa', () => imp(vend, [{ codigo: '001', nombre: 'X' }]), /sin_permiso/);
await falla('lote vacío', () => imp(admin, []), /items_invalidos/);

grupo('Primera importación');
await q(`UPDATE productos SET sku = 'TERMO1' WHERE id = 2`);
const r1 = await imp(stock, [
  { codigo: '001', nombre: 'CELULAR REDMI A5 64GB 3RAM', marca: 'XIAOMI', categoria_id: 2, stock: 17 },
  { codigo: '4909', nombre: 'PAVA TERMO MATE', marca: 'ULTRACOMB', categoria_id: 1, stock: -2 },
  { codigo: '238', nombre: 'tender ropa', proveedor: 'BUENOS AIRES', stock: 3 },
  { codigo: 'termo1', nombre: 'Algo con código igual a un SKU', stock: 0 },
  { codigo: '', nombre: 'sin código' },
  { codigo: '999', nombre: 'x' },
]);
t('3 nuevos + 1 con SKU ocupado, 2 errores sin frenar el resto', [r1.creados, r1.errores], [4, 2]);
const cel = await prod('001');
t('nuevo: inactivo, SKU = código viejo, marca y categoría', [cel.estado, cel.sku, cel.marca, cel.categoria_id], ['inactivo', '001', 'XIAOMI', 2]);
t('stock 17 como referencia, sin contar', [cel.stock_actual, cel.stock_controlado], [17, false]);
t('quedó el movimiento de carga inicial', (await q(`SELECT tipo, cantidad, motivo FROM movimientos_inventario WHERE producto_id = $1`, [cel.id])),
  [{ tipo: 'carga_inicial', cantidad: 17, motivo: 'Stock del sistema anterior' }]);
t('negativo → 0', (await prod('4909')).stock_actual, 0);
t('el "origen" va como proveedor (aparte, no a la vista de la tienda)', (await prod('238')).proveedor, 'BUENOS AIRES');
t('si el código ya es SKU de otro producto, recibe un MH- nuevo', (await prod('termo1')).sku.startsWith('MH-'), true);
t('los errores dicen qué renglón y por qué', r1.items.filter(i => i.accion === 'error').map(i => [i.codigo, i.detalle]),
  [[null, 'Falta el código.'], ['999', 'Falta la descripción.']]);

grupo('Se puede vender aunque esté inactivo');
const v = (await vend(`SELECT venta_registrar($1::jsonb) r`, [JSON.stringify({ items: [{ producto_id: cel.id, cantidad: 1, precio_unitario: 250000 }] })]))[0].r;
t('venta ok, sin tocar el stock (sin contar)', [v.ok, (await prod('001')).stock_actual], [true, 17]);

grupo('Reimportar el mismo archivo');
const r2 = await imp(admin, [{ codigo: '001', nombre: 'OTRO NOMBRE', marca: 'OTRA', categoria_id: 1, stock: 50 }]);
t('no duplica: actualiza', [r2.creados, r2.actualizados, (await q(`SELECT count(*)::int n FROM productos WHERE codigo_anterior = '001'`))[0].n], [0, 1, 1]);
const cel2 = await prod('001');
t('no pisa nombre, marca, categoría ni el stock que ya tenía', [cel2.nombre, cel2.marca, cel2.categoria_id, cel2.stock_actual], ['CELULAR REDMI A5 64GB 3RAM', 'XIAOMI', 2, 17]);

grupo('Lista de precios (después)');
const r3 = await imp(admin, [{ codigo: '001', precio: '249.999,50' }, { codigo: '4909', precio: 38000 }, { codigo: '238', precio: 0 }]);
t('actualiza precios por código', [r3.actualizados, (await prod('001')).precio, (await prod('4909')).precio], [3, 249999.5, 38000]);
t('precio 0 no borra nada', (await prod('238')).precio, null);
t('números como en una planilla argentina', (await q(`SELECT fn_importar_num('249.999,50') a, fn_importar_num('1.200') b, fn_importar_num('$ 15.000') c, fn_importar_num('12.5') d, fn_importar_num('abc') e`))[0],
  { a: '249999.50', b: '1200', c: '15000', d: '12.5', e: null });
t('sigue inactivo (se publica a mano, con foto)', (await prod('4909')).estado, 'inactivo');

grupo('Vincular a un producto que ya estaba en la web');
// La freidora (id 1) ya existía, contada, activa
await db.exec(`SELECT set_config('request.jwt.claim.sub', '${ADMIN}', false)`);
await q(`SELECT fn_stock_contar(1, 4)`);
await db.exec(`SELECT set_config('request.jwt.claim.sub', '', false)`);
const r4 = await imp(admin, [{ codigo: '8612', nombre: 'FREIDORA 3LTS', marca: 'ULTRACOMB', stock: 2, vincular_producto_id: 1 }]);
const fr = await prod('8612');
t('vinculado: no crea otro', [r4.vinculados, r4.creados, fr.id], [1, 0, 1]);
t('no le cambia nombre, estado ni el stock contado', [fr.nombre, fr.estado, fr.stock_actual, fr.stock_controlado], ['Freidora de aire 5L', 'activo', 4, true]);
t('completa la marca que no tenía', fr.marca, 'ULTRACOMB');
const r5 = await imp(admin, [{ codigo: '9999', nombre: 'Otra', vincular_producto_id: 1 }]);
t('no se vincula un producto que ya tiene otro código', [r5.errores, r5.items[0].error], [1, 'ya_vinculado']);

grupo('Registro');
t('queda en el historial cada tanda', (await q(`SELECT count(*)::int n FROM historial_actividad WHERE accion = 'importar'`))[0].n, 5);

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
