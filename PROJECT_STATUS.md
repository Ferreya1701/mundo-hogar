# PROJECT_STATUS — Mundo Hogar / TIAF

> Consultar este archivo antes de re-analizar el proyecto. Actualizado: 2026-11-12 (016–021 en producción).

## Hosting (desde 2026-10-16): Cloudflare Workers
- **Producción:** `https://mundohogarstf.com` servido por **Cloudflare Workers** (solo archivos
  estáticos, sin código de servidor), cuenta Cloudflare de TIAF, proyecto `mundo-hogar`. Cada push a
  `main` se despliega solo. Motivo: el plan Hobby de Vercel no permite uso comercial; Cloudflare es
  gratis, comercial y sin tope de ancho de banda. Consumo real en Vercel antes de mudar: 4,53 GB/30 días.
- **Config versionada:** `wrangler.jsonc` (assets, 404 propia, barra final automática),
  `_redirects` (rutas), `_headers` (seguridad + caché 1 año en imágenes), `.assetsignore` (no se
  publican `sql/`, `scripts/`, `supabase/`, `*.md` ni configs).
- **DNS en Cloudflare** (nameservers `patryk`/`sreeni.ns.cloudflare.com`; el dominio se sigue pagando en
  GoDaddy). Correo de GoDaddy intacto: MX, SPF, DMARC y 4 CNAME (`bounces.cloud[2].em`,
  `sable.cloud[2]._domainkey`) copiados a mano — el escaneo automático no los detectó.
- **Configuración de zona:** "Always Use HTTPS" activo. Regla de redirección 301 `www` → dominio
  principal ("www a dominio principal (301)", conserva parámetros): canonical, OG y sitemap usan el
  dominio sin `www`. Pendiente subir la versión mínima de TLS a 1.2 (SSL/TLS → Edge Certificates).
- **Vercel** queda solo como espejo en `mundo-hogar-tan.vercel.app` (sin dominio propio). `vercel.json`
  replica las reglas para ese espejo.
- **Imágenes:** cada `.jpg` de `public/images/productos` tiene su `.webp` (máx. 1200 px). El sitio pide
  la `.webp` y cae al `.jpg` si falta (`MH.webpUrl` / `MH.setImg`). Al sumar fotos nuevas, generar ambas.
- Cloudflare redirige `x.html` → `x` y `/productos` → `/productos/` (conserva los parámetros).

## Importar artículos del sistema anterior (2026-11-11) — EJECUTADO EN PRODUCCIÓN 2026-11-12
- `sql/021-importar-articulos.sql`: `productos.codigo_anterior` (único) y `productos_importar()` en
  tandas: crea inactivos con stock de referencia sin contar, vincula a productos existentes, no duplica
  al reimportar, actualiza precios por código. Pantalla `admin/importar.html` (lee el CSV en el
  navegador: el repo es público y los datos no se versionan). Guía: `GUIA-IMPORTAR-ARTICULOS.md`.
- Catálogo recibido 11/11/2026 (PDF "Stock de Artículos"): 972 artículos, 28 rubros (ACCESORIOS 793),
  sin precios; "marca" mezcla marcas y orígenes. ~80 se parecen a productos de la web (revisar a mano).
- Pruebas: `node scripts/test-importar-sql.mjs` (23).

## Quitar productos de una venta (2026-11-11) — EJECUTADO EN PRODUCCIÓN 2026-11-12
- `sql/020-editar-venta.sql`: `venta_quitar_items` devuelve stock, recalcula el total y los
  disparadores de caja (018) y cuenta corriente (019) devuelven la diferencia. Registro en
  `venta_ediciones`; la venta queda "Modificada". `venta_anular` ya no repone renglones en 0.
  Permisos `ventas.editar_propias` (24 h) y `ventas.editar_todas`.
- Pantalla: Ventas → Ver → "Quitar productos"; ticket corregido. Guía: `GUIA-STOCK-Y-VENTAS.md` §12.
- Pruebas: `node scripts/test-editar-venta-sql.mjs` (33).

## Fotos para revisar: placas del Drive (2026-11-12) — EN EL REPO; FALTA CORRER sql/031 Y CARGAR LAS FOTOS
- Drive "Catálogo Revendedor" (279 placas de Canva). Herramientas en `scripts/placas/` (LEEME.md): OCR del
  título/ficha, recorte de la foto sola (borra texto y plantilla) y cruce con el catálogo. 267 recortes;
  sugerencias: 90 casi seguras, 20 probables, 108 dudosas, 49 sin sugerencia. Muestra de 25 "seguras": 22 bien.
- `sql/031-fotos-sugeridas.sql`: tabla `fotos_sugeridas` + `foto_sugerida_asignar/descartar/deshacer`
  (usa `producto_fotos_guardar` del 023). Nada se publica sin que alguien confirme. Pruebas:
  `scripts/test-fotos-sugeridas-sql.mjs` (23).
- Pantalla `/admin/fotos-revisar` (Catálogo, permiso `productos.editar`): foto, lo que dice la placa, 3
  sugerencias (teclas 1-3), buscar otro producto, descartar (D), deshacer.
- Carga: `SUPABASE_SERVICE_ROLE_KEY=... node scripts/cargar-fotos-placas.mjs <paquete>` (paquete armado en la
  sesión del 2026-11-12, en el scratchpad local; se puede rearmar con scripts/placas).

