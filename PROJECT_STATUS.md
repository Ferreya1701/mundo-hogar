# PROJECT_STATUS — Mundo Hogar / TIAF

> Consultar este archivo antes de re-analizar el proyecto. Actualizado: 2026-07-13.

## Fase actual
**Núcleo de stock ↔ ventas implementado en local (sin commit/deploy).** Auditoría 2026-07-13 y paquete
completo de entregables en `..\..\08_ENTREGABLES\` (auditoría, procesos, diseño de stock, modelo de
datos, roadmap, propuesta ejecutiva, demo HTML).

## Hecho en esta sesión (2026-07-13)
- **`sql/007-nucleo-stock.sql` (NUEVO)**: (1) cierra hallazgo crítico H1 — `fn_registrar_movimiento` era
  ejecutable por anónimos vía REST (SECURITY DEFINER sin REVOKE ni chequeo de rol); ahora exige rol
  staff + REVOKE de PUBLIC/anon. (2) RPC `cambiar_estado_solicitud`: máquina de estados, confirmar
  descuenta stock (`salida_venta`, referencia = código MH), cancelar repone (`devolucion_cliente`),
  idempotente vía `solicitudes.stock_descontado`. (3) Tabla `solicitud_eventos` (bitácora inmutable).
  (4) Trigger que bloquea UPDATE directo de `estado`. Idempotente; pendiente de ejecutar en Supabase.
- **`admin/solicitudes.html`**: `cambiarEstado` usa la RPC; degrada al UPDATE directo con aviso si el
  007 no está ejecutado; errores amigables (faltantes por producto, transición inválida, permisos).

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
1. **Ejecutar `sql/006-puesta-a-punto.sql` y luego `sql/007-nucleo-stock.sql` en Supabase → SQL Editor**
   (dueño/TIAF). El 006 habilita solicitudes+imágenes; el 007 cierra el agujero de seguridad y conecta
   stock↔ventas. Los cambios locales de esta sesión están SIN commitear (revisar y commitear).
2. Precios: se cargan desde /admin cuando el dueño quiera (catálogo externo en Drive; NO automatizar).
3. Confirmar usuario admin creado en Supabase.

## Archivos importantes
- `assets/catalogo.js` — MH: catálogo, precios, Cart, settings, track, flag pagos.
- `producto.html`, `carrito.html`, `admin/solicitudes.html`, `sql/005-solicitudes.sql`.
- `supabase-config.js` — ahora expone window.* (crítico, no revertir).
- `vercel.json` / `scripts/server.js` — rewrites.

## Próxima acción
Ejecutar `sql/005-solicitudes.sql` en Supabase y probar el ciclo completo solicitud→admin en producción. Luego Fase 3 (según plan): pedidos con pago online (MP) — mantener flag apagado hasta entonces.
