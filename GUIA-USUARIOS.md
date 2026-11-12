# Accesos al panel (Usuarios)

Desde 2026-11-06 los accesos se crean desde el panel: **Usuarios → + Nuevo acceso**. Ya no hace
falta entrar a Supabase.

## Puesta en marcha (una sola vez, en este orden)
1. **Cerrar el registro público.** Supabase → Authentication → Sign In / Providers → apagar
   **"Allow new users to sign up"** → Save. Las cuentas se crean solo desde el panel.
2. **Base de datos:** pegar `sql/014-accesos.sql` en el SQL Editor y correrlo (idempotente; requiere
   001..013). Al final muestra la lista de accesos: si aparece alguno que no conocés, desactivalo
   desde Usuarios → Editar o borralo en Authentication → Users.
3. **Edge Function** (en una terminal con la CLI logueada):
   `npx supabase functions deploy usuarios --project-ref vduinkzeneokkqzdgxig --no-verify-jwt --use-api`
   No necesita secretos nuevos (usa `SUPABASE_SERVICE_ROLE_KEY`, que pone Supabase sola).
   `--no-verify-jwt` porque la función valida la sesión y el rol adentro, como las otras.
4. **Web:** push a `main` (Cloudflare despliega solo). Página nueva: `/admin/clave`.

Si la web sube antes que la función, el panel avisa "Falta instalar la función usuarios" y no rompe nada.

## Cómo se usa
- **Dar un acceso:** Usuarios → **+ Nuevo acceso** → nombre, email y rol. El panel muestra una
  **contraseña temporal una sola vez** (tipo `k7mq-x4rt-9bne`). Pasarla en persona o por un gestor de
  contraseñas, no por WhatsApp.
- **Primera entrada:** la persona entra en `mundohogarstf.com/admin` con la temporal y el panel la
  manda a **Elegí tu contraseña** antes de dejarla usar nada.
- **Se olvidó la contraseña:** **🔑 Clave nueva** en su fila → otra temporal (la vieja deja de andar).
- **Cambiar la propia:** botón **🔑** arriba a la derecha, al lado de Salir.
- **Ya no trabaja más:** **Editar** → apagar "Cuenta activa". No ve nada más desde ese momento.

## Reglas (las hace cumplir la base, no solo la pantalla)
- Toda cuenta nueva nace **inactiva y vendedor**; la activa con el rol pedido la función `usuarios`
  (solo para administradores activos) o un administrador desde Editar.
- Rol y estado solo los cambia un **administrador**, y nunca los suyos propios (que nadie se deje
  afuera por error: eso se lo pide a otro admin, o se hace desde el SQL Editor).
- Cada uno puede cambiar su nombre y su contraseña. El email no se cambia desde el panel.

## Archivos
- `sql/014-accesos.sql` — perfil inactivo al crear, guardia de roles, `debe_cambiar_clave`.
- `supabase/functions/usuarios/` — `index.ts` (crear / restablecer) y `logica.ts` (contraseña temporal
  y validaciones, probadas con node).
- `admin/usuarios.html`, `admin/clave.html`, `admin/js/auth.js` (redirige a /admin/clave si la
  contraseña es temporal), `admin/js/layout.js` (botón 🔑).
- Pruebas: `node scripts/test-accesos-sql.mjs` (36, Postgres real con PGlite) y
  `node scripts/test-usuarios-fn.mjs` (17).

## Qué ve cada rol (sql/015, 2026-11-06)
| | Administrador | Encargado de stock | Vendedor |
|---|---|---|---|
| Ventas del local | Todas | Todas | **Solo las suyas** |
| Pedidos web, comprobantes | Sí (confirma pagos) | Sí | Sí |
| Clientes (CRM) | Sí | No | Sí |
| Productos y stock | Edita | Edita, cuenta, compras | Ve |
| Costo y proveedor de productos, compras | Sí | Sí | **No** |
| Cuentas bancarias | Completas (CUIT, límites) | Nombre, titular y alias | Nombre, titular y alias |
| Historial de actividad | Sí | No | No |
| Usuarios, configuración, categorías | Sí | No | No |