## Historial de cambios / auditoría (2026-11-12) — EN EL REPO; FALTA CORRER sql/030
- `sql/030-historial.sql`: tabla `auditoria` llenada por triggers (no por el navegador) en 18 tablas
  (productos, ventas, caja, stock a mano, cuenta corriente, cobros, usuarios, permisos, cuentas bancarias,
  configuración, pedidos, compras…). Guarda solo lo que cambió (antes → después) y marca lo delicado
  (precios, anulaciones, quitar productos, deshacer entregas, egresos y anulaciones de caja, diferencias de
  cierre, ajustes de stock, permisos, roles, cuentas bancarias). Nadie la edita ni la borra (ni con acceso
  total: trigger). La ve el permiso `auditoria.ver` (solo admin de entrada). Lo automático (stock de cada
  venta, cobros asentados) no se registra; el alta de una fila se registra al confirmar la operación, ya
  completa (trigger diferido), sin los retoques intermedios. Pruebas: `scripts/test-historial-sql.mjs` (20).
- Pantalla `admin/historial.html` (Administración → Historial): por día, frases legibles, filtros por
  período, persona, tipo, búsqueda y "solo lo delicado"; detalle antes → después.

## Panel como UNA SOLA APLICACIÓN (2026-11-12) — etapa 1 hecha
- `admin/app.html` + `admin/js/app.js`: armazón con menú y barra fijos; cada módulo se abre en su propio
  iframe y QUEDA ABIERTO (hasta 8; el más viejo se cierra). Volver a un módulo: ~12 ms, conserva lo que
  había (ticket a medio armar, filtros). Un módulo oculto más de 10 min se recarga al volver; algunos
  refrescan sus datos al volver (`window.MHAlMostrar`).
- Dirección: `/admin/app#/caja?ver=12`. Las direcciones viejas (`/admin/caja`) redirigen solas al armazón
  (auth.js, `MH_AL_ARMAZON`); `?solo=1` abre un módulo suelto (para revisar algo sin armazón).
- Dentro del armazón (`MH_EMBEBIDO`): el módulo esconde su menú, pasa los enlaces al armazón, usa el
  perfil del armazón (sin consultas), los contadores y el asistente son del armazón.
- Por qué iframes y no reemplazar el HTML: aislamiento (el código de un módulo no puede escribir en la
  pantalla de otro ni dejar temporizadores andando) y módulos que siguen vivos.
- Etapa 2 (pendiente): catálogo compartido entre módulos (bajarlo una vez en el armazón), y de a poco
  reescribir módulos como componentes del armazón.

## Circuito de venta estilo PromRepuestos (2026-11-12) — plan acordado con el dueño
- **Etapa A — cobrar en caja con pago mixto: sql/026 EJECUTADO EN PRODUCCIÓN 2026-11-12.** Decisiones del dueño:
  SIEMPRE por caja (nadie cobra directo) y pago mixto desde el inicio. Cuenta corriente no pasa por caja.
  `sql/026-cobrar-en-caja.sql`: estado `pendiente_cobro`, `venta_pagos`, `venta_cobrar`, `venta_devolver`,
  `venta_reenviar_a_caja`, permiso `caja.cobrar`; caja y cuentas bancarias se asientan por medio/cuenta
  desde `fn_venta_pagado`. Parchea venta_registrar / venta_anular / venta_quitar_items / caja_cuenta_pedir.
  Pantallas: Crear venta ("Enviar a caja", espera con aviso automático, "mis ventas en la caja"),
  Caja ("Para cobrar", cobro mixto, devolver, cancelar), Ventas (estado, quién cobró, cómo pagó),
  orden para la caja y ticket con desglose. Guía: `GUIA-STOCK-Y-VENTAS.md` §13. Pruebas (41).
  OJO al correr el 026: desde ese momento NINGUNA venta queda cobrada sin pasar por Caja → avisar al
  personal y tener la caja abierta. Las pantallas viejas en caché (5 min) mostrarían "cobrada" de más.
- **Etapa B — retiros y envíos (módulo Entregas): sql/027 EJECUTADO EN PRODUCCIÓN 2026-11-12.** Venta elige se lo lleva / retira después / envío por transporte; Entregas con Para retirar, Envíos por transporte (despacho múltiple con guía), Entregadas; comprobante de retiro con ubicaciones, etiqueta por bulto, hoja de despacho. Lo sin pagar no sale (salvo cuenta corriente). Guía §14 de GUIA-STOCK-Y-VENTAS.md.
- **Etapa C — pedidos web en el circuito: sql/028 EJECUTADO EN PRODUCCIÓN 2026-11-12.** "Pasar al mostrador" en Pedidos convierte el pedido en venta: pagado online → venta pagada (medio `web`, no toca caja); sin pagar → Caja "pagan al retirar". Pedido y venta se sincronizan (pago online, entrega, anulación). Guía §15.
- **Etapa E — menú reordenado con contadores: HECHO (solo panel, sin SQL).** Mostrador / Entregas / Pedidos web / Clientes / Catálogo / Stock / Administración; contadores de caja, entregas y pedidos (head counts en paralelo, cache 60 s en sessionStorage). Guía §16.
- **Limpieza de pruebas en producción (2026-11-12, pedido del dueño):** borradas las ventas, la caja, los pedidos web (con comprobantes y eventos) y el historial de actividad de prueba. Se conservaron las 492 cargas iniciales de stock del catálogo y los 6 contactos del CRM. Respaldo: `~/mundo-hogar-respaldos/datos-antes-limpieza-20261112-1424.sql`.
- **Etapa D — comprobantes y avisos por paso: HECHO (solo panel).** Retiro con ubicaciones y pedido web, etiqueta por bulto, hoja de despacho, avisos de WhatsApp (pedido tomado / listo para retirar / despachado con guía). Guía §17.
- **Circuito A–E completo.** Fuera de alcance por ahora: presupuestos, proveedores, estadísticas, facturación.
- **Rol cajero: sql/029 EJECUTADO y función `usuarios` desplegada (2026-11-12).** Cobra, abre/cierra caja, cuenta corriente (ver y cobrar), cobrar pedidos web, entregas; no vende; entra directo a Caja. Al vendedor no se le sacó nada. GUIA-USUARIOS.md.
- Por qué tardaba al cambiar de módulo: (1) cada módulo es una página aparte que vuelve a pedir todo;
  (2) cada consulta a Supabase en Virginia tarda 0,2–0,45 s y las páginas hacían 6–7 EN FILA
  (perfil → permisos → categorías → productos tanda 1 → tanda 2 → ubicaciones → ubicación de cada
  producto); (3) el catálogo pasó de 142 a 1.060 productos.
