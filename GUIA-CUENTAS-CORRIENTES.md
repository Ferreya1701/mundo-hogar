# Cuentas corrientes (sql/019, 2026-11-11)

Clientes que compran a cuenta y pagan después. Pantalla: **Ventas → Cuentas corrientes**
(`/admin/cuentas-corrientes`).

## Puesta en marcha
1. Correr `sql/019-cuentas-corrientes.sql` en Supabase (después del 016, 017 y 018).
2. **Recargos:** Cuentas corrientes → "Recargos por categoría". Se pone cuánto se suma **por unidad**
   al vender en cuenta corriente (ej. Celulares $20.000).
3. **Abrir las cuentas** de los clientes que ya compran a cuenta ("+ Nueva cuenta": nombre, teléfono,
   DNI/CUIT, día de pago, límite). Si el teléfono ya está en Clientes (CRM) se usa esa ficha.
4. **Saldo de la libreta:** en cada cuenta, "± Ajuste" → "Suma deuda" con motivo "Saldo inicial".

## Cómo funciona
- **Un saldo por cliente.** Vender en cuenta corriente lo sube; los pagos lo bajan.
- **Día fijo de pago (1 a 28).** Lo comprado en un mes vence ese día del mes siguiente. Los pagos
  cancelan primero lo más viejo. "Vencido" = lo que ya pasó su vencimiento y no se pagó.
- **Límite de crédito** (opcional): la venta que lo supera se rechaza, salvo para quien tenga el
  permiso "Vender por encima del límite".
- **Suspender** una cuenta: no puede comprar, sí pagar.
- **Recargo por categoría:** lo suma la base de datos, no la vendedora. Si se cambia el precio a mano
  en el ticket, el recargo se suma igual. Se ve en el ticket ("Incluye recargo cuenta corriente").
  En efectivo, transferencia o tarjeta no se suma nada.

## Vender (Crear venta)
Medio de pago **Cuenta corriente** → buscar el cliente (nombre, teléfono o CUIT). Muestra cuánto debe,
lo vencido y cómo queda con esta compra; avisa si supera el límite o está suspendida. El campo
**"Retira"** (para todas las ventas) es quién se lleva la mercadería si no es el cliente.
El ticket de una venta en cuenta corriente trae saldo anterior, saldo nuevo, próximo vencimiento y
lugar para la firma del cliente. **No entra a la caja** (no es plata).

## Cobrar
En la cuenta del cliente → **Registrar pago**: monto (sugiere lo vencido o lo que vence), cómo pagó.
- Sale un **recibo numerado** (R-000001…) para imprimir, con saldo anterior y actual.
- El cobro **entra a la caja** con ese medio (con la caja cerrada queda pendiente, como una venta).
- Si paga de más, la diferencia queda **a favor** del cliente.
- "Recordatorio por WhatsApp" arma un mensaje con el saldo y el vencimiento.

## Corregir
- **Anular un pago** (rebotó, se cargó mal): vuelve la deuda y sale el egreso de la caja por el mismo
  medio. Con motivo.
- **Anular la venta** (desde Ventas): baja la deuda sola.
- **Ajustes** (suma o resta deuda, con motivo): saldos iniciales, bonificaciones, errores. No tocan la caja.
- Nada se borra ni se edita a mano: ni la base deja cambiar un saldo fuera de estas operaciones.

## Permisos (Admin → Permisos)
| Permiso | Vendedor | Encargado |
|---|---|---|
| Ver cuentas corrientes y saldos | ✔ | |
| Vender en cuenta corriente | ✔ | ✔ |
| Registrar pagos de clientes | ✔ | |
| Habilitar cuentas, límite y día de pago | | |
| Ajustes de saldo y anular pagos | | |
| Cambiar recargos por categoría | | |
| Vender por encima del límite | | |

## Por dentro
- `cc_cuentas` (1 por cliente del CRM, `saldo` guardado) y `cc_movimientos` (libro: cargo, pago,
  devolución, ajustes, pago anulado; cada fila guarda saldo anterior y posterior y la base verifica
  que cuadre). `fn_cc_asentar` es el único lugar que cambia un saldo.
- `categorias.recargo_cc`; `ventas.cc_cuenta_id`, `retira_nombre`, `recargo_total`;
  `venta_items.recargo_unitario`.
- `venta_registrar` se reemplaza (mismo comportamiento + cuenta corriente + retira). La deuda la
  asienta el disparador `tr_ventas_cc` (alta, anulación y la futura edición de ventas), igual que la caja.
- Vencimientos: `fn_cc_estado(cuenta)`; lista: vista `v_cc_cuentas`; búsqueda: `cc_buscar(q)`.
- Pruebas: `node scripts/test-cc-sql.mjs` (64) y `node scripts/test-ticket.mjs`.
