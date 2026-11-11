# Guía: stock real, ventas en el local y compras

Qué resuelve: para vender online hace falta saber qué hay. Eso se logra con tres cosas que
ahora hace el sistema: (1) cada **venta en el local** descuenta stock al instante, (2) cada
**compra que llega** carga stock, y (3) un **conteo desde el celular** para poner al día lo
que ya está en el depósito. Como el catálogo nunca está 100 % contado, cada producto dice si su
stock está **controlado** o todavía **sin contar**.

| Producto | Venta en el local | Tienda online |
|---|---|---|
| **Sin contar** (nunca se contó ni llegó por compra) | Se vende igual, **no toca stock** | Muestra el precio y "**Consultar stock**" por WhatsApp. No se agrega al carrito |
| **Controlado** y hay | Descuenta al instante | "Agregar" (hasta el disponible) |
| **Controlado** y no hay | Se vende igual si el producto está en la mano; queda en **negativo** para revisar | "Sin stock" → consultar |

Disponible para la web = stock físico − unidades de pedidos web que están **esperando el pago**
por transferencia (así dos clientes no compran la misma última unidad). Al confirmar el pago se
descuenta de verdad; al vencer o cancelar, se libera.

---

## 1. Activar (una sola vez)

1. **Base de datos:** ejecutar `sql/013-local-compras-stock.sql` (idempotente; requiere 001..012).
   Con la CLI logueada (`npx supabase login`):
   `npx supabase db query --linked --project-ref zydotmaolgddwenwywyc -f sql/013-local-compras-stock.sql`
   o pegarlo en el SQL Editor del panel de Supabase. Probado con `node scripts/test-stock-sql.mjs`
   (109 pruebas con PGlite). Hasta que se ejecute, las páginas nuevas del panel avisan
   "falta ejecutar sql/013" y la tienda sigue funcionando como antes.
2. **Lectura de listas con IA (opcional):** desplegar la Edge Function `leer-lista-compra`
   igual que `leer-comprobante`:
   `npx supabase functions deploy leer-lista-compra --project-ref zydotmaolgddwenwywyc --no-verify-jwt --use-api`.
   Usa el mismo secreto `ANTHROPIC_API_KEY`. Sin la función o sin la clave, la carga de compras
   funciona igual pegando la planilla (la IA solo suma leer fotos/PDF y traducir nombres).
3. **Deploy de la web:** push a `main` (Cloudflare despliega solo). Páginas nuevas:
   `/admin/vender`, `/admin/ventas`, `/admin/compras`; `/admin/carga-stock` cambió a conteo.
4. **Cámara en el celular:** `_headers` ya permite la cámara en `/admin/*` (lector de códigos
   de barras). En iPhone hace falta Safari 17 o más; en Android, Chrome.

## 2. Contar stock (celular) — `/admin/carga-stock`

Para administrador y encargado de stock.

- Filtro **"Sin contar"** arranca activo: es la lista de lo que falta. Recorré el depósito y
  escribí **cuántas unidades hay** (el total, no lo que sumás). Botón "No hay (0)" para
  confirmar que no queda ninguno. Enter pasa al siguiente producto.
- 📷 **Escanear** lee el código de barras con la cámara y filtra el producto (o avisa que no
  existe). Con un lector USB: escaneá en el buscador y Enter.
- **"+ Producto que no está"**: alta rápida (nombre, categoría, código de barras, precio,
  cantidad contada). Nace oculto en la tienda hasta completarlo (foto, descripción).
- **Guardar conteo**: cada diferencia con el sistema queda asentada como movimiento
  (`carga_inicial` la primera vez, `correccion` después) con usuario, fecha y nota. El
  producto pasa a **controlado**. Un conteo igual al sistema no genera movimiento.
- Filtro **"En negativo"**: productos que el local vendió más de lo que el sistema conocía.
  Contarlos arregla el número.
- "Volver a sin contar" (en "más ▾"): deshace el control si se contó mal; la web deja de
  venderlo hasta volver a contarlo.

## 3. Crear venta (vender en el local) — `/admin/vender`

Para todo el staff (administrador, vendedor, encargado de stock).

1. Buscá por nombre, SKU o código de barras (lector USB: escaneá y listo; celular: 📷).
   Tocar un producto lo suma al ticket. Chips de categoría para navegar sin escribir.
2. En el ticket: cantidades con −/+, precio editable (✎), quitar, descuento en pesos, medio
   de pago (efectivo, transferencia, débito, crédito, Mercado Pago, cuenta corriente, otro),
   cliente opcional (nombre y teléfono para mandarle el ticket por WhatsApp), nota interna.