- Hecho: perfil + permisos recordados 5 min entre páginas (`Auth.PERFIL_TTL`; un cambio de rol o
  permisos se ve a los 5 min como mucho — la base lo aplica al instante igual); `Utils.traerTodo` pide
  de a dos tandas en paralelo; la ubicación viene en la misma consulta de productos; categorías,
  productos y ubicaciones a la vez; la ficha pide producto + costos + fotos a la vez; conexión
  anticipada a Supabase (`<link rel="preconnect">`, cambiar la URL al mudar a São Paulo).
  Medido con la clave pública: 6 consultas en fila ≈ 1,4 s → 4 en paralelo ≈ 0,35–0,6 s.
- Lo que queda: la mudanza a São Paulo (cada consulta ~4 veces más rápida) y, si hiciera falta más,
  guardar el catálogo en el navegador entre páginas (no hecho: riesgo de precios/stock viejos en caja).

## Cuentas bancarias en la caja, igual que la web (2026-11-12) — sql/025 EJECUTADO EN PRODUCCIÓN 2026-11-12
- Antes la cuenta en Crear venta era una etiqueta elegida a mano (sin límites ni cupo). Ahora la asigna
  el sistema con `fn_cobros_elegir_cuenta` (el mismo de la web), con reserva de 15 min (`cobro_reservas`,
  `caja_cuenta_pedir`), y la venta se asienta en `movimientos_cobro` (venta_id) por disparador
  (`tr_ventas_cobros`): cuenta para límites, resumen y liquidación; anular / quitar productos devuelve
  el cupo. `venta_registrar` se parchea en 3 puntos (resuelve la cuenta al fijar el total).
- Nunca frena la venta: si se pasa del límite, registra y avisa. Sin cuentas activas, como antes.
- Crear venta: bloque "El cliente transfiere $X a ALIAS", "Otra cuenta", N° de operación; ticket con la
  cuenta. Caja: transferencias del día por cuenta (`caja_por_cuenta`). Guía: `GUIA-COBROS.md` §7.
- OJO producción: hoy hay UNA sola cuenta y está inactiva ("CUENTA DE PRUEBA (borrar)"): hasta cargar
  las reales, la caja sigue sin cuenta. Pruebas: `node scripts/test-caja-cuentas-sql.mjs` (34).

## Ubicación del stock (2026-11-12) — sql/024 EJECUTADO EN PRODUCCIÓN 2026-11-12
- Una ubicación por producto (lugar + sector opcional), de una lista propia (`ubicaciones`,
  `productos.ubicacion_id`, `productos_ubicar()`). NO divide stock por lugar (decisión del dueño: varios
  locales/depósitos, pero solo "dónde está guardado").
- Contar stock: filtro por ubicación y "Estoy contando en…" (lo contado queda ubicado). Productos y
  Completar: acción en masa. Ficha: selector. Crear venta: muestra 📍. `admin/js/ubicaciones.js`.
- Sin el 024 no aparece nada de esto (las pantallas siguen igual). Guía: `GUIA-PRODUCTOS.md`.

## Productos simples para los empleados (2026-11-12) — sql/023 EJECUTADO EN PRODUCCIÓN 2026-11-12
- **Tope de 1000 filas de Supabase:** con ~1060 productos, Productos / Contar stock / Inicio / Crear
  venta / Compras / Ajuste manual perdían ~60 sin avisar. Ahora todo pide de a tandas
  (`Utils.traerTodo`); la tienda pública también (`assets/catalogo.js`).
- `admin/completar.html` (Catálogo → Completar productos): foto + precio + categoría + publicar por fila,
  guardado automático, Enter pasa al siguiente, acciones en masa, barra de avance.
- `admin/js/fotos.js`: compresión en el navegador (1600 px, WebP), varias fotos, principal, orden,
  arrastrar / pegar / cámara. La ficha (`producto-form.html`) se reordenó: lo esencial y fotos arriba,
  avanzado plegado, checklist "qué falta", margen y oferta validados, slug estable, SKU automático.
- Productos: 50 por página, búsqueda sin acentos (nombre, SKU, barras, código viejo, marca), stock
  "~N · sin contar" distinto del contado, publicar en masa solo los completos. Ajuste manual ve inactivos.
- `sql/023-fotos-precios-publicar.sql`: `producto_fotos_guardar`, `productos_precio_masivo`,
  `productos_publicar`, fotos con el permiso "productos.editar". Sin el 023: las fotos igual suben (solo
  la principal) y publicar/precios en masa avisan que falta.
- Guía para empleados: `GUIA-PRODUCTOS.md`. Pruebas: `node scripts/test-fotos-precios-sql.mjs` (21).

## Producción al 2026-11-12 (Virginia, antes de la mudanza)
- 016 → 021 EJECUTADOS el 2026-11-12 con `npx supabase db query --remote=<ref> --yes -f` (cada uno dentro
  de BEGIN/COMMIT). Respaldo previo (estructura + datos, incluidos usuarios) en `~/mundo-hogar-respaldos/`
  de la máquina del dueño (no está en el repo).
- `leer-lista-compra` redesplegada (pide el permiso "compras.gestionar").
- **El 011 (charla en PanelBot) NUNCA se corrió en producción.** El 016 saltea `crm_base_conversacion`
  si no existe; si algún día se corre el 011, volver a correr el 016 después.
