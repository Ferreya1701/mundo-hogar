# Importar artículos del sistema anterior (sql/021, 2026-11-11)

Pantalla: **Catálogo → Importar artículos** (`/admin/importar`). Permiso: "Crear y editar productos".

> El repo es público: **las planillas con datos del negocio NO se suben al repo.** El archivo se lee
> en el navegador y va directo a la base.

## El archivo
CSV (separado por `;` o `,`) con columnas: `codigo`, `descripcion`, `marca`, `rubro`, `stock`,
`precio`, `observaciones`. Acepta otros nombres comunes (cod, nombre, categoría, cantidad, precio venta…).
Para una **lista de precios** alcanza con `codigo` y `precio`.

El listado "Stock de Artículos" (PDF del sistema viejo, Crystal Reports) se pasó a CSV leyendo la
posición de cada palabra en el PDF (los códigos y descripciones cortados en dos renglones se unen; las
"variantes" van a observaciones). Resultado del 11/11/2026: 972 artículos, 28 rubros, sin precios. Conversor: `scripts/catalogo-pdf-a-csv.py`.

## Pasos en la pantalla
1. **Elegir el archivo.** Se lee en la computadora; no se sube nada hasta confirmar.
2. **Rubros → categorías.** Se recuerda en ese navegador para la próxima vez.
3. **Qué es cada "marca".** En el sistema viejo ese campo mezcla marcas reales (Kanji, Ultracomb…)
   con orígenes/proveedores (Buenos Aires, Córdoba, Rosario, Litoral). Proveedor se guarda aparte
   (`producto_costos`, no se ve en la tienda); "NINGUNA" se ignora.
4. **Revisar artículos.** "ENVIO" y similares vienen destildados. **Posibles duplicados**: hasta 3
   productos de la web que se le parecen; elegir "Es el mismo que…" para vincular en vez de crear
   otro (con 80% o más ya viene elegido).
5. **Importar** (tandas de 150) → resumen, errores por renglón y CSV con el resultado.

## Qué hace con cada artículo
- **Nuevo:** producto **inactivo** (no se ve en la tienda hasta tener precio y foto; se activa desde
  Productos), SKU = código viejo si está libre (si no, MH-xxxxx), stock como **referencia sin contar**
  (negativos → 0). Se puede vender en el local desde el primer día.
- **Vinculado / ya importado:** no cambia nombre, estado ni un stock ya contado. Completa marca y
  categoría si faltan, y actualiza el precio si el archivo lo trae.
- Importar dos veces el mismo archivo **no duplica** (se reconoce por `productos.codigo_anterior`).

Pruebas: `node scripts/test-importar-sql.mjs` (23).
