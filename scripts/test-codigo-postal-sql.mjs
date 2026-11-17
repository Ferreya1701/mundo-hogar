/**
 * Pruebas: código postal en los pedidos web (sql/036-codigo-postal.sql)
 * contra un Postgres REAL en memoria (PGlite).
 *
 *   node scripts/test-codigo-postal-sql.mjs
 *
 * crear_solicitud guarda el código postal válido (4 números o CPA), descarta
 * lo inválido sin frenar el pedido, y sigue haciendo todo lo de antes.
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


await db.exec(`
INSERT INTO categorias (nombre, slug) VALUES ('Electrodomésticos','electrodomesticos');
INSERT INTO productos (nombre, slug, categoria_id, precio_minorista, seguimiento_inventario, estado) VALUES
  ('Freidora de aire 5L', 'freidora', 1, 45000, true, 'activo');
SET mh.stock = '1'; UPDATE productos SET stock_actual = 10, stock_controlado = true WHERE id = 1; RESET mh.stock;
`);
async function como(rol, sql, params = []) {
  return db.transaction(async tx => {
    await tx.exec(`SET LOCAL ROLE ${rol}`);
    const r = await tx.query(sql, params);
    return r.rows;
  });
}
const anon = (sql, p) => como('anon', sql, p);
const q = async (sql, p) => (await db.query(sql, p)).rows;
let nTel = 0;
const pedir = async (extra = {}) => {
  nTel++;
  const p = { nombre: 'Laura Web', telefono: '342400000' + nTel, localidad: 'Santa Fe', tipo_entrega: 'envio',
              direccion: 'San Martín 1234', items: [{ id: 1, cantidad: 1 }], ...extra };
  const [r] = await anon(`SELECT crear_solicitud($1::jsonb) r`, [JSON.stringify(p)]);
  return r.r;
};
const cpDe = async codigo => (await q(`SELECT codigo_postal FROM solicitudes WHERE codigo = $1`, [codigo]))[0].codigo_postal;

grupo('Migración');
let err = null;
const SQL = leerSQL('036-codigo-postal.sql');
try { await db.exec(SQL); await db.exec(SQL); } catch (e) { err = e.message; }
t('036 corre limpio, dos veces seguidas', err, null);
if (err) { console.log(`\n${ok} pasadas, ${fail} fallidas\n`); process.exit(1); }

grupo('Código postal');
t('4 números se guardan', await cpDe((await pedir({ codigo_postal: '3000' })).codigo), '3000');
t('el CPA se guarda en mayúsculas y sin espacios', await cpDe((await pedir({ codigo_postal: 's 3000 abc' })).codigo), 'S3000ABC');
t('uno inválido se descarta sin frenar el pedido', await cpDe((await pedir({ codigo_postal: '12' })).codigo), null);
t('texto cualquiera se descarta', await cpDe((await pedir({ codigo_postal: 'DROP TABLE' })).codigo), null);
t('sin código postal queda vacío', await cpDe((await pedir()).codigo), null);

grupo('Lo de antes sigue igual');
const r = await pedir({ codigo_postal: '3000' });
t('devuelve el código del pedido y el total', [/^MH-\d{6}-[0-9A-F]{4}$/.test(r.codigo), r.total], [true, 45000]);
t('guarda la dirección y la entrega', (await q(`SELECT direccion, tipo_entrega FROM solicitudes WHERE codigo = $1`, [r.codigo]))[0], { direccion: 'San Martín 1234', tipo_entrega: 'envio' });
let e1 = null; try { await pedir({ items: [{ id: 1, cantidad: 50 }] }); } catch (e) { e1 = e.message; }
t('sigue frenando si no hay stock', e1, 'sin_stock');
let e2 = null; try { await pedir({ nombre: 'L' }); } catch (e) { e2 = e.message; }
t('sigue validando el nombre', e2, 'nombre_invalido');
t('anónimo puede crear el pedido (permisos de 013 intactos)', (await q(`SELECT has_function_privilege('anon', 'crear_solicitud(jsonb)', 'EXECUTE') x`))[0].x, true);

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