- La mudanza a São Paulo se lleva todo esto en la copia de la base (no hay que volver a correr nada).
- **022 EJECUTADO 2026-11-12**: en producción `fn_registrar_movimiento` había quedado en la versión del 007
  (sin el `mh.stock` del 008) con el guard del 008 activo → TODO movimiento de stock fallaba
  (`stock_solo_por_movimiento`). Se detectó al importar; comparando las 99 funciones de producción con
  las del repo era la única distinta. `sql/022-reparar-movimientos-stock.sql` agrega solo esa línea.
- **Catálogo del sistema viejo IMPORTADO 2026-11-12** (971 artículos; "ENVIO" excluido): 919 productos
  nuevos INACTIVOS (SKU = código viejo) + 52 vinculados a productos de la web (revisados a mano, solo los
  claros). 492 con stock de referencia sin contar (14.198 unidades, movimiento "Stock del sistema
  anterior"). Rubros → categorías y ACCESORIOS (793) clasificado por palabras clave; 26 sin categoría
  (bicicletas, monopatines, triciclos: no hay categoría para eso). "Marca" Buenos Aires/Córdoba/Rosario/
  Litoral → proveedor. Hecho con `productos_importar()` en 5 tandas, a nombre del admin
  joseignaciopivas05. Respaldo previo: `~/mundo-hogar-respaldos/datos-antes-de-importar-20261112-1149.sql`.
- Falta: precios (lista del sistema viejo → Importar artículos con codigo + precio), fotos, y activar en
  Productos lo que se quiera publicar.
- Siguiente: importar el catálogo del sistema viejo (Catálogo → Importar artículos), cargar recargos
  por categoría y saldos iniciales de cuentas corrientes. Falta del sistema viejo la **lista de precios**.
  Pendiente: cotizar envíos fuera de Santa Fe (espera empresa de transporte).

## Cuentas corrientes (2026-11-11) — EJECUTADO EN PRODUCCIÓN 2026-11-12
- `sql/019-cuentas-corrientes.sql`: cuentas sobre clientes del CRM con saldo único, día fijo de pago,
  límite opcional y suspensión; recargo fijo por unidad por categoría (lo suma la base); pagos con
  recibo numerado que entran a la caja; anulación de pagos y ajustes con motivo; vencimientos FIFO.
  Reemplaza `venta_registrar` (agrega cuenta corriente y "retira"). 7 permisos `cc.*`.
- Pantallas: `admin/cuentas-corrientes.html` (nueva), Crear venta (cliente de cuenta, recargo a la
  vista, "Retira"), Ventas (detalle con cuenta y recargo), ticket con saldo y firma.
- También se corrigió el 016: `fn_tiene_permiso` se puede llamar sin sesión (devuelve false), así una
  consulta anónima a ventas da 0 filas en vez de error.
- Pruebas: `node scripts/test-cc-sql.mjs` (64). `MH_HASTA=019 node scripts/test-stock-sql.mjs` corre
  las pruebas de stock con todo instalado (3 fallas esperables: leen el costo de `productos`, que desde
  el 015 vive en `producto_costos`). Guía: `GUIA-CUENTAS-CORRIENTES.md`.

## Caja diaria (2026-11-11) — EJECUTADO EN PRODUCCIÓN 2026-11-12
- `sql/018-caja.sql`: apertura con fondo, ventas que entran solas por disparador (efectivo al cajón,
  otros medios aparte, cuenta corriente no), ingresos/egresos con concepto, anulación con inverso,
  cierre con diferencia obligatoriamente explicada, retiro y fondo. Nunca frena una venta: con la caja
  cerrada el movimiento queda pendiente y se suma al abrir. 6 permisos nuevos `caja.*`.
- Pantalla `admin/caja.html` (menú Ventas → Caja); aviso en Crear venta si está cerrada; cierre
  imprimible (`MHImprimir.cierreCaja`).
- Pruebas: `node scripts/test-caja-sql.mjs` (75), `node scripts/test-ticket.mjs` (54).
  Detalle: `GUIA-STOCK-Y-VENTAS.md` §11.

## Ticket y recibo con datos fiscales (2026-11-11) — EJECUTADO EN PRODUCCIÓN 2026-11-12
- `sql/017-datos-fiscales.sql`: columnas en `site_settings` (cuit validado con dígito verificador,
  domicilio_fiscal, ingresos_brutos, inicio_actividades, condicion_iva, ticket_pie), cargadas con los
  datos del negocio solo si están vacías. Se editan en Configuración → Datos fiscales.
- `admin/js/impresion.js`: ticket nuevo (logo + datos fiscales + fecha con segundos + cliente/retira)
  y `MHImprimir.recibo()` para los pagos de cuenta corriente. Sin el 017 imprime como antes.
- "Retira" se muestra si la venta lo trae; el campo se agrega a la venta en la etapa de cuentas corrientes.
- Pruebas: `node scripts/test-ticket.mjs`. Detalle: `GUIA-STOCK-Y-VENTAS.md` §10.

## Permisos tildables por rol (2026-11-11) — EJECUTADO EN PRODUCCIÓN 2026-11-12
- `sql/016-permisos-tildables.sql`: tablas `permisos` + `rol_permisos`, `fn_tiene_permiso(clave)`,
  `fn_mis_permisos()`, `permisos_rol_guardar(rol, permisos[])` (solo admin, queda en el historial).
  Las funciones y políticas que miraban el rol ahora miran el permiso; valores iniciales = lo de
  antes. `fn_es_staff_ventas()` = "pedidos.cobrar"; `fn_es_staff_stock()` = "compras.gestionar".
- Pantalla nueva **Admin → Permisos** (`admin/permisos.html`). Menú y páginas usan `Auth.puede()`.
- Después de correrlo: volver a desplegar la Edge Function `leer-lista-compra`.
- Detalle y tabla de permisos: `GUIA-USUARIOS.md` → *Permisos tildables por rol*.
- Pruebas: `node scripts/test-permisos-tildables-sql.mjs` (66).
- Plan de las próximas etapas (acordado 2026-11-11): 2) datos fiscales + ticket y recibo,
  3) caja diaria con apertura/cierre, 4) cuentas corrientes (saldo único, día fijo de pago, recargo
  fijo por unidad según categoría), 5) editar venta quitando productos, 6) cotizar envíos (espera
  empresa de transporte). Cada permiso nuevo se suma al catálogo del 016 desde su migración.
