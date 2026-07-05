# Informe de auditoría completa — Mundo Hogar (2026-07-05)

## 1. Estado inicial y tecnologías

- **Tienda pública**: HTML/CSS/JS estático (sin framework, sin build). Páginas: inicio, `/productos`, `/categorias[/slug]`, `/producto/:slug`, `/carrito`, 404.
- **Base de datos**: Supabase (Postgres + Auth + Storage + RLS). La tienda lee por REST con la clave pública; el panel usa supabase-js v2.
- **Hosting**: Vercel (repo `Ferreya1701/mundo-hogar`, rama `main`, deploy automático). `vercel.json` maneja rewrites y headers de seguridad.
- **Panel admin** (`/admin`): login con Supabase Auth, roles (administrador / encargado_stock / vendedor), módulos de dashboard, solicitudes, productos, categorías, inventario, historial, alertas, usuarios y (nuevo) configuración.
- **Pagos**: NO hay Mercado Pago integrado. El flujo de venta es carrito → solicitud → WhatsApp. Hay un flag `ONLINE_PAYMENTS_ENABLED=false` preparado para el futuro.

## 2. Problemas encontrados

| # | Problema | Gravedad | Estado |
|---|----------|----------|--------|
| 1 | El bucket de imágenes `producto-imagenes` no existía en Supabase → subir imágenes desde el panel fallaba | Crítico | SQL 006 listo — **requiere ejecutarlo** |
| 2 | La tabla `solicitudes` y la función `crear_solicitud` no estaban en la base (el SQL 005 nunca se ejecutó) → los pedidos no se guardaban y la página Solicitudes del panel fallaba | Crítico | SQL 006 listo — **requiere ejecutarlo** |
| 3 | Faltaban las políticas de Storage (lectura pública, subida solo staff) | Crítico | Incluidas en SQL 006 (con política UPDATE que faltaba en el 004 original) |
| 4 | Tablas viejas en inglés (`products`, `categories`, `product_images`, `orders`, `order_items`), vacías, generaban confusión | Importante | SQL 006 las elimina solo si están vacías (verificado) |
| 5 | La tabla `site_content` (textos de la home) existía pero nadie la usaba: ni la tienda la leía ni el panel la editaba | Importante | Resuelto (panel + tienda conectados) |
| 6 | `site_settings` (WhatsApp, envíos, datos) no era editable desde el panel | Importante | Resuelto (página Configuración) |
| 7 | 404.html con diseño viejo dorado/oscuro, ajeno a la marca | Medio | Resuelto (azul/naranja + logo) |
| 8 | og:image y JSON-LD usaban la foto de una heladera en vez del logo | Menor | Resuelto |
| 9 | Sitemap sin el hub `/categorias` | Menor | Resuelto |
| 10 | Ningún producto tiene precio ni stock cargado (0 de 137) | Dato del negocio | Pendiente del propietario (la tienda muestra "Consultar precio" correctamente) |

## 3. Archivos modificados / creados

- `sql/006-puesta-a-punto.sql` (NUEVO) — bucket + políticas storage + solicitudes/RPC + limpieza + sincronización de textos. Copia lista para pegar: `C:\Users\Usuario\Desktop\MUNDO-HOGAR-SQL-2.txt`.
- `admin/configuracion.html` (NUEVO) — edición de datos del negocio (site_settings) y textos de la home (site_content).
- `admin/js/layout.js` — ítem "Configuración" en el menú (solo administrador).
- `assets/catalogo.js` — `loadContent()` y `applyContent()` (textos editables con protección del diseño: el título solo se aplica si usa el formato `parte normal|parte naranja`).
- `index.html` — 8 textos conectados a la base (hero, mayorista, envíos, pagos, footer) con respaldo local; og:image/JSON-LD con el logo.
- `404.html` — rediseñada con la identidad azul/naranja y el logo real.
- `sitemap.xml` — hub de categorías + fechas actualizadas.

Commits: `49ee52e` (fix SQL), `16baa18` (feat configuración), `a9e620b` (feat textos editables), `37363d9` (improve 404/SEO). Todo pusheado y desplegado.

## 4. Cambios de base de datos (SQL 006 — PENDIENTE DE EJECUTAR)

El archivo `Desktop\MUNDO-HOGAR-SQL-2.txt` (sin comentarios, listo para pegar) hace, en este orden:
1. Crea el bucket público `producto-imagenes` + 4 políticas de Storage.
2. Crea `solicitudes` + `solicitud_items` + índices + RLS + la función pública `crear_solicitud` (valida y sanitiza todo en el servidor, relee precios de la base, límite anti-abuso por teléfono y global).
3. Elimina las tablas viejas en inglés **solo si están vacías** (si alguna tuviera datos, avisa y no la toca).
4. Sincroniza `hero_titulo`/`hero_subtitulo` con el texto actual de la portada.

