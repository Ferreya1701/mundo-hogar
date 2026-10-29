# PROJECT_STATUS — Mundo Hogar / TIAF

> Consultar este archivo antes de re-analizar el proyecto. Actualizado: 2026-10-29 (stock real: caja, compras, conteo).

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

## Stock real: ventas en el local, compras y conteo (2026-10-29) — CÓDIGO LISTO, SQL PENDIENTE DE EJECUTAR
Guía: `GUIA-STOCK-Y-VENTAS.md`. Objetivo: que el stock sea confiable para vender online.
- **`sql/013-local-compras-stock.sql`** — ESCRITO Y PROBADO (`scripts/test-stock-sql.mjs`, 109 pruebas en
  PGlite), **todavía NO ejecutado en producción**. Hasta ejecutarlo, las páginas nuevas del panel muestran
  "falta ejecutar sql/013" y la tienda/dashboard/alertas/carrito degradan al comportamiento anterior
  (piden las columnas nuevas y, si no existen, repiten sin ellas).
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
- **Edge Function `supabase/functions/leer-lista-compra/index.ts`** — NO desplegada todavía. Lee foto/PDF/
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
0. **Ejecutar `sql/013-local-compras-stock.sql` en producción** (`npx supabase db query --linked
   --project-ref zydotmaolgddwenwywyc -f sql/013-local-compras-stock.sql`) y desplegar
   `leer-lista-compra`. Después: contar stock por sector desde el celular y vender desde la caja.
1. Cargar el secreto `ANTHROPIC_API_KEY` en Supabase (lectura automática de comprobantes y
   asistente del panel), cargar las cuentas reales, borrar la cuenta y el pedido de prueba, y
   recién después prender `carrito_activo` desde Configuración (ver `GUIA-COBROS.md`).
2. Carga real de precios y stock desde el panel (lado del dueño).
3. Cerrar la mudanza: subir la versión mínima de TLS a 1.2 en Cloudflare y decidir si el espejo de Vercel
   se borra (si se borra, quitar `vercel.json`).
4. Mejora futura: verificar ingresos por API de Mercado Pago (hoy la verificación final es manual
   o por confirmación automática opcional).