- Mudanza de Supabase a São Paulo (cuenta TIAF) en curso por el socio: correr 016 en el proyecto
  nuevo una vez migrado.

## Qué ve cada rol (2026-11-06) — sql/015 EJECUTADO EN PRODUCCIÓN (verificado 2026-11-12)
- Auditoría: varias tablas solo pedían "estar logueado" (`auth.uid() IS NOT NULL`). Además el costo y
  el proveedor de los productos activos eran legibles por cualquiera con la clave pública (estaban
  vacíos: no se filtró nada). `sql/015-permisos-por-rol.sql`:
  - **E** staff = cuenta activa con rol (`fn_get_user_role() IS NOT NULL`): desactivado no lee nada.
  - **A** ventas/venta_items: el vendedor ve solo las suyas; admin y encargado todas.
  - **B** compras*: solo admin + encargado (`fn_es_staff_stock()`). Costo y proveedor viven en
    `producto_costos` (RLS admin + encargado); `productos.precio_costo/proveedor` quedan siempre NULL
    (trigger `tr_productos_mudar_costos` muda lo que se escriba ahí: compras del 013, importación).
  - **C** `cuentas_cobro` completa solo admin; el resto usa la vista `cuentas_cobro_staff`
    (nombre, titular, alias o CBU si no hay alias). Pedidos web y Crear venta leen la vista.
  - **D** historial_actividad: lee solo admin; registra cualquier staff activo.
- Pantallas: producto-form lee/escribe costos en `producto_costos` (si no existe la tabla, usa las
  columnas viejas); Ventas/Inicio/Crear venta dicen "Mis ventas" al vendedor.
- Pruebas: `node scripts/test-permisos-sql.mjs` (57). `test-cobros-sql.mjs` tiene 2 fallas previas
  que no son de esto: un comprobante de prueba con fecha fija 23/10/2026 hoy queda "anterior al pedido".

## Accesos al panel desde Usuarios (2026-11-06) — EN PRODUCCIÓN
- **Agujero cerrado:** el registro público de Supabase estaba abierto (`disable_signup: false`) y el
  trigger del 001 tomaba el rol de los datos de quien se registra → cualquiera podía crearse
  administrador. Además `profiles_update_own` dejaba que un vendedor se pusiera rol admin.
  `sql/014-accesos.sql`: cuentas nuevas nacen inactivas/vendedor; rol y estado solo los cambia otro
  administrador (guardia `fn_profiles_proteger`). Hay que APAGAR "Allow new users to sign up".
- **Alta desde el panel:** Edge Function `usuarios` (crear / restablecer con contraseña temporal,
  solo admins activos) + `admin/clave.html` (elegir/cambiar contraseña; `debe_cambiar_clave` obliga
  a pasar por ahí) + botón 🔑 al lado de Salir. Nombres escapados en Usuarios (antes, XSS posible).
- **Hecho 2026-11-06:** Edge Function `usuarios` desplegada (ping ok; sin sesión responde 401) y web en `main`.
- **Hecho 2026-11-06 (dueño):** registro público apagado (verificado desde afuera: `/auth/v1/signup`
  responde 422 `signup_disabled`) y `sql/014` corrido (la columna `debe_cambiar_clave` existe).
  Falta solo probarlo de punta a punta: crear un vendedor de prueba, entrar con la temporal, elegir
  contraseña, 🔑 Clave nueva, desactivarlo. Ver `GUIA-USUARIOS.md`.

## Panel: nombres, limpieza, ticket y etiquetas (2026-11-02) — DESPLEGADO

- **Menú renombrado** (`admin/js/layout.js`): Inicio, Caja, Ventas, Pedidos web, Clientes, Cuentas
  bancarias, Productos, Categorías, Contar stock, Compras, Ajuste manual, Movimientos de stock,
  Usuarios, Configuración. Los ids y las URLs no cambian; títulos, asistente y guías actualizados.
- **Alertas de Stock eliminada como página**: Contar stock suma el chip "Sin stock" y acepta
  `?filtro=` (`sin_contar|negativo|cero|bajo|controlado|todos`). `admin/alertas.html` queda como
  redirección a `/admin/carga-stock?filtro=cero`. Inicio y asistente apuntan ahí.
- **Ajuste manual** (`inventario.html`): se quitaron los tipos que duplicaban Caja/Compras/Contar
  (`entrada_compra`, `salida_venta`, `carga_inicial`, `transferencia`, `correccion`). La función
  `fn_registrar_movimiento` los sigue aceptando; solo no se ofrecen en el formulario.
- **Formulario de producto**: sin campo "stock inicial" (un producto nuevo nace con 0 y "sin contar";
  el stock entra por conteo o compra). Se muestra el stock actual en solo lectura.
- **Productos**: sin borrado permanente (queda archivar). Se agregó `codigo_barras` al select.
- **Impresión** (`admin/js/impresion.js`, iframe oculto, sin pestañas): ticket de venta de 80 mm
  (Caja al cobrar y `F8`; Ventas → detalle) con datos de `site_settings`; etiquetas CODE128
  (código de barras o SKU) en rollo 50×30 o A4 3×8, desde Productos (fila o selección) y desde el
  detalle de una compra. JsBarcode desde jsdelivr; si no carga, sale el código en texto.