Es idempotente: se puede ejecutar más de una vez sin romper nada.

## 5. Pruebas realizadas

- Home local: sin errores de consola ni requests fallidos; textos de la base aplicados conservando el diseño (título naranja, eyebrow con ícono).
- 404: contenido y botones correctos (Inicio / Ver productos / WhatsApp).
- `/admin/configuracion.html` sin sesión → redirige al login (ruta protegida OK).
- Producción verificada tras el deploy: configuración (200), sitemap (200), 404 con logo y texto nuevos, `catalogo.js` con `loadContent` en vivo.
- Base por REST: 137 productos activos, RLS pública OK, `site_settings`/`site_content`/`banners` accesibles en lectura.
- No aplica build/lint/TypeScript: el sitio es estático sin toolchain (verificación = navegador + consola + producción).

## 6. Qué quedó operativo y qué falta

**Operativo hoy**: tienda completa (catálogo, ficha, carrito, categorías, búsqueda/filtros), pedido por WhatsApp con respaldo aunque falle la base, panel (login, roles, productos CRUD, categorías CRUD con protección de borrado, inventario con movimientos atómicos, alertas, usuarios, configuración), textos de la home editables, RLS correcta, deploy automático.

**Queda pendiente (requiere acción del propietario/usuario)**:
1. **Ejecutar `MUNDO-HOGAR-SQL-2.txt`** en Supabase → SQL Editor (habilita: subir imágenes, registro de solicitudes, limpieza).
2. **Cargar precios y stock** de los productos desde el panel (hoy todo muestra "Consultar precio").
3. Completar datos reales en Configuración: email, dirección exacta, horarios, redes.
4. Información legal (políticas de devolución, términos): no se inventó; cuando el negocio la defina se agrega.

## 7. Sugerencias clasificadas

### Prioridad alta (antes de entregar)
- **Ejecutar SQL 006** (5 min, complejidad baja) — habilita imágenes y solicitudes.
- **Cargar precios/stock** de al menos los productos destacados (complejidad baja, tiempo del dueño) — beneficio directo en conversión: precio visible vende más que "consultar".
- **Probar el flujo completo de compra real** (agregar al carrito → enviar → ver la solicitud en el panel) una vez ejecutado el SQL.

### Prioridad media
- **Dominio propio** (ej: mundohogar.com.ar) en Vercel (baja) — confianza y marca.
- **Google Analytics 4 o Meta Pixel** (baja) — los eventos ya se emiten desde el código (`track()`); solo falta pegar el snippet.
- **Optimizar imágenes a WebP** (media) — hoy son JPG ~100-300 KB; WebP bajaría ~40% el peso.
- **Página "Cómo comprar" / preguntas frecuentes ampliada** (baja) — reduce consultas repetidas.

### Prioridad baja
- Mercado Pago con checkout real (alta complejidad) — el flag ya existe; requiere backend/función serverless para crear preferencias sin exponer credenciales.
- Multi-imagen por producto desde el panel (media) — la tabla `producto_imagenes` ya existe; falta la UI de galería.
- Banners administrables en la home (media) — la tabla `banners` ya existe.

## 8. Guía rápida para el propietario

- **Entrar al panel**: `https://mundo-hogar-tan.vercel.app/admin/` con tu email y contraseña.
- **Crear/editar producto**: Productos → "+ Nuevo producto" (o ✏️ en la lista). Completá nombre, categoría, precio minorista, stock inicial y foto (clic o arrastrar). "Destacado" lo muestra en la portada.
- **Cambiar precio o stock**: Productos → ✏️ → editar precio → Guardar. El stock posterior se maneja desde "Registrar Movimiento" (entradas, salidas, ajustes) para que quede historial.
- **Ofertas**: en el producto, activá "En oferta" y cargá el precio de oferta (el precio anterior aparece tachado en la tienda).
- **Categorías**: Categorías → crear/editar/desactivar. No deja borrar una categoría con productos.
- **Textos y datos del negocio**: Configuración → cambiá WhatsApp, horarios, textos de la portada → Guardar (se ve al instante en la web).
- **Pedidos**: Solicitudes WhatsApp → cada pedido del carrito queda registrado con estado (nueva → contactado → entregado).
- **Respaldo**: la base está en Supabase (backups automáticos diarios en el plan gratuito por 7 días). El código está en GitHub. Recomendado: una vez por mes, Supabase → Database → Backups para verificar.

## 9. Credenciales y variables

- Única "variable" del frontend: `supabase-config.js` (URL del proyecto + clave publishable, que es pública por diseño; los datos se protegen con RLS).
- **Nunca** poner en el código la clave `sb_secret_...` ni la contraseña de la base.
- No hay variables de entorno en Vercel (sitio estático, no las necesita).
