# Informe de Auditoría, Corrección y Optimización — Mundo Hogar

**Fecha:** 29 de junio de 2026
**Sitio:** https://mundo-hogar-tan.vercel.app/
**Repositorio:** github.com/Ferreya1701/mundo-hogar
**Estado final:** ✅ Sitio publicado y funcionando (error 404 resuelto)

---

## Resumen para el dueño (en 1 minuto)

El sitio **ya no da error 404**: ahora abre correctamente desde el enlace público y al recargar
cualquier sección. Se eliminaron **todas** las referencias a Tiendanube (el proyecto ya no depende
de esa plataforma), se corrigieron datos (ubicación, año, enlaces rotos), se agregó SEO completo,
una página de error 404 propia y un sistema de imagen de respaldo.

La web es hoy una **landing page profesional con catálogo en fotos** donde el cliente consulta por
WhatsApp. Existe además un **panel de administración propio** (carpeta `/admin`) listo para funcionar
en cuanto se configure la base de datos (Supabase). **Mercado Pago con pago online todavía no está
integrado** porque esa parte vivía en Tiendanube; abajo se explica exactamente qué falta.

---

## 1. Causa exacta del error 404

El proyecto se sirve en Vercel **sin framework y sin build**. En esa situación, Vercel adopta por
defecto la carpeta **`public/`** como "Output Directory" (raíz del sitio) **si esa carpeta existe**.
El repo tiene una carpeta `public/` (con las imágenes), así que Vercel estaba sirviendo el contenido
de `public/` como si fuera la raíz del sitio.

Como **no existe `public/index.html`**, la página de inicio y todas las rutas devolvían
`404 NOT_FOUND`. Lo único que funcionaba eran las imágenes (`/images/...` resolvía a
`public/images/...`). Se confirmó técnicamente:

- `https://.../` → 404 `NOT_FOUND`
- `https://.../images/productos/herramientas/HPC0442.jpg` → **200 OK**

Es decir: el `index.html` estaba en la raíz del repositorio, pero Vercel servía una carpeta interna.

## 2. Solución aplicada

Se creó/commiteó un **`vercel.json`** que fuerza la raíz del repositorio como salida:

```json
{
  "outputDirectory": ".",
  "rewrites": [
    { "source": "/images/:path*", "destination": "/public/images/:path*" }
  ],
  "headers": [ /* seguridad + caché de imágenes */ ]
}
```

- `"outputDirectory": "."` → Vercel sirve la raíz (donde está `index.html`). **Esto resuelve el 404.**
- El `rewrite` mantiene `/images/...` apuntando a `public/images/...` (las fotos siguen cargando).
- Antes este `vercel.json` existía en local **pero nunca se había subido al repositorio**, y además le
  faltaba el `outputDirectory`.

**Verificación post-deploy (en vivo):** `/`, `/index.html`, `/admin/`, `/robots.txt`, `/sitemap.xml`
y las imágenes responden **200**; una ruta inexistente devuelve la **404 personalizada**.

> **Nota de respaldo:** si en el futuro el 404 reapareciera, revisar en el panel de Vercel
> (Settings → Build & Deployment) que **Root Directory esté vacío** y que no haya un Output Directory
> forzado a `public`. El `vercel.json` ya cubre el caso normal.

## 3. Archivos modificados / creados

| Archivo | Cambio |
|---|---|
| `vercel.json` | **Creado/commiteado** — fix del 404 + headers de seguridad |
| `index.html` | Tiendanube eliminado, CTAs reapuntados, SEO, datos corregidos, fallback de imágenes |
| `404.html` | **Nuevo** — página de error personalizada |
| `robots.txt` | **Nuevo** — SEO, bloquea /admin, /sql, /scripts |
| `sitemap.xml` | **Nuevo** — SEO |
| `.gitignore` | Ignora `.claude/` y duplicados de imágenes en la raíz |
| `admin/` (14 archivos) | Panel admin versionado |
| `sql/` (4 archivos) | Esquema de base de datos versionado |
| `supabase-config.js` | Plantilla de configuración (sin credenciales reales) |
| `ADMINISTRADOR-MUNDO-HOGAR.md` | Manual del panel versionado |
| `INFORME-AUDITORIA-2026-06-29.md` / `TRANSFERENCIA-PROPIETARIO.md` | **Nuevos** — esta documentación |