- **Repo**: scripts de importación de julio borrados; informes de junio/julio movidos a `historico/`.

## Stock real: ventas en el local, compras y conteo (2026-10-29) — DESPLEGADO; SQL EJECUTADO EN PRODUCCIÓN
Guía: `GUIA-STOCK-Y-VENTAS.md`. Objetivo: que el stock sea confiable para vender online.
- **`sql/013-local-compras-stock.sql`** — EJECUTADO EN PRODUCCIÓN el 2026-10-29 (`npx supabase db query
  --linked`), probado antes con `scripts/test-stock-sql.mjs` (109 pruebas en PGlite). Verificado en vivo:
  142 productos, 0 controlados (nada contado todavía), 11 RPC nuevas, `pg_trgm@extensions`; el catálogo
  anónimo ya devuelve `stock_controlado`, `stock_disponible` y `disponibilidad_web` ("consultar" en todos
  hasta que se cuenten); `venta_registrar` anónima → 401 permission denied; `ventas` anónima → vacío.
  Si alguna vez la base se reconstruye sin el 013, el panel avisa "falta ejecutar sql/013" y la tienda
  degrada al comportamiento anterior (pide las columnas nuevas y, si no existen, repite sin ellas).
  Qué agrega: `productos.stock_controlado` (+ `stock_controlado_en`, `ultimo_conteo_en`, `sku_proveedor`);
  conteo absoluto `fn_stock_contar` / `fn_stock_contar_lote` / `fn_stock_quitar_control`; alta rápida
  `producto_crear_rapido` (SKU `MH-00001`, slug único, nace inactivo); `ventas` + `venta_items` con
  `venta_registrar` (descuenta solo controlados, permite negativo con aviso, ítem libre, medio de pago,
  cuenta de cobro opcional) y `venta_anular` (repone); `compras` / `compra_items` / `compra_recepciones`
  con `compra_sugerir` (SKU, barras, código proveedor, nombre parecido con pg_trgm), `compra_crear`
  (vincular/crear/omitir, `recibir_ahora`), `compra_recibir` ("ya había" para no contados; costo en pesos
  por tipo de cambio; marca controlado), `compra_item_vincular`, `compra_cambiar_estado`; columnas
  calculadas PostgREST `stock_comprometido` / `stock_disponible` / `disponibilidad_web` (comprometido =
  pedidos web esperando pago); `crear_solicitud` redefinida: 'sin_stock' si un controlado no alcanza,
  `solicitud_items.stock_a_confirmar` para productos con precio sin controlar (→ `tiene_pendientes`,
  sin pago online); `catalogo_bot` suma `stock_controlado`. Backfill: productos con movimientos previos
  quedan controlados. Extensión `pg_trgm` en esquema `extensions`.
- **Panel:** `admin/vender.html` (caja; lector USB o cámara con `admin/js/scanner.js`, ticket deslizable
  en celular, ticket por WhatsApp), `admin/ventas.html` (listado, KPIs, anular, CSV), `admin/compras.html`
  (asistente: pegar/subir Excel/CSV o leer con IA → coincidencias → crear; recepción parcial/total),
  `admin/carga-stock.html` reescrito como **conteo** absoluto (filtros sin contar / negativo / bajo).
  Dashboard: KPIs ventas hoy y sin contar; Alertas: pestaña "Sin contar"; Pedidos: etiqueta "stock a
  confirmar". Menú en `layout.js`. Asistente MH conoce las secciones nuevas.
- **Tienda:** `MH.availability(p)` → ok / sin_stock / consultar / cotizar (`assets/catalogo.js`); tarjeta
  y ficha muestran "Consultar stock" para productos sin controlar; ficha limita la cantidad al disponible
  y dice "¡Últimas N!"; carrito avisa y, ante 'sin_stock' del servidor, ajusta cantidades y lo explica.
- **Edge Function `supabase/functions/leer-lista-compra/index.ts`** — DESPLEGADA 2026-11-02 (`--no-verify-jwt`, valida sesión y rol sola). Lee foto/PDF/
  texto de la lista del proveedor con Claude (`claude-opus-5`, salida JSON con esquema, fallbacks por
  defecto) y devuelve renglones en español. Requiere el mismo `ANTHROPIC_API_KEY` que falta.
- **Hosting:** `_headers` y `vercel.json` permiten la cámara en `/admin/*` (Permissions-Policy).
- **Decisiones:** la caja nunca frena por stock (la realidad gana; queda negativo para revisar). Productos
  nuevos creados por compras nacen `inactivo` (ocultos) hasta completar foto/precio. Pedidos web que
  solo salen por WhatsApp no reservan stock; los que eligen pagar por transferencia sí (comprometido).
- **Pruebas:** `scripts/test-stock-sql.mjs` (SQL), `scripts/test-compras-parse.mjs` (parseo de listas),
  `scripts/test-admin.mjs` sigue en 129/129.

## Cobros por transferencia (2026-10-23) — DESPLEGADO EN PRODUCCIÓN
Gestor de ventas y cobros (no factura, no se conecta con ARCA). Guía: `GUIA-COBROS.md`.
- **`sql/012-cobros.sql`** — EJECUTADO en producción el 2026-10-23 (vía `npx supabase db query --linked`): `cuentas_cobro`, columnas de pago en
  `solicitudes` (`estado_pago`, cuenta, monto con centavos únicos, vencimiento), `comprobantes`,
  `movimientos_cobro` (libro inmutable), `liquidaciones`, config en `site_settings`
  (`cobros_activos`, `cobros_plazo_horas`, `cobros_auto_confirmar`, `comision_pct`,
  `cobros_instrucciones`), bucket privado `comprobantes`. Redefine `cambiar_estado_solicitud`
  (007) con vía interna. RPC públicas: `pedido_consultar`, `pedido_pagar_transferencia`,
  `pedido_subir_comprobante`. Panel: `habilitar_pago`, `confirmar_pago`, `rechazar_comprobante`,
  `anular_pago`, `cerrar_liquidacion`, `fn_cobros_vencer`. Solo servicio:
  `comprobante_registrar_lectura`. Probado con `scripts/test-cobros-sql.mjs` (68 pruebas, PGlite).