3. **Cobrar** → confirmación con el detalle → venta `VL-AAMMDD-XXXX`. Pantalla final con el
   ticket, "Imprimir ticket" (rollo de 80 mm, atajo `F8`), "Mandar por WhatsApp", "Copiar" y
   "Nueva venta". El ticket impreso es un comprobante interno, no una factura. El ticket sin cobrar se guarda en
   el navegador: si se recarga la página no se pierde.
- Productos **sin precio**: al tocarlos pide el precio. **Ítem fuera del catálogo** (abajo):
  nombre y precio, no toca stock.
- Productos con stock controlado se descuentan al cobrar (movimiento `salida_venta` con
  referencia `VL-…`). Si el sistema dice menos de lo que se vende, avisa y vende igual: el
  stock queda negativo para revisar (nunca frena la caja).
- Atajos de teclado: `/` o `F2` buscador, `F9` cobrar, `F8` imprimir la última venta. En celular el ticket es un panel
  deslizable abajo con el total.

## 4. Ventas — `/admin/ventas`

Rangos rápidos (hoy, ayer, semana, mes, fechas), filtros por medio de pago, vendedor y
estado, buscador por código/cliente/producto. KPIs: total cobrado, ticket promedio, unidades,
desglose por medio de pago. Detalle con los renglones y si descontaron stock, con "Imprimir
ticket". **Anular**:
repone el stock de los renglones que lo descontaron (`devolucion_cliente`). Un vendedor
anula solo sus ventas de las últimas 24 h; el administrador, cualquiera. Exportar CSV (un
renglón por producto).

## 5. Compras — `/admin/compras`

Para administrador y encargado de stock.

### Nueva compra
1. **La lista**: pegá las celdas de Excel/Sheets, o subí el archivo (`.xlsx`, `.csv`, `.txt`),
   o **Leer con IA** (foto, PDF o planilla desordenada en inglés/chino: saca los renglones y
   los traduce). Las columnas se detectan solas (descripción, cantidad, costo, código del
   proveedor, código de barras) y se pueden corregir. Listas simples también sirven
   ("Freidora 5L x 20").
2. **Revisar productos**: el sistema sugiere a qué producto corresponde cada renglón:
   100 % = SKU, código de barras o código del proveedor exacto; 95 % = mismo nombre;
   menos = nombre parecido. Verde: seguro. Amarillo: dudoso (confirmar). Azul: **producto
   nuevo** (se crea). También: buscar otro producto a mano u omitir el renglón. Datos de la
   compra: proveedor, referencia, moneda, tipo de cambio (para guardar el costo en pesos),
   fechas, categoría para los nuevos, **"ya llegó"** (carga el stock ahora) y "publicar nuevos"
   (por defecto nacen ocultos hasta completar foto y precio).
3. **Cargar la compra** → `OC-AAMMDD-XXXX`. Los productos nuevos aparecen con link para
   completarlos.

### Recibir
En la compra → **Recibir**: viene precargado lo que falta por renglón; se puede recibir parte
(queda "Llegó parte") y cerrar después. Columna **"Ya había"**: para productos que todavía no
estaban contados y de los que quedaban unidades viejas en el local; se suman como conteo. Todo
producto recibido queda con **stock controlado**, con su costo en pesos actualizado (si hay
tipo de cambio) y su código del proveedor guardado para que la próxima lista lo encuentre solo.
Cada entrada queda en Movimientos de stock con referencia `OC-…`. Desde el detalle de la compra,
**🏷️ Etiquetas** imprime códigos de barras para lo que llegó (ver sección 8).

Estados: pedido → en tránsito → llegó parte → recibido. Cancelar solo si no se recibió nada.

## 6. Cómo arrancar (orden sugerido)

1. Ejecutar `sql/013` y hacer el push.
2. En el local: **Vender** desde el primer día (no hace falta haber contado nada).
3. Ir contando por sector con el celular (Contar stock → "Sin contar"). Lo contado ya se vende
   online. Prender el carrito de la tienda (Configuración) cuando haya una base razonable.
4. Cada compra a China: cargar la lista al hacer el pedido; al llegar, "Recibir".
5. Revisar cada tanto Contar stock → "Sin contar", "En negativo" y "Sin stock".

## 7. Qué NO hace (todavía)

- No factura ni habla con ARCA (igual que los cobros).
- No hay caja por turno (apertura/cierre, arqueo): el resumen por día y medio de pago está en
  Ventas.
- No hay devolución parcial: se anula la venta completa y se vuelve a cobrar lo que queda.
- Un solo depósito. El borrador multi-depósito sigue en `sql/borradores-no-ejecutados/`.
- Los pedidos web que salen solo por WhatsApp (sin elegir pagar) no reservan stock.

## 8. Etiquetas con código de barras

Los productos que llegan de China suelen venir sin código propio. Para que la caja los escanee:

