/**
 * Pruebas de la lógica pura de la Edge Function "usuarios"
 * (supabase/functions/usuarios/logica.ts). Node 23.6+ lee .ts sin compilar.
 *
 *   node scripts/test-usuarios-fn.mjs
 */
import { claveTemporal, validarAlta, esEmailExistente } from '../supabase/functions/usuarios/logica.ts';

let ok = 0, fail = 0;
const t = (nombre, real, esperado) => {
  const a = JSON.stringify(real), b = JSON.stringify(esperado);
  if (a === b) { ok++; console.log('  OK   ' + nombre); }
  else { fail++; console.log(`  FALLA ${nombre}\n        esperado: ${b}\n        obtenido: ${a}`); }
};

console.log('\n— Contraseña temporal —');
const muestras = Array.from({ length: 2000 }, () => claveTemporal());
t('formato xxxx-xxxx-xxxx', muestras.every(c => /^[a-z2-9]{4}-[a-z2-9]{4}-[a-z2-9]{4}$/.test(c)), true);
t('sin caracteres confusos (0 o 1 l i)', muestras.some(c => /[01lio]/.test(c)), false);
t('no se repiten en 2000', new Set(muestras).size, 2000);
const usadas = new Set(muestras.join('').replace(/-/g, ''));
t('usa las 31 letras y números del alfabeto', usadas.size, 31);
// Azar fijo: bytes por encima del tope (248) se descartan, no sesgan.
let llamada = 0;
const azarFijo = n => { llamada++; return new Uint8Array(n).map((_, i) => llamada === 1 ? 250 + (i % 6) : i); };
t('descarta bytes sesgados y pide más azar', [claveTemporal(azarFijo), llamada], ['abcd-efgh-jkmn', 2]);

console.log('\n— Validar alta —');
t('alta válida, limpia espacios y mayúsculas',
  validarAlta({ email: '  Jose@Mail.COM ', nombre: '  José   Piva ', rol: 'vendedor' }),
  { email: 'jose@mail.com', nombre: 'José Piva', rol: 'vendedor' });
t('email inválido', validarAlta({ email: 'jose@', nombre: 'J', rol: 'vendedor' }), { error: 'email_invalido' });
t('email sin dominio', validarAlta({ email: 'jose@mail', nombre: 'J', rol: 'vendedor' }), { error: 'email_invalido' });
t('nombre vacío', validarAlta({ email: 'a@b.com', nombre: '  ', rol: 'vendedor' }), { error: 'nombre_invalido' });
t('nombre de más de 80', validarAlta({ email: 'a@b.com', nombre: 'x'.repeat(81), rol: 'vendedor' }), { error: 'nombre_invalido' });
t('rol inventado', validarAlta({ email: 'a@b.com', nombre: 'A', rol: 'superadmin' }), { error: 'rol_invalido' });
t('los tres roles válidos',
  ['administrador', 'encargado_stock', 'vendedor'].map(rol => validarAlta({ email: 'a@b.com', nombre: 'A', rol }).rol),
  ['administrador', 'encargado_stock', 'vendedor']);
t('sin datos', validarAlta({}), { error: 'email_invalido' });

console.log('\n— Email existente —');
t('código email_exists', esEmailExistente({ code: 'email_exists', status: 422 }), true);
t('mensaje viejo de GoTrue', esEmailExistente({ message: 'A user with this email address has already been registered', status: 422 }), true);
t('otro error 422 no es "existente"', esEmailExistente({ message: 'Password should be at least 6 characters', status: 422 }), false);
t('sin error', esEmailExistente(null), false);

console.log(`\n${ok} pasadas, ${fail} fallidas\n`);
process.exit(fail ? 1 : 0);