- **Edge Function `leer-comprobante`** — DESPLEGADA (`--no-verify-jwt`, valida sola). **Falta el secreto
  `ANTHROPIC_API_KEY`** (el proyecto no lo tiene; sin él los comprobantes quedan "ilegible" y se revisan a mano): lee imagen/PDF con Claude
  (`claude-haiku-4-5`, ~USD 0,003 por lectura) y registra la lectura; la base decide si coincide.
- **Tienda:** `pedido.html` en `/pedido/<código>` (estado, datos para transferir, subida de
  comprobante); `carrito.html` ofrece "Pagar por transferencia" si hay total y
  `site_settings.cobros_activos`; `assets/catalogo.js` expone `MH.cobrosActivos()`.
- **Panel:** `admin/pedidos.html` reemplaza a Solicitudes (que ahora redirige),
  `admin/cuentas-cobro.html` (admin). Menú actualizado en `layout.js`.
- **Estado en producción:** `cobros_activos = true`, `carrito_activo = false` (la tienda es solo
  catálogo + WhatsApp; el equipo prueba con `?preview=1`). Existe una cuenta
  **"CUENTA DE PRUEBA (borrar)"** (alias `prueba.mundohogar.mp`) y el pedido de prueba
  `MH-261023-FCAA` con un comprobante en revisión: sirven para recorrer el panel. **Borrar o pausar
  la cuenta de prueba y cargar las reales antes de prender `carrito_activo`.**
- Verificado en producción el 2026-10-23: crear pedido → pagar por transferencia (cuenta y
  centavos) → subir al bucket → registrar comprobante → función de lectura → consulta; subida fuera
  de la carpeta y descarga anónima rechazadas.
- Riesgo a conversar con el cliente antes de usar varias cuentas: ver `GUIA-COBROS.md` (cabecera).

