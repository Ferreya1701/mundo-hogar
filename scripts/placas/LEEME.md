# Placas del Drive → "Fotos para revisar"

Las placas de Canva (1080×1920: logo, título, foto, ficha, precio) se convierten en
fotos de producto con una sugerencia de a qué producto corresponden. Una persona
confirma cada una en `/admin/fotos-revisar` (sql/031). Nada se publica solo.

Requiere `tesseract` (con idioma español), ImageMagick y Python con numpy, pillow y scipy.

1. Bajar la carpeta del Drive como ZIP y descomprimirla. Correr todo desde esa carpeta,
   porque la huella (id) de cada foto sale de su ruta relativa.
2. `leer.py <placa> <salida>` → una línea JSON por placa con título, ficha y precio leídos (OCR).
   Juntar todas en `ocr.jsonl`.
3. `catalogo.json`: los productos (`id, nombre, sku, marca, categoria, estado, tiene_foto`).
4. `cruzar.py <carpeta>` → `cruce.json`: candidatos y nivel (seguro / probable / dudoso / sin_match).
   Puntaje: qué parte del título está en el nombre (pesando palabras raras), códigos de modelo
   (también parciales: "1010" ↔ "LC1010") y la marca de la ficha. Ignora la basura del OCR.
5. `recortar.py <salida> <placas...>` → la foto sola: borra el texto (cajas del OCR), el blanco y
   los colores de la plantilla, y se queda con el bloque grande que queda. Cuadrada, fondo blanco.
6. Armar el paquete (`filas.json`, `fotos/`, `placas/`) y cargarlo:
   `SUPABASE_SERVICE_ROLE_KEY=... node scripts/cargar-fotos-placas.mjs <paquete>`.

Resultado con las 279 placas de noviembre 2026: 267 recortes (12 sin producto detectable);
de una muestra de 25 "seguros", 22 correctos. Por eso siempre confirma una persona.
