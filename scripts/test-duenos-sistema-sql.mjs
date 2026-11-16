/**
 * Pruebas: dueños del sistema y "Configuración web" (sql/033-duenos-sistema.sql)
 * contra un Postgres REAL en memoria (PGlite).
 *
 *   node scripts/test-duenos-sistema-sql.mjs
 *
 * Solo los dueños ven la comisión y cambian la configuración web de cobros;
 * un administrador que no es dueño, no. La comisión deja de estar a la vista.
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
await db.exec(leerSQL('021-importar-articulos.sql'));
await db.exec(leerSQL('022-reparar-movimientos-stock.sql'));
await db.exec(leerSQL('023-fotos-precios-publicar.sql'));
await db.exec(leerSQL('024-ubicaciones.sql'));
await db.exec(leerSQL('025-caja-cuentas-bancarias.sql'));
await db.exec(leerSQL('026-cobrar-en-caja.sql'));
await db.exec(leerSQL('027-entregas.sql'));
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

for (const f of ['028-pedidos-web-en-circuito.sql', '029-rol-cajero.sql', '030-historial.sql', '031-fotos-sugeridas.sql']) {
  await db.exec(leerSQL(f));
}

await db.exec(leerSQL('032-avisos-banco.sql'));
await q(`UPDATE site_settings SET comision_pct = 5, cobros_activos = true WHERE id = 1`);

grupo('Migración');
let err = null;
const SQL = leerSQL('033-duenos-sistema.sql');
try { await db.exec(SQL); await db.exec(SQL); } catch (e) { err = e.message; }
t('033 corre limpio, dos veces seguidas', err, null);
if (err) { console.log(`\n${ok} pasadas, ${fail} fallidas\n`); process.exit(1); }
t('la comisión pasó a la tabla privada', (await q(`SELECT comision_pct::float c FROM config_duenos`))[0].c, 5);
t('y en site_settings (pública) quedó en 0', (await q(`SELECT comision_pct::float c FROM site_settings`))[0].c, 0);

await q(`INSERT INTO duenos_sistema (user_id) VALUES ($1)`, [ADMIN]);
const ADMIN2 = VEND2;   // un segundo administrador que no es dueño
await q(`UPDATE profiles SET rol = 'administrador' WHERE id = $1`, [ADMIN2]);
const admin2 = usuario(ADMIN2);

grupo('Quién es dueño');
t('el dueño lo sabe', (await admin(`SELECT fn_es_dueno_sistema() x`))[0].x, true);
t('otro administrador no es dueño', (await admin2(`SELECT fn_es_dueno_sistema() x`))[0].x, false);
t('el vendedor tampoco', (await vend(`SELECT fn_es_dueno_sistema() x`))[0].x, false);
await q(`UPDATE profiles SET activo = false WHERE id = $1`, [ADMIN]);
t('un dueño desactivado deja de serlo', (await admin(`SELECT fn_es_dueno_sistema() x`))[0].x, false);
await q(`UPDATE profiles SET activo = true WHERE id = $1`, [ADMIN]);

grupo('La comisión');
t('el dueño la ve', (await admin(`SELECT comision_pct::float c FROM config_duenos`)).map(r => r.c), [5]);
t('el otro administrador no', await cuantos(admin2, 'config_duenos'), 0);
await falla('el público ni la consulta', () => cuantos(anon, 'config_duenos'), /permission denied/);
await admin(`UPDATE config_duenos SET comision_pct = 7 WHERE id = 1`);
t('el dueño la cambia', (await q(`SELECT comision_pct::float c FROM config_duenos`))[0].c, 7);
t('el otro administrador no (0 filas)', (await admin2(`UPDATE config_duenos SET comision_pct = 0 WHERE id = 1`)).afectadas, 0);
t('sigue en 7', (await q(`SELECT comision_pct::float c FROM config_duenos`))[0].c, 7);
t('ni quién es dueño ve el otro administrador', await cuantos(admin2, 'duenos_sistema'), 0);

grupo('Configuración web en site_settings');
await falla('el otro administrador no apaga los cobros', () => admin2(`UPDATE site_settings SET cobros_activos = false WHERE id = 1`), /sin_permiso/);
await falla('ni cambia el plazo', () => admin2(`UPDATE site_settings SET cobros_plazo_horas = 1 WHERE id = 1`), /sin_permiso/);
await falla('ni prende confirmar solo con comprobante', () => admin2(`UPDATE site_settings SET cobros_auto_confirmar = true WHERE id = 1`), /sin_permiso/);
await falla('ni escribe una comisión en la columna vieja', () => admin2(`UPDATE site_settings SET comision_pct = 50 WHERE id = 1`), /sin_permiso/);
await pasa('pero sí el resto de la configuración de la tienda', () => admin2(`UPDATE site_settings SET whatsapp = '5493424000000' WHERE id = 1`));
await pasa('y guardar la fila entera sin tocar lo de cobros', () => admin2(`UPDATE site_settings SET whatsapp = whatsapp, cobros_activos = cobros_activos WHERE id = 1`));
await admin(`UPDATE site_settings SET cobros_auto_confirmar = false, cobros_plazo_horas = 48 WHERE id = 1`);
t('el dueño sí cambia la configuración web', (await q(`SELECT cobros_plazo_horas p FROM site_settings`))[0].p, 48);

grupo('Liquidación con la comisión privada');
await q(`INSERT INTO cuentas_cobro (nombre, titular, alias) VALUES ('C1', 'T', 'mh.c1')`);
await q(`INSERT INTO movimientos_cobro (cuenta_cobro_id, tipo, monto, fecha) VALUES (1, 'cobro', 100000, '2026-09-10 12:00-03')`);
const liq = (await admin(`SELECT cerrar_liquidacion('2026-09') r`))[0].r;
t('usa el 7% de config_duenos', [Number(liq.porcentaje), Number(liq.comision)], [7, 7000]);

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