## Fase actual
**Núcleo de stock ↔ ventas DESPLEGADO Y VERIFICADO en producción (2026-07-13).** `sql/006` y `sql/007`
ejecutados en Supabase real; fix de `admin/solicitudes.html` y `admin/producto-form.html` commiteados y
pusheados a `main` (commit `3e9c3dd`), desplegados por Vercel. Paquete completo de entregables en
`..\..\08_ENTREGABLES\` y `docs\sistema-operativo-mundo-hogar\` (auditoría, procesos, diseño de stock,
modelo de datos, roadmap, propuesta ejecutiva, demo HTML).

## Hecho en esta sesión (2026-07-13)
- **`sql/007-nucleo-stock.sql` — EJECUTADO EN PRODUCCIÓN**: (1) cierra hallazgo crítico H1 —
  `fn_registrar_movimiento` era ejecutable por anónimos vía REST; verificado en vivo con una llamada
  REST anónima real → **401 `permission denied`** (antes habría funcionado). (2) RPC
  `cambiar_estado_solicitud`: máquina de estados, confirmar descuenta stock (`salida_venta`, referencia =
  código MH), cancelar repone (`devolucion_cliente`), idempotente vía `solicitudes.stock_descontado`.
  (3) Tabla `solicitud_eventos` (bitácora inmutable). (4) Trigger que bloquea UPDATE directo de `estado`
  — funcionando: bloqueó correctamente los primeros intentos hechos con el frontend viejo (ver abajo).
- **`admin/solicitudes.html`**: `cambiarEstado` usa la RPC; degrada al UPDATE directo con aviso si la
  RPC no está desplegada; errores amigables (faltantes por producto, transición inválida, permisos).
  **Desplegado a producción** — antes de este deploy, el trigger de arriba bloqueaba TODO cambio de
  estado en el panel en vivo (correcto: protegía contra el UPDATE directo del código viejo).
- **`admin/producto-form.html`**: fix del bug de stock duplicado al crear producto, desplegado.
- **Corrección de dato**: el plan FREE de Supabase **NO tiene backups automáticos** (se creía que sí,
  por un informe previo sin verificar). Si se necesita backup real, hay que hacerlo manual o subir a Pro.
- **Ciclo completo verificado en producción**: solicitud de prueba `MH-260713-E57F` creada, confirmada
  (bloqueada correctamente por falta de stock del producto de prueba, y luego por el trigger mientras el
  frontend viejo seguía desplegado), y tras el deploy del fix, el flujo confirmar/cancelar quedó operativo.
- **`sql/008-blindaje-stock.sql` — EJECUTADO EN PRODUCCIÓN** (mismo día, más tarde): cierra el ítem C3 —
  `stock_actual` ya no se puede editar directo (ni por REST con sesión staff ni por SQL a mano): el trigger
  `tr_productos_guard_stock` exige que todo cambio de stock pase por `fn_registrar_movimiento` (flag
  transaccional `mh.stock`). El alta de producto debe nacer con stock 0. Sin CHECK >= 0 duro a propósito
  (backorder explícito con `permite_venta_sin_stock` sigue permitido). Escape de emergencia documentado
  en el propio script (DISABLE TRIGGER).

## Fase 2 (previa) — resumen

## Hecho en Fase 2
- **Feature flag** `ONLINE_PAYMENTS_ENABLED = false` en `assets/catalogo.js` (no existe UI de pago; cuando se integre MP, activar ahí).
- **Precios**: el catálogo trae precio_minorista/oferta/sku/marca/stock desde Supabase. Producto con precio → precio (+oferta tachada) + "Agregar"; sin precio → "Consultar precio" + "Cotizar". Nunca $0/NaN (`MH.fmtPrice` devuelve null si inválido). "Sin stock" solo bloquea productos CON precio (stock aún no cargado).
- **Ficha de producto** `/producto/:slug` (`producto.html`): galería (producto_imagenes), specs reales, cantidad, carrito, WhatsApp, relacionados, JSON-LD, canonical.
- **Carrito** `/carrito` (`carrito.html`): persistente (localStorage `mh_cart_v1`), cantidades, quitar, totales honestos ("Total a confirmar" si hay items sin precio), releé precios vivos de la base al abrir.
- **Solicitud**: formulario (nombre/teléfono/localidad/entrega/dirección condicional/mayorista/observaciones, honeypot) → RPC `crear_solicitud` (valida y re-lee precios EN SERVIDOR, rate-limit 5/tel/hora) → mensaje WhatsApp ordenado con código MH-YYMMDD-XXXX → wa.me. **Si la RPC no está desplegada, degrada con gracia y sale igual por WhatsApp.** No descuenta stock (se confirma manualmente).
- **Formulario mayorista** en `index.html` (#mayorista): guarda solicitud canal='mayorista' + WhatsApp.
- **Admin**: nueva página `admin/solicitudes.html` (sección Ventas en `layout.js`): lista, filtros, detalle, cambio de estado (nueva→…→entregado/cancelado), export CSV, responder por WhatsApp.
- **WhatsApp configurable**: se lee de `site_settings.whatsapp` (editable en panel) y se reescriben todos los links wa.me en runtime (`MH.syncWaLinks`); el hardcodeado queda solo como fallback.
- **Buscador**: ahora busca por nombre+descripción+marca+SKU+categoría; orden por precio y chips "Con precio"/"Ofertas" aparecen solo si hay datos.
- **BUG REAL CORREGIDO**: `supabase-config.js` usaba `const` global (no crea `window.SUPABASE_URL`) → la tienda pública SIEMPRE caía al JSON de respaldo. Ahora expone `window.*` y el catálogo es 100% vivo desde Supabase.
- **Analítica**: `MH.track()` no-op (GA4/Meta no instalados; sin datos personales).
- Rewrites `/producto/:slug` y `/carrito` en `vercel.json` + `scripts/server.js`.

## Validación (local con Supabase real, 2026-07-04)
137 productos vivos; agregar/quitar/cantidades/persistencia OK; ficha OK (galería, relacionados, JSON-LD); carrito mixto y totales "a confirmar" OK; validación de formulario OK; mensaje WhatsApp sin undefined/null OK; RPC 404 → fallback OK; estados con precio/oferta/sin stock/precio-0 OK; categoría y 404 OK; móvil OK.

## Bloqueos
1. ~~Ejecutar `sql/006` y `sql/007` en Supabase~~ — **HECHO 2026-07-13**, verificado en producción.
2. Precios: se cargan desde /admin cuando el dueño quiera (catálogo externo en Drive; NO automatizar).
   **0 de 137 productos con precio/stock al 2026-07-05** — sigue pendiente de carga real.
3. Confirmar usuario admin del dueño creado en Supabase (y desactivar el del desarrollador al transferir).
4. ~~Rama `research/sistema-operativo-mundo-hogar` sin mergear~~ — la rama ya no existe; lo útil quedó en
   `main` (`sql/borradores-no-ejecutados/008-multideposito-BORRADOR.sql`, commit `5986736`). La
   documentación de negocio vive fuera del repo (`docs/` está excluido por ser repo público).
5. Supabase FREE no tiene backups automáticos: hacer uno manual (o subir a Pro) antes de cargar precios
   y stock reales.

## Archivos importantes
- `sql/013-local-compras-stock.sql` + `GUIA-STOCK-Y-VENTAS.md` — stock controlado, caja, compras.
- `assets/catalogo.js` — MH: catálogo, precios, disponibilidad (availability), Cart, settings, track.
- `producto.html`, `carrito.html`, `admin/solicitudes.html`, `sql/005-solicitudes.sql`.
- `supabase-config.js` — ahora expone window.* (crítico, no revertir).
- `wrangler.jsonc` / `_redirects` / `_headers` — hosting de producción (Cloudflare).
- `vercel.json` / `scripts/server.js` — mismas reglas para el espejo de Vercel y el servidor local.

## Próxima acción
0. ~~Ejecutar `sql/013` en producción~~ — HECHO 2026-10-29. ~~Desplegar `leer-lista-compra` y `asistente`~~ — HECHO
   2026-11-02 (las tres Edge Functions están en producción; los deploys los corre el dueño con
   `! npx supabase functions deploy <nombre> ... --yes`, el modo automático de Claude Code no puede).
   Después: contar stock por sector desde el celular (Contar stock → "Sin contar") y vender desde la caja.
0b. Probar en producción el ticket impreso (Caja → cobrar → Imprimir) y las etiquetas (Productos → 🏷️)
   con la impresora real; ajustar medidas en `impresion.js` (`FORMATOS`) si el rollo es otro.
1. Cargar el secreto `ANTHROPIC_API_KEY` en Supabase (lectura automática de comprobantes y
   asistente del panel), cargar las cuentas reales, borrar la cuenta y el pedido de prueba, y
   recién después prender `carrito_activo` desde Configuración (ver `GUIA-COBROS.md`).
2. Carga real de precios y stock desde el panel (lado del dueño).
3. Cerrar la mudanza: subir la versión mínima de TLS a 1.2 en Cloudflare y decidir si el espejo de Vercel
   se borra (si se borra, quitar `vercel.json`).
4. Mejora futura: verificar ingresos por API de Mercado Pago (hoy la verificación final es manual
   o por confirmación automática opcional).
