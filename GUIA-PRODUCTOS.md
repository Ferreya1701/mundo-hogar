# Productos: fotos, precios, stock y publicar (2026-11-12)

Guía corta para quien carga productos. Todo esto está en el menú **Catálogo**.

## La pantalla para trabajar rápido: Completar productos
`Catálogo → Completar productos`. Una fila por producto, todo se guarda solo:
- **Foto:** arrastrala sobre el producto, pegala con Ctrl+V, o tocá **＋** (en el celular, **📷 Sacar foto**).
  Se achican solas (una foto de 6 MB queda en ~200 KB). Hasta 12 por producto; la primera es la
  **principal**. Con las flechas ◀ ▶ se cambia el orden y con ✕ se quita.
- **Precio:** escribilo y apretá **Enter**: guarda y salta al producto siguiente.
- **Categoría:** se elige de la lista.
- **Publicar:** el botón se habilita cuando tiene foto, precio y categoría. Arriba, **"Publicar los N
  listos"** publica de una todos los que ya están completos.
- Filtros: *Les falta algo*, *Listos para publicar*, *Sin foto*, *Sin precio*, *Sin categoría*,
  *Publicados*. Buscador por nombre, SKU o código del sistema viejo (sin importar acentos).
- Tildando varios: poner el mismo precio, subir/bajar un %, cambiar categoría, publicar u ocultar.
- La barra de arriba muestra el avance (publicados sobre el total). En **Inicio** aparece el aviso de
  cuántos productos cargados todavía no están en la tienda.

## Precios de muchos productos a la vez
- **Planilla:** `Catálogo → Importar artículos`, con un CSV de dos columnas: `codigo` y `precio`.
  Es lo más rápido para la lista de precios del sistema viejo.
- **En pantalla:** en Completar productos o en Productos, tildar varios → *Poner precio* (fijar un
  precio, subir/bajar un %, o sumar un monto; con redondeo). Si una oferta queda más cara que el
  precio nuevo, se apaga sola.

## La ficha del producto
`Productos → ✏️`. Arriba lo esencial (nombre, precio, categoría, marca) y las fotos. Lo demás está
plegado: descripción, códigos, costo/proveedor/mayorista, medidas. A la derecha, **En la tienda**
muestra qué le falta para publicarse, y **Stock** explica de dónde sale el número.
- El código interno (SKU) se genera solo si se deja vacío.
- Cambiar el nombre ya no cambia el link del producto en la tienda.
- Oferta: tiene que ser más barata que el precio de venta (lo avisa y no deja guardar si no).
- El margen sobre el costo se calcula solo.

## Stock: qué significa cada cosa
| En pantalla | Qué es |
|---|---|
| **~15 · sin contar** | Número de referencia (viene del sistema viejo). No frena ventas ni se descuenta. |
| **15** (en color) | Contado en el local. Baja solo con cada venta y avisa si queda poco. |
| **—** | Sin contar y sin número. |

Se cuenta en `Stock → Contar stock`. Hasta que un producto no está contado, la tienda web lo muestra
como "Consultar" (no lo vende online), aunque esté publicado. En la caja se vende siempre.

## Publicado, oculto, archivado
- **Publicado:** se ve en la tienda.
- **Oculto:** solo en el panel y la caja (así entraron los importados).
- **Archivado:** ya no se vende; no aparece en ningún lado.
Publicar de a muchos solo publica los completos (foto + precio + categoría). De a uno se puede publicar
igual, con aviso (sin precio la tienda dice "Consultar").

## Por dentro
`admin/completar.html`, `admin/js/fotos.js` (compresión y galería), `sql/023-fotos-precios-publicar.sql`
(`producto_fotos_guardar`, `productos_precio_masivo`, `productos_publicar`, permisos de fotos con
"Crear y editar productos"). Las listas piden los productos de a 1000 (`Utils.traerTodo`): Supabase
corta ahí y el catálogo ya tiene más. Pruebas: `node scripts/test-fotos-precios-sql.mjs` (21).

## Ubicación: dónde está guardado cada producto (sql/024)
Cada producto tiene **una** ubicación, elegida de una lista que arman ustedes: un **lugar** (local,
depósito…) y, si quieren, un **sector** (fila, estante). Ej.: "Depósito 1 · Fila B", "Local Blas Parera".
No divide el stock por lugar: dice adónde ir a buscarlo.

- **La forma rápida de cargarlas:** en `Stock → Contar stock`, abajo aparece **"📍 Estoy contando en…"**.
  Se elige el lugar y todo lo que se cuente queda ubicado ahí al guardar. El filtro de ubicación
  ("Sin ubicación" incluido) sirve para contar un lugar por vez.
- **De a muchos:** en Productos o Completar productos, tildar varios → **📍 Ubicación**.
- **De a uno:** en la ficha, tarjeta Stock → "Dónde está guardado". El ⚙ abre la lista para agregar,
  corregir o desactivar ubicaciones (no se borran).
- **Dónde se ve:** en Productos (y se puede buscar escribiendo el lugar), en Contar stock y en
  **Crear venta**, al lado de cada producto, para saber adónde ir a buscarlo.
- Pueden ubicar y armar la lista quienes tengan "Crear y editar productos", "Contar stock" o
  "Ajuste manual". Verla, todo el personal.
- Pruebas: `node scripts/test-ubicaciones-sql.mjs` (18).
