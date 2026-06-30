# Informe de Rediseño de la Página Principal — Mundo Hogar

**Fecha:** 29 de junio de 2026
**Sitio:** https://mundo-hogar-tan.vercel.app/
**Estado:** ✅ Publicado y verificado en producción
**Backup previo:** rama `backup/pre-rediseno-2026-06-29`

---

## 1. Problemas detectados

- La página de inicio mostraba **el catálogo completo (137 productos)** de corrido → home larguísima, scroll interminable, sensación de "catálogo infinito" en vez de tienda.
- **No había navegación por categorías** real: las tarjetas del home llevaban a anclas genéricas y no a páginas de categoría.
- Los **productos importantes no se destacaban** (todos al mismo nivel).
- **No existía una página de catálogo** con buscador/filtros ni páginas por categoría.
- La paleta (azul marino + dorado) **no coincidía con la marca** (azul + naranja + blanco).

## 2. Cambios realizados

- **Home convertida en vidriera comercial**: dejó de listar los 137 productos; ahora muestra hero, beneficios, categorías, destacados, novedades, mayorista, FAQ y envíos.
- **Nueva paleta azul + naranja + blanco** en todo el sitio (sistema de diseño compartido).
- **Nueva página `/productos`** (catálogo completo con buscador, filtros, orden y "cargar más").
- **Nuevas páginas por categoría `/categorias/<slug>`** (7) con banner, breadcrumb, buscador interno, orden, volver y estado vacío. `/categorias` funciona como hub.
- **Carruseles** horizontales accesibles para destacados y novedades.
- Datos: se agregó el flag **`destacado`** (12 productos) y se calculan **"novedades"** por fecha de carga.

## 3. Nueva estructura de la página principal

1. Header con navegación (Inicio, Categorías, Productos, Mayorista, Contacto) + WhatsApp.
2. **Hero** azul→naranja: título "Todo para tu hogar, en un solo lugar", subtítulo, 3 botones (Ver productos / Explorar categorías / Comprar por WhatsApp) e indicadores (envíos, +10 años, compra segura) + collage de 4 categorías.
3. **Beneficios** (4 íconos: mayorista/minorista, variedad, atención, compra segura).
4. **Categorías** (7 tarjetas reales con imagen, ícono y conteo) + "Ver todas las categorías".
5. **Productos destacados** (carrusel) + "Ver todos los productos".
6. **Novedades** (carrusel) + "Ver catálogo completo".
7. **Sección mayorista** (con "Consultar precios mayoristas" → WhatsApp).
8. **Banda CTA** ("Hacé tu pedido por WhatsApp").
9. **Envíos, pagos y atención** (3 tarjetas).
10. **Preguntas frecuentes** (acordeón accesible).
11. **Footer** (contacto, enlaces, WhatsApp).

La home pasó de **~137 productos en una sola página** a **~24 productos en carruseles** + accesos: mucho más corta y rápida de recorrer.

## 4. Categorías organizadas

Se usaron las **7 categorías reales** del proyecto (no se inventó ninguna):

| Categoría | Slug / URL | Productos |
|---|---|---|
| Electrodomésticos | /categorias/electrodomesticos | 60 |
| Herramientas | /categorias/herramientas | 21 |
| Tecnología y Celulares | /categorias/tecnologia-celulares | 19 |
| Muebles y Hogar | /categorias/muebles-hogar | 20 |
| Cuidado Personal | /categorias/cuidado-personal | 10 |
| Salud | /categorias/salud | 5 |
| Seguridad | /categorias/seguridad | 2 |

Cada categoría tiene nombre, descripción, ícono, imagen representativa y conteo dinámico. La estructura es **escalable**: si se agrega una categoría nueva en los datos, aparece sola (el ruteo `/categorias/<slug>` es dinámico).

## 5. Productos sin categoría

**No hay productos sin categoría.** Los 140 productos tienen `categoria` asignada y los 137 activos se reparten en las 7 categorías de arriba (3 están archivados como duplicados de auditorías previas, no se muestran).

## 6. Productos destacados configurados

Se marcaron **12 destacados** (flag `destacado: true`), variados por rubro: Air fryer Westinghouse doble, Heladera Telefunken, Lavarropas Vitta, Robot de cocina Liliana, Smart TV Enova, Moto G05, Taladro Kanji, Amoladora Black+Decker, Sofá 2 cuerpos, Cerradura inteligente, Kit Ultracomb y Tensiómetro digital. Son **editables a futuro** (es solo un campo en los datos / panel).

## 7. Interacciones agregadas

- Aparición suave de secciones al hacer scroll (IntersectionObserver).
- Carruseles con flechas, soporte táctil, teclado (← →) y scroll-snap.
- Zoom suave de imágenes y elevación de tarjetas al hover.
- Flechas de botones que se desplazan; cambios de color en hover.
- **Skeleton loaders** mientras carga el catálogo.
- Acordeón de FAQ; menú móvil con transición.
- **Respeto por `prefers-reduced-motion`** (se desactivan animaciones).

## 8. Botones modificados

Sistema de botones unificado con estados **normal / hover / active / focus-visible / disabled**, buen contraste y área táctil ≥46px: `btn-primary` (naranja), `btn-blue`, `btn-outline`, `btn-wa`, `btn-ghost-light`, tamaños `btn-lg`/`btn-sm`. Aplicados a: Ver productos, Explorar categorías, Comprar por WhatsApp, Ver categoría, Ver todos, Cargar más, Volver, Limpiar filtros, Consultar precio, Consultar mayorista. **Ningún botón quedó sin función.**