Una cuenta **desactivada** no lee nada, aunque entre por fuera del panel. Lo hace cumplir la base de
datos (no solo la pantalla). Pruebas: `node scripts/test-permisos-sql.mjs`.

## Permisos tildables por rol (sql/016, 2026-11-11)
Desde el 016, lo que puede hacer el **vendedor** y el **encargado de stock** se elige en
**Admin → Permisos**: una tabla con un tilde por permiso y por rol. El **administrador siempre puede
todo** (su columna no se edita). Los cambios valen para todas las personas de ese rol desde la
próxima página que abran.

| Permiso | Vendedor | Encargado | Qué controla |
|---|---|---|---|
| Crear ventas en el local | ✔ | ✔ | Crear venta / cobrar en el mostrador |
| Ver las ventas de todos | | ✔ | Sin él, cada uno ve solo sus ventas |
| Anular sus propias ventas (24 h) | ✔ | ✔ | |
| Anular cualquier venta | | | De otros o de más de 24 h |
| Gestionar pedidos web | ✔ | | Cambiar estado de pedidos de la tienda |
| Cobrar pedidos web | ✔ | | Habilitar pago, confirmar/rechazar comprobantes |
| Anular un pago confirmado | | | |
| Ver y gestionar clientes | ✔ | | Clientes (CRM) |
| Crear y editar productos | | ✔ | Borrar productos sigue siendo solo del admin |
| Crear y editar categorías | | | |
| Contar stock | | ✔ | |
| Ajuste manual de stock | | ✔ | |
| Compras, proveedores y costos | | ✔ | |

Los tildes de arriba son los **valores iniciales** = exactamente lo que cada rol podía antes del 016.
Volver a correr el 016 **no** pisa lo que el administrador cambió.

**Siempre solo del administrador:** usuarios, permisos, configuración, cuentas bancarias,
liquidaciones, historial de actividad y borrar productos.

Cómo funciona por dentro:
- Tablas `permisos` (catálogo) y `rol_permisos` (lo tildado). Se cambian solo con la función
  `permisos_rol_guardar(rol, permisos[])`, que exige administrador y deja registro en el historial.
- La base consulta `fn_tiene_permiso('clave')` en las funciones y en las políticas. El 016 cambió en
  cada función existente **solo la línea** que miraba el rol; si alguien modificó una a mano y no
  encuentra esa línea, el script se detiene sin cambiar nada.
- El panel pide `fn_mis_permisos()` al entrar y oculta menús y botones (`Auth.puede('clave')`). Si el
  016 todavía no se corrió, usa los permisos de siempre.
- Contar stock y recibir compras generan movimientos de stock por la vía interna: no hace falta
  tener "Ajuste manual" para contar o recibir.
- La Edge Function `leer-lista-compra` pide el permiso "Compras, proveedores y costos" (hay que
  volver a desplegarla después de correr el 016).
- Pruebas: `node scripts/test-permisos-tildables-sql.mjs` (66).

## Rol Cajero (sql/029, 2026-11-12)

Para separar quién vende de quién cobra. El **cajero** arranca con: ver la caja, abrirla y cerrarla,
cobrar ventas (con pago mixto), cargar ingresos y egresos, ver cuentas corrientes y registrar pagos de
clientes, cobrar pedidos web, y ver y entregar retiros y envíos. **No crea ventas.** Al entrar al panel
va directo a la Caja. Todo se cambia en Administración → Permisos (columna "Cajero").

Al vendedor no se le sacó nada al crear el rol. Cuando haya un cajero cargado, si quieren que cobre solo
él: Permisos → destildar "Cobrar ventas en la caja" (y "Abrir y cerrar la caja") en la columna Vendedor.

Para dar de alta un cajero desde Usuarios hace falta redesplegar la función `usuarios` (ver arriba):
mientras tanto se crea como vendedor y se le cambia el rol a Cajero editándolo.
Pruebas: `node scripts/test-rol-cajero-sql.mjs` (18).