Backup de seguridad: rama **`backup/deploy-state-2026-06-29`** (estado previo) + copias locales.

## 4. Errores encontrados

1. **404 total del sitio** (causa raíz arriba).
2. **Dependencia de Tiendanube**: ~16 enlaces a `mundohogar47.mitiendanube.com`, logo "TN" y crédito
   "Tienda impulsada por Tienda Nube".
3. **Ubicación equivocada**: decía "Buenos Aires" (el negocio es **Santa Fe Capital**).
4. **Enlaces rotos**: botones de comunidad apuntaban a `chat.whatsapp.com/XXXXXXX` (placeholder).
5. **Copyright desactualizado** ("© 2025").
6. **Sin SEO**: faltaba meta description, Open Graph, canonical, favicon, datos estructurados,
   sitemap y robots.
7. **Sin página 404 propia** ni sistema de imagen de respaldo.
8. **`vercel.json` y panel admin sin commitear** (existían solo en la PC).

## 5. Errores corregidos

Todos los puntos del apartado 4 quedaron corregidos y verificados en producción, salvo las tareas
que dependen de credenciales del dueño (Supabase / Mercado Pago), detalladas en los puntos 7 y 8.

## 6. Botones y enlaces reparados

- **Hero "Ver todos los productos"** → ahora va a la galería interna (`#galeria`).
- **Tarjetas de categoría (8)** → galería interna.
- **"Ver catálogo completo" / "Ver tienda completa"** → galería interna.
- **Tarjeta "Tienda Online" (contacto)** → reemplazada por "Ver catálogo" (galería).
- **Columna del footer "Tienda Online"** → reemplazada por enlaces internos (productos, ofertas,
  hacer pedido por WhatsApp, contacto).
- **Botones de comunidad WhatsApp (2)** → ahora abren un chat real de WhatsApp.
- **Galería**: cada producto tiene botón "Consultar precio" que abre WhatsApp con el nombre del
  producto precargado. **Funciona.**
- WhatsApp flotante, header, menú móvil, contacto, mailto: revisados y operativos.

**No queda ningún botón muerto ni enlace a una plataforma externa que ya no se usa.**

## 7. Estado de Mercado Pago

**No hay integración de pago online en el código actual.** El sitio nunca tuvo checkout propio: el
pago con Mercado Pago se hacía **dentro de Tiendanube**. Al quitar Tiendanube, el modelo de venta
vigente es **consulta y cierre por WhatsApp** (el cliente consulta precio/stock y coordina el pago).

Las menciones a "Mercado Pago / hasta 12 cuotas" en la web son **informativas** (medios de pago que
se aceptan al coordinar la compra), no un botón de pago.

**Para tener pago online real con Mercado Pago** se necesita construir un checkout propio. Como el
hosting es estático (Vercel), esto requiere agregar **funciones serverless** (Vercel Functions) que:
1. Creen la *preferencia de pago* en el backend con el **Access Token** (nunca en el frontend).
2. Validen **precio y stock desde el servidor** (no confiar en el frontend).
3. Definan `success_url`, `failure_url`, `pending_url` y un **webhook** para confirmar el pago.
4. Registren el pedido y eviten duplicados.

Esto está **documentado pero no implementado** (excede una corrección y depende de credenciales).
Ver variables necesarias en el punto 8.

## 8. Variables de entorno necesarias

Hoy el sitio público **no usa variables de entorno** (es estático). Se necesitarán cuando se active
el panel (Supabase) y, opcionalmente, Mercado Pago. **Ninguna credencial sensible debe ir al código.**