## 9. Mejoras responsive

- Verificado en **móvil (375px)**: nav colapsa a menú hamburguesa, grillas a 2 columnas, **sin scroll horizontal**.
- Grillas de productos/categorías adaptativas; carruseles funcionan con el dedo en celular.
- Textos y botones con tamaños cómodos en mobile; toolbar de filtros sticky.

## 10. Mejoras de rendimiento

- La home **ya no carga 137 productos**: muestra 24 en carruseles → menos DOM y más rápida.
- `/productos` pagina de a **24 con "Cargar más"** (no renderiza todo junto).
- Imágenes con `loading="lazy"` + `decoding="async"` y caché de 1 año.
- Sin librerías externas (todo HTML/CSS/JS propio, ~6 KB de JS compartido). Fuentes con `preconnect`.
- Animaciones sólo con transform/opacity (baratas), y desactivadas con reduced-motion.

## 11. Archivos modificados / creados

| Archivo | Cambio |
|---|---|
| `index.html` | Reescrito como vidriera (paleta nueva, secciones, carruseles) |
| `assets/catalogo.css` | **Nuevo** — sistema de diseño compartido |
| `assets/catalogo.js` | **Nuevo** — datos, tarjetas, carruseles, metadata de categorías |
| `productos/index.html` | **Nuevo** — catálogo completo con filtros |
| `categoria.html` | **Nuevo** — plantilla de página por categoría |
| `vercel.json` | Rewrites de `/categorias` |
| `sitemap.xml` | Nuevas URLs (productos + 7 categorías) |
| `scripts/server.js` | Dev server con el nuevo routing |
| `src/data/productos.json` | Flag `destacado` en 12 productos |

## 12. Rutas creadas

- `/productos` — catálogo completo.
- `/categorias` — hub de categorías.
- `/categorias/electrodomesticos`, `/herramientas`, `/tecnologia-celulares`, `/muebles-hogar`, `/cuidado-personal`, `/salud`, `/seguridad`.

Todas funcionan al recargar y por enlace directo (rewrites en `vercel.json`).

## 13. Cambios en el panel administrativo

El panel (`/admin`, Supabase) ya contempla productos, categorías, destacados, ofertas y novedades en su esquema. **Lo nuevo se diseñó para alinearse con eso**: el flag `destacado` y la asignación de categoría son los mismos campos que maneja el panel. Una vez configurado Supabase, el dueño podrá marcar destacados/ofertas/novedades y crear categorías **sin tocar código**. *Pendiente real:* hoy la vidriera lee de `productos.json`; para que el panel controle 100% la portada hay que conectar la web a la base de Supabase (ver recomendaciones).

## 14. Pruebas realizadas

Verificado (local con navegador real + producción por HTTP):
- Home: 7 categorías con conteo, 12 destacados, 12 novedades, hero con 3 CTAs, WhatsApp flotante. ✅
- `/productos`: 8 chips, 24 productos iniciales, "137 productos", **filtro por categoría** (electro→60), **buscador** ("air fryer"→7), **orden**, **limpiar filtros**, **cargar más**. ✅
- `/categorias/electrodomesticos`: título/H1/descr/breadcrumb/canonical correctos, 60 productos. ✅
- `/categorias` (hub): 7 tarjetas. ✅
- **Responsive móvil 375px**: nav→hamburguesa, 2 columnas, sin scroll horizontal, menú abre/cierra. ✅
- Rutas en producción: `/`, `/productos`, `/categorias`, `/categorias/<slug>`, `/assets/*`, `/sitemap.xml` → **200**. ✅
- Sin errores en consola del navegador. ✅

## 15. Capturas

La verificación se hizo con un navegador real controlado por herramientas (inspección del DOM, interacción con filtros y prueba responsive). La **captura de imagen automática no pudo generarse** por una limitación del entorno de preview (timeout), pero todo el comportamiento quedó verificado funcionalmente. Recomiendo al dueño abrir el sitio en celular y escritorio para una revisión visual final.

## 16. Problemas pendientes

- **Ofertas con precio**: no hay precios/descuentos cargados, así que no hay sección de "Ofertas" con precio anterior/actual (sería inventar datos). La estructura está lista; se activa cuando se carguen precios desde el panel.
- **"Más vendidos"**: requiere datos de ventas; hoy se priorizan "Destacados" y "Novedades".
- **Portada 100% editable desde el panel**: requiere conectar la web a Supabase (hoy lee `productos.json`).
- **Imagen Open Graph dedicada** (1200×630) para compartir.

## 17. Recomendaciones futuras

1. **Configurar Supabase** y migrar la lectura de productos de `productos.json` a la base, para que destacados, ofertas, novedades, categorías y textos se administren desde `/admin` sin deploy.
2. **Cargar precios** (minorista/mayorista) para habilitar la sección de Ofertas y filtros por precio.
3. **Conectar un dominio propio** y agregar Google Analytics (seguimiento de clics de WhatsApp) y Meta Pixel para las campañas.
4. Sumar fotos propias para reemplazar las capturas de Instagram/MercadoLibre y una portada (OG) de marca.

---
*Rediseño del 29/06/2026. Backup del estado previo en `backup/pre-rediseno-2026-06-29`.*