- **Productos** → 🏷️ en la fila, o seleccionar varios → "🏷️ Etiquetas".
- **Compras** → abrir la compra → "🏷️ Etiquetas": precarga la cantidad recibida de cada renglón.
- Se imprime el **código de barras** del producto si lo tiene; si no, el **SKU** (`MH-00123`). La caja
  reconoce los dos al escanear. Siempre en formato CODE128.
- Formatos: rollo de 50 × 30 mm (impresora de etiquetas) u hoja A4 de 24 etiquetas de 70 × 37 mm
  (3 × 8, papel autoadhesivo). Con o sin precio. Al imprimir, desactivar "ajustar a la página".
- Si no carga la librería de códigos (sin internet), la etiqueta sale igual con el código en texto.

## 9. Ajuste manual — `/admin/inventario`

Solo para lo que no pasa por Crear venta, Compras ni Contar stock: devolución de cliente, mercadería que
apareció, producto dañado, pérdida, devolución a proveedor, ajuste negativo. Para dejar un producto en
la cantidad real es más fácil contarlo.

## 10. Ticket de compra y recibo (sql/017, 2026-11-11)
Rollo de 80 mm. Encabezado de los dos, en este orden: **logo**, **nombre de la tienda**, CUIT,
domicilio, Ingresos Brutos, inicio de actividades y condición frente al IVA. Esos datos se editan en
**Configuración → Datos fiscales** (solo administrador); ahí también está "Imprimir ticket de prueba".
El 017 los carga con los datos del negocio (CUIT 20-35653078-1, Blas Parera 9961, IIBB 0116724067,
inicio 01/07/2015, Responsable Inscripto) solo si están vacíos.

- **Ticket de compra:** fecha y hora con segundos (hora de Argentina), número de venta, cliente (o
  "Consumidor final"), quién retira (si se cargó), quién atendió, productos con cantidad × precio,
  total y medio de pago.
- **Recibo:** para pagos (lo usan las cuentas corrientes): de quién, importe, forma de pago, saldo
  anterior y actual, y línea de firma.
- Los dos dicen al pie "Comprobante interno · no válido como factura".
- Se imprime cuando cargó el logo (o a los 2,5 s si no carga), así no sale sin logo.
- Código: `admin/js/impresion.js` (`MHImprimir.ticket`, `MHImprimir.recibo`). Pruebas:
  `node scripts/test-ticket.mjs` (también cubre el cierre de caja).

## 11. Caja diaria — `/admin/caja` (sql/018, 2026-11-11)
**Abrir:** se pone el efectivo que hay en el cajón (viene sugerido el fondo que dejó el último
cierre; si no coincide, pide una nota). **Cerrar:** se cuenta el efectivo; la pantalla muestra lo que
debería haber y la diferencia. Si no coincide hay que explicar qué pasó. Se elige cuánto queda de
fondo para mañana; el resto queda como "Retiro al cierre". Al cerrar se puede imprimir el cierre (80 mm).

- **Ventas:** entran solas. Efectivo suma al cajón; transferencia, débito, crédito, Mercado Pago y
  "otro" se ven aparte ("no están en el cajón"). **Cuenta corriente no entra** (entra cuando el
  cliente paga). Anular una venta saca la devolución por el mismo medio.
- **La caja nunca frena una venta.** Con la caja cerrada se vende igual (Crear venta avisa) y el
  cobro queda pendiente: se suma solo a la próxima apertura.
- **Ingresos y egresos:** botones "+ Ingreso" / "− Egreso" con concepto (compras menores, retiro del
  dueño, sueldos, servicios, fletes…). "Otros" exige detalle. Solo con la caja abierta.
- **Nada se borra ni se edita.** Un movimiento manual mal cargado se **anula** con motivo: queda
  tachado y aparece el inverso. Las ventas se anulan desde Ventas.
- **Cajas anteriores:** lista de cierres con esperado, contado, diferencia y retiro, y reimpresión.
- **Conceptos:** se agregan y se desactivan (no se borran); renombrar no cambia los movimientos viejos.

| Permiso (Admin → Permisos) | Vendedor | Encargado |
|---|---|---|
| Ver la caja del día | ✔ | ✔ |
| Abrir y cerrar la caja | ✔ | |
| Cargar ingresos y egresos | ✔ | |
| Anular movimientos de caja | | |
| Ver cajas anteriores | | |
| Editar conceptos de caja | | |

Por dentro: `caja_sesiones`, `caja_movimientos`, `caja_conceptos`. Las ventas llegan por el disparador
`tr_ventas_caja` → `fn_caja_sincronizar_venta`, que compara lo que la venta debería haber dejado en
caja con lo que dejó y asienta la diferencia (sirve para alta, anulación y la futura edición de
ventas). Funciones: `caja_abrir`, `caja_cerrar`, `caja_movimiento_registrar`,
`caja_movimiento_anular`, `caja_resumen`, `caja_esta_abierta`. Pruebas: `node scripts/test-caja-sql.mjs` (75).