**Supabase (para el panel `/admin`):** se cargan en `supabase-config.js` (la *anon key* es pública por
diseño; los datos se protegen con RLS):
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`

**Mercado Pago (si se implementa checkout) — en Vercel → Settings → Environment Variables, NO en el código:**
- `MP_ACCESS_TOKEN` (secreto, solo backend)
- `MP_PUBLIC_KEY`
- `MP_WEBHOOK_SECRET`
- `URL_SUCCESS`, `URL_FAILURE`, `URL_PENDING`
- Usar credenciales de **prueba** primero, luego producción. Moneda: **ARS**.

## 9. Estado de las imágenes

- **122 productos, todos con imagen** (0 productos sin foto).
- Imágenes organizadas por categoría en `public/images/productos/<categoria>/`.
- Cargan correctamente desde Vercel (verificado 200 en producción vía el rewrite `/images`).
- `object-fit: contain` en la galería → no se deforman.
- **`loading="lazy"` + `decoding="async"`** → carga diferida, mejor rendimiento.
- **Texto alternativo** descriptivo en cada imagen.
- **Sistema de respaldo nuevo:** si una foto fallara, se muestra un placeholder "MH / Imagen no
  disponible" (evita espacios vacíos), sin riesgo de bucle de error.
- **Caché de un año** para imágenes (header `Cache-Control: immutable`).

**Pendientes de imágenes** (no bloquean el sitio):
- Hay fotos **`.HEIC`** sin convertir en `imagenes de productos/_HEIC (convertir para clasificar)`
  (formato iPhone, no se ven en navegadores). No están en el sitio. Convertir a JPG/WebP para sumarlas.
- Falta una **imagen Open Graph dedicada** (1200×630) para las vistas previas al compartir; por ahora
  se usa una foto de producto.
- Algunas fotos son capturas de Instagram/MercadoLibre (resolución correcta pero estética mixta);
  conviene reemplazarlas por fotos propias con el tiempo.

## 10. Productos con información faltante

El catálogo (`src/data/productos.json`) tiene: `id, nombre, imagen, alt, categoria, slug, activo`.
**No tiene precio, stock, descripción larga, SKU ni especificaciones** — porque el modelo actual es
"consultar por WhatsApp". Esto es coherente con la web, pero esos datos **sí existen en el esquema de
la base de datos** (`sql/001-schema.sql`: precio, precio_mayorista, stock, SKU, especificaciones, etc.).

➡️ Una vez configurado el panel, el dueño podrá completar precio/stock/descripción de cada producto
**sin tocar código**. Recomendado priorizar: **precio minorista, precio mayorista y stock**.

## 11. Mejoras realizadas en las descripciones

Los **nombres** de producto ya eran específicos y descriptivos (p. ej. "Air fryer Westinghouse doble",
"Lavarropas + secarropas Codini"), no genéricos ni repetidos — se conservaron. No se inventaron
características técnicas. Las **descripciones comerciales largas** se cargarán desde el panel
(campo previsto en la base de datos) para no codificar texto producto por producto.

## 12. Referencias de Tiendanube eliminadas

**Cero referencias restantes** (verificado en el código y en el sitio en vivo):
- 16+ enlaces `mundohogar47.mitiendanube.com` (hero, categorías, footer, contacto) → reemplazados.
- Logo "TN" en la tarjeta de contacto → reemplazado por ícono de catálogo.
- Crédito "Tienda impulsada por **Tienda Nube**" en el footer → eliminado.
- La web se presenta **únicamente como plataforma propia de Mundo Hogar.**

## 13. Funcionamiento del panel administrativo

Existe un panel propio en **`/admin`** (no es de Tiendanube). Hoy muestra una pantalla
**"Configuración requerida"** hasta que se cargue Supabase. Una vez configurado, permite:
**productos** (crear/editar/activar/archivar/eliminar, imágenes, SKU, precios, destacados),
**categorías**, **inventario** (movimientos de stock), **historial** (inmutable), **alertas de stock
bajo** y **usuarios**. Incluye importación de los 122 productos desde el JSON y exportación a CSV.

**Lo que el panel todavía NO cubre:** módulo de **pedidos/ventas online** y **edición de banners/textos
de la home** (la home sigue siendo HTML; los textos se editan en `index.html`). Ver pendientes en el
punto 22.

## 14. Roles y permisos creados

Definidos en el esquema y aplicados con RLS (Supabase):

| Acción | Administrador | Encargado de Stock | Vendedor |
|---|:--:|:--:|:--:|
| Ver dashboard / productos / alertas | ✅ | ✅ | ✅ |
| Crear / editar productos | ✅ | ✅ | ❌ |
| Eliminar productos | ✅ | ❌ | ❌ |
| Movimientos de stock | ✅ | ✅ | ❌ |
| Gestionar categorías / usuarios | ✅ | ❌ | ❌ |

El **propietario** es un administrador con control total. Contraseñas gestionadas por Supabase Auth
(bcrypt + JWT), nunca en el código.

## 15. Procedimiento para transferir el proyecto

Documentado en detalle en **`TRANSFERENCIA-PROPIETARIO.md`**. Resumen: transferir el repositorio de
GitHub, el proyecto de Vercel, el proyecto de Supabase, la cuenta de Mercado Pago y el dominio; crear
un nuevo usuario administrador y quitar los accesos del desarrollador.

## 16. Mejoras de rendimiento

- Sitio **estático** (HTML+CSS inline) → carga muy rápida, sin framework pesado ni JS de más.
- Imágenes con **lazy-load**, `decoding="async"` y **caché de 1 año**.
- Fuentes con `preconnect` a Google Fonts.
- `productos.json` separado del HTML (la galería se arma en cliente, sin recargar).

## 17. Mejoras de seguridad

- **Headers** agregados: `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN`,
  `Referrer-Policy: strict-origin-when-cross-origin`, `Permissions-Policy` restrictiva.
- **Sin credenciales en el código** (Supabase usa la *anon key* pública + RLS; el Access Token de MP
  iría en variables de entorno del servidor).
- `robots.txt` desindexa `/admin`, `/sql`, `/scripts`.
- Enlaces externos con `rel="noopener"`.
- Panel: autenticación obligatoria, control de rol y cuentas desactivables.

## 18. Mejoras de SEO

- `<title>` y **meta description** orientados a Santa Fe.
- **Open Graph** + **Twitter Card** (vista previa al compartir).
- **Canonical**, **favicon**, **theme-color**, etiquetas **geo**.
- **JSON-LD** tipo `Store` (negocio local: teléfono, dirección, horarios, medios de pago, moneda ARS).
- **`sitemap.xml`** y **`robots.txt`**.
- Encabezados H1/H2 coherentes; `alt` en imágenes.

## 19. Pruebas realizadas

- ✅ Ejecución **local** con el dev server (`scripts/server.js`) — render y consola OK.
- ✅ Home, `/index.html`, `/404.html`, `robots.txt`, `sitemap.xml`, `productos.json` → 200.
- ✅ Imágenes vía rewrite `/images/...` → 200.
- ✅ **0 referencias a mitiendanube** en el HTML servido.
- ✅ `productos.json` con **122 productos**, todos con imagen.
- ✅ **En producción:** home 200, rutas internas del admin recargan 200, 404 personalizada activa,
  headers de seguridad presentes.

## 20. Resultado del nuevo deployment

Commit **`b5860b3`** subido a `main`; Vercel desplegó automáticamente. **Deploy exitoso y verificado
en vivo.** El error 404 quedó resuelto.

## 21. Enlace final de producción

**https://mundo-hogar-tan.vercel.app/**

## 22. Problemas pendientes (requieren intervención del propietario)

1. **Configurar Supabase** para activar el panel (URL + anon key, correr `sql/001..004`, crear el
   primer admin). Guía: `ADMINISTRADOR-MUNDO-HOGAR.md`.
2. **Mercado Pago online**: decidir si se quiere checkout propio (requiere desarrollo de funciones
   serverless + credenciales) o se mantiene la venta por WhatsApp.
3. **Convertir las fotos `.HEIC`** y sumarlas al catálogo.
4. **Cargar precios y stock** reales desde el panel.
5. **Imagen Open Graph** dedicada (1200×630) y **link real del grupo de WhatsApp** (hoy abre chat directo).
6. **Dominio propio** (opcional): hoy es `mundo-hogar-tan.vercel.app`; se puede conectar
   `mundohogar.com.ar` u otro. El email `ventas@mundohogar.com.ar` debe existir o cambiarse.
7. **Módulos de panel** que faltan si se desea: pedidos y edición de textos/banners de la home.

## 23. Manual básico de uso del panel

El manual completo está en **`ADMINISTRADOR-MUNDO-HOGAR.md`**. En resumen, una vez configurado:
- Ingresar a `…/admin/`, iniciar sesión.
- **Productos** → crear/editar, subir fotos, poner precio y stock, marcar destacados.
- **Inventario** → registrar entradas/salidas de stock.
- **Categorías / Usuarios** → solo administrador.
- Cambios de productos/precios/stock se reflejan **sin tocar código ni hacer deploy**.
- Para cambiar **textos o banners de la portada** hoy sí hay que editar `index.html` (pendiente de
  mover a panel).

---

*Documento generado durante la auditoría del 29/06/2026. Backup del estado previo en la rama
`backup/deploy-state-2026-06-29`.*
