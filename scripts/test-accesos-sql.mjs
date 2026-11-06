/**
 * Pruebas de los accesos al panel (sql/014-accesos.sql) contra un Postgres
 * REAL en memoria (PGlite), sin tocar Supabase.
 *
 *   npm i --no-save --prefix scripts @electric-sql/pglite   (una sola vez)
 *   node scripts/test-accesos-sql.mjs
 *
 * Qué prueba:
 *   1. El 014 corre limpio dos veces (idempotente) sobre 001/002.
 *   2. Antes del 014 el agujero existe (registro con rol administrador,
 *      vendedor que se asciende solo); después, no.
 *   3. Cuenta nueva: nace inactiva y vendedor, sin acceso a nada.
 *   4. Qué columnas puede tocar cada uno y qué hace el servidor.
 */
import fs from 'fs';
import path from 'path';
import { fileURLToPath, pathToFileURL } from 'url';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const leerSQL = f => fs.readFileSync(path.join(RAIZ, 'sql', f), 'utf8');

async function cargarPGlite() {
  try { return (await import('@electric-sql/pglite')).PGlite; } catch (_) { /* sigue */ }
  if (process.env.PGLITE_DIR) {
    const p = path.join(process.env.PGLITE_DIR, 'node_modules', '@electric-sql', 'pglite', 'dist', 'index.js');
    return (await import(pathToFileURL(p).href)).PGlite;
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

const PGlite = await cargarPGlite();
const db = new PGlite();

await db.exec(`
CREATE SCHEMA auth;
CREATE TABLE auth.users (id UUID PRIMARY KEY, email TEXT, raw_user_meta_data JSONB DEFAULT '{}'::jsonb);
CREATE FUNCTION auth.uid() RETURNS UUID LANGUAGE sql STABLE AS
  $f$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $f$;
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
GRANT USAGE ON SCHEMA public, auth TO anon, authenticated;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated;
`);
await db.exec(leerSQL('001-schema.sql').replace(/CREATE EXTENSION[^;]*;/i, ''));
await db.exec(leerSQL('002-rls-policies.sql'));

const ADMIN  = '00000000-0000-0000-0000-00000000000a';
const ADMIN2 = '00000000-0000-0000-0000-00000000000d';
const VEND   = '00000000-0000-0000-0000-00000000000b';
const STOCK  = '00000000-0000-0000-0000-00000000000c';
const INTRUSO_VIEJO = '00000000-0000-0000-0000-0000000000e1';
const INTRUSO       = '00000000-0000-0000-0000-0000000000e2';
const NUEVO         = '00000000-0000-0000-0000-0000000000f1';

async function como(rol, uid, sql, params = []) {
  return db.transaction(async tx => {
    await tx.exec(`SET LOCAL ROLE ${rol}`);
    await tx.query(`SELECT set_config('request.jwt.claim.sub', $1, true)`, [uid ?? '']);
    const r = await tx.query(sql, params);
    return Object.assign(r.rows, { afectadas: r.affectedRows });
  });
}
const usuario = uid => (sql, p) => como('authenticated', uid, sql, p);
const admin = usuario(ADMIN), vend = usuario(VEND), stock = usuario(STOCK);
const q = async (sql, p) => (await db.query(sql, p)).rows;   // servidor (SQL Editor / clave de servicio)
const perfil = async id => (await q(`SELECT nombre, rol, activo, debe_cambiar_clave FROM profiles WHERE id = $1`, [id]))[0];
const rolDe = async uid => (await usuario(uid)(`SELECT fn_get_user_role() AS r`))[0].r;

async function falla(nombre, fn, patron) {
  try { await fn(); t(nombre, 'no falló', 'falla con ' + patron); }
  catch (e) { t(nombre, patron.test(e.message) ? 'falló bien' : e.message, 'falló bien'); }
}

// ── Cómo estaba antes del 014 ─────────────────────────────────────
grupo('Antes del 014 (el agujero)');
await q(`INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ($1, 'ana@mh.test',    '{"nombre":"Ana Admin","rol":"administrador"}'),
  ($2, 'vero@mh.test',   '{"nombre":"Vero Ventas"}'),
  ($3, 'sergio@mh.test', '{"nombre":"Sergio Stock","rol":"encargado_stock"}'),
  ($4, 'beto@mh.test',   '{"nombre":"Beto Admin","rol":"administrador"}')`, [ADMIN, VEND, STOCK, ADMIN2]);
await q(`INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ($1, 'intruso@mal.test', '{"nombre":"Intruso","rol":"administrador"}')`, [INTRUSO_VIEJO]);
t('antes: un registro con rol administrador quedaba administrador', await rolDe(INTRUSO_VIEJO), 'administrador');
await vend(`UPDATE profiles SET rol = 'administrador' WHERE id = $1`, [VEND]);
t('antes: un vendedor podía ascenderse solo',
  (await q(`SELECT rol FROM profiles WHERE id = $1`, [VEND]))[0].rol, 'administrador');
await q(`UPDATE profiles SET rol = 'vendedor' WHERE id = $1`, [VEND]);   // lo dejamos como estaba

// ── Migración ─────────────────────────────────────────────────────
grupo('Migración');
let errorMigracion = null;
const SQL014 = leerSQL('014-accesos.sql');
try { await db.exec(SQL014); await db.exec(SQL014); } catch (e) { errorMigracion = e.message; }
t('014 corre limpio, dos veces seguidas', errorMigracion, null);
if (errorMigracion) { console.log(`\n${ok} pasadas, ${fail} fallidas\n`); process.exit(1); }
t('los perfiles existentes no cambian', [await perfil(ADMIN), await perfil(VEND)], [
  { nombre: 'Ana Admin', rol: 'administrador', activo: true, debe_cambiar_clave: false },
  { nombre: 'Vero Ventas', rol: 'vendedor', activo: true, debe_cambiar_clave: false }]);
t('el listado final del 014 trae todos los accesos',
  (await db.exec(SQL014)).at(-1).rows.map(r => r.email).sort(),   // mismo created_at: el orden entre ellos no importa
  ['ana@mh.test', 'beto@mh.test', 'intruso@mal.test', 'sergio@mh.test', 'vero@mh.test']);

// ── Cuentas nuevas ────────────────────────────────────────────────
grupo('Cuenta nueva');
await q(`INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ($1, 'otro@mal.test', '{"nombre":"Otro intruso","rol":"administrador"}')`, [INTRUSO]);
t('un registro que pide administrador nace vendedor e INACTIVO', await perfil(INTRUSO),
  { nombre: 'Otro intruso', rol: 'vendedor', activo: false, debe_cambiar_clave: false });
t('y no tiene rol para nada (fn_get_user_role = null)', await rolDe(INTRUSO), null);
t('no ve productos de stock interno ni perfiles ajenos',
  (await usuario(INTRUSO)(`SELECT count(*)::int AS n FROM profiles`))[0].n, 1);
await falla('no puede activarse solo', () =>
  usuario(INTRUSO)(`UPDATE profiles SET activo = true WHERE id = $1`, [INTRUSO]), /solo_admin_cambia_roles/);
await falla('ni darse rol', () =>
  usuario(INTRUSO)(`UPDATE profiles SET rol = 'administrador' WHERE id = $1`, [INTRUSO]), /solo_admin_cambia_roles/);
t('sigue inactivo', (await perfil(INTRUSO)).activo, false);

await q(`INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES ($1, 'jose@mh.test', '{}')`, [NUEVO]);
t('sin nombre: usa el principio del email', (await perfil(NUEVO)).nombre, 'jose');
await q(`INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('00000000-0000-0000-0000-0000000000f2', 'largo@mh.test', $1)`, [JSON.stringify({ nombre: 'x'.repeat(200) })]);
t('nombre larguísimo: se corta a 80', (await perfil('00000000-0000-0000-0000-0000000000f2')).nombre.length, 80);

// Lo que hace la Edge Function "usuarios" con la clave de servicio
await q(`UPDATE profiles SET nombre = 'José', rol = 'vendedor', activo = true, debe_cambiar_clave = true WHERE id = $1`, [NUEVO]);
t('el servidor lo activa con rol y clave temporal', await perfil(NUEVO),
  { nombre: 'José', rol: 'vendedor', activo: true, debe_cambiar_clave: true });
t('ya tiene acceso como vendedor', await rolDe(NUEVO), 'vendedor');

// ── Qué puede tocar cada uno ──────────────────────────────────────
grupo('Cambios sobre el propio perfil');
await falla('un vendedor no puede ascenderse', () =>
  vend(`UPDATE profiles SET rol = 'administrador' WHERE id = $1`, [VEND]), /solo_admin_cambia_roles/);
await falla('un encargado tampoco', () =>
  stock(`UPDATE profiles SET rol = 'administrador' WHERE id = $1`, [STOCK]), /solo_admin_cambia_roles/);
await falla('nadie cambia su email desde el panel', () =>
  vend(`UPDATE profiles SET email = 'otro@x.test' WHERE id = $1`, [VEND]), /perfil_campo_protegido/);
t('sí puede cambiar su nombre',
  (await vend(`UPDATE profiles SET nombre = 'Verónica' WHERE id = $1`, [VEND])).afectadas, 1);
t('y registrar su último acceso',
  (await vend(`UPDATE profiles SET ultimo_acceso = now() WHERE id = $1`, [VEND])).afectadas, 1);
await usuario(NUEVO)(`UPDATE profiles SET debe_cambiar_clave = false WHERE id = $1`, [NUEVO]);
t('y bajar su marca de clave temporal después de cambiarla', (await perfil(NUEVO)).debe_cambiar_clave, false);
t('un vendedor no edita a otro (0 filas, por RLS)',
  (await vend(`UPDATE profiles SET nombre = 'x' WHERE id = $1`, [STOCK])).afectadas, 0);

grupo('Administrador');
await admin(`UPDATE profiles SET rol = 'encargado_stock' WHERE id = $1`, [VEND]);
t('cambia el rol de otro', (await perfil(VEND)).rol, 'encargado_stock');
await admin(`UPDATE profiles SET activo = false WHERE id = $1`, [VEND]);
t('desactiva a otro', (await perfil(VEND)).activo, false);
t('el desactivado se queda sin acceso', await rolDe(VEND), null);
await admin(`UPDATE profiles SET activo = true, rol = 'vendedor' WHERE id = $1`, [INTRUSO]);
t('activa una cuenta nueva', await rolDe(INTRUSO), 'vendedor');
await falla('no puede cambiar su propio rol', () =>
  admin(`UPDATE profiles SET rol = 'vendedor' WHERE id = $1`, [ADMIN]), /no_podes_cambiar_tu_rol/);
await falla('ni desactivarse', () =>
  admin(`UPDATE profiles SET activo = false WHERE id = $1`, [ADMIN]), /no_podes_cambiar_tu_rol/);
t('sí su nombre', (await admin(`UPDATE profiles SET nombre = 'Ana' WHERE id = $1`, [ADMIN])).afectadas, 1);
await falla('tampoco cambia el email de otro', () =>
  admin(`UPDATE profiles SET email = 'x@x.test' WHERE id = $1`, [VEND]), /perfil_campo_protegido/);
await admin(`UPDATE profiles SET activo = false WHERE id = $1`, [ADMIN2]);
t('otro administrador sí puede desactivar a un admin', (await perfil(ADMIN2)).activo, false);
t('un admin desactivado ya no edita a nadie (0 filas, por RLS)',
  (await usuario(ADMIN2)(`UPDATE profiles SET rol = 'administrador' WHERE id = $1`, [VEND])).afectadas, 0);
await falla('ni se reactiva solo', () =>
  usuario(ADMIN2)(`UPDATE profiles SET activo = true WHERE id = $1`, [ADMIN2]), /solo_admin_cambia_roles/);

grupo('Servidor (SQL Editor / clave de servicio)');
await q(`UPDATE profiles SET rol = 'administrador', activo = true WHERE id = $1`, [ADMIN2]);
t('puede todo, incluso reactivar un admin', await perfil(ADMIN2),
  { nombre: 'Beto Admin', rol: 'administrador', activo: true, debe_cambiar_clave: false });
await q(`UPDATE profiles SET email = 'ana@mundohogar.test' WHERE id = $1`, [ADMIN]);
t('y corregir un email', (await q(`SELECT email FROM profiles WHERE id = $1`, [ADMIN]))[0].email, 'ana@mundohogar.test');

grupo('Permisos de las funciones');
await falla('anon no puede llamar a la guardia', () =>
  como('anon', '', `SELECT fn_profiles_proteger()`), /permission denied|trigger functions can only be called/);

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
