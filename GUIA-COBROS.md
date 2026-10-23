# Guía: cobros por transferencia (gestor de ventas y cobros)

Qué hace: el cliente arma el pedido en la tienda, la web le asigna una cuenta (alias/CVU) y un
monto exacto con centavos, transfiere desde su banco o Mercado Pago, sube el comprobante en
`/pedido/<código>`, la IA lo lee, y desde el panel se confirma el pago (el pedido pasa a
"confirmado" y descuenta stock). Todo queda registrado cuenta por cuenta para la liquidación
mensual con el porcentaje de comisión.

**No factura ni se conecta con ARCA.** Es un registro interno de ventas y cobros.

> ⚠️ Las cuentas deben ser del negocio o de personas que facturen al negocio por lo que reciben.
> Repartir ingresos entre cuentas de terceros para quedar por debajo de umbrales de información es
> fraccionamiento: trae bloqueos de Mercado Pago y problemas fiscales. El reparto automático de
> este sistema es operativo (límites por cuenta, redundancia), y cada cobro queda atado a su pedido.

---

## 1. Activar (una sola vez)

1. **Base de datos:** ejecutar `sql/012-cobros.sql` (idempotente; requiere 001..011). Ya está
   ejecutado en producción (2026-10-23). Con la CLI logueada (`npx supabase login` en una
   terminal): `npx supabase db query --linked --project-ref zydotmaolgddwenwywyc -f sql/012-cobros.sql`.
   O pegarlo en el SQL Editor del panel de Supabase.
2. **Lectura automática (opcional pero recomendada):** desplegar la Edge Function
   `leer-comprobante` igual que `asistente` (ver `GUIA-ASISTENTE-IA.md`): Edge Functions → Deploy a
   new function → nombre exacto `leer-comprobante` → pegar `supabase/functions/leer-comprobante/index.ts`.
   Con la CLI: `npx supabase functions deploy leer-comprobante --project-ref zydotmaolgddwenwywyc --no-verify-jwt --use-api`
   (ya desplegada). Necesita el secreto `ANTHROPIC_API_KEY` (hoy el proyecto NO lo tiene):
   `npx supabase secrets set ANTHROPIC_API_KEY=sk-ant-... --project-ref zydotmaolgddwenwywyc`.
   Sin la clave, los comprobantes se suben igual y quedan "ilegible / revisar a mano".
3. **Panel → Cuentas de cobro → + Nueva cuenta:** nombre interno, titular, alias y/o CBU/CVU,
   CUIT/CUIL, peso, límites diario y mensual (opcionales).
4. **Panel → Cuentas de cobro → Configuración:** prender "Cobros activos en la tienda", plazo para
   pagar (horas), porcentaje de comisión, instrucciones para el cliente.
5. **Deploy de la web:** push a `main` (Cloudflare despliega solo). Rutas nuevas: `/pedido`,
   `/pedido/<código>`, `/admin/pedidos`, `/admin/cuentas-cobro`.

## 2. Cómo funciona día a día

### Para el cliente
1. Carrito → "Enviar pedido por WhatsApp" (igual que antes). Si el pedido tiene total y los cobros
   están activos, ve además "Pagar por transferencia".
2. En `/pedido/<código>` ve alias, CBU/CVU, titular y el **monto exacto con centavos**. Los
   centavos son únicos entre los pedidos pendientes de esa cuenta: por eso se reconoce la
   transferencia por el importe.
3. Sube la foto o PDF del comprobante (hasta 10 MB, máximo 5 por pedido). Ve el estado:
   recibido → leído (coincide / revisión) → aceptado o rechazado (con el motivo).
4. Para volver a entrar necesita código + teléfono del pedido (el navegador los recuerda).

### Para el panel (Pedidos y cobros)
- Chip **"Para revisar"**: pedidos con comprobante que esperan una decisión. Es lo que se mira
  todos los días.
- En el detalle: lo que leyó la IA (monto, fecha, destino, origen, nº de operación, confianza) al
  lado de la imagen, y el motivo si no coincide (monto distinto, cuenta distinta, fecha anterior,
  nº de operación ya usado en otro pedido).
- **Confirmar pago con este comprobante**: registra el movimiento en la cuenta, marca el pedido
  pagado y lo pasa a "confirmado" (descuenta stock). Si no hay stock, nada se guarda y el panel
  muestra qué falta: ajustar stock en Inventario y volver a confirmar.
- **Rechazar**: pide un motivo que el cliente ve en su página; el pedido vuelve a "esperando pago".
- **Registrar pago a mano**: efectivo u otro medio, indicando cuenta y monto.
- **Habilitar pago**: para cotizaciones (productos sin precio) se indica el monto final y el
  cliente recibe los datos para pagar (plantilla de WhatsApp "Datos para pagar").
- **Anular pago** (solo administrador): deja un movimiento de anulación; el pedido queda
  "esperando pago" y conserva su estado (cancelarlo es otra decisión).
- Pagos pendientes sin comprobante pasados del plazo quedan **vencidos**; el cliente puede volver a
  habilitar el pago (se reasigna cuenta y monto).

### Cuentas de cobro (solo administrador)
- Por cuenta: cobrado hoy, mes, pendiente asignado, pedidos pendientes, último cobro, barra contra
  el límite. Pausar una cuenta la saca del reparto sin borrar nada.
- **Movimientos**: libro inmutable (cobros y anulaciones) por cuenta y mes, con pedido, cliente,
  nº de operación y usuario. Exportable a CSV para conciliar con el extracto.
- **Liquidaciones**: cerrar un mes congela el total por cuenta y la comisión. No se puede cerrar
  dos veces ni el mes en curso.

## 3. Reparto automático entre cuentas

Cada pedido va a la cuenta **activa** que menos acumuló en el mes dividido por su **peso**
(1 a 10), entre las que no superan su límite diario ni mensual contando lo ya cobrado más lo
asignado y pendiente. Si ninguna puede, toma el pedido la cuenta marcada como **respaldo** (sin
mirar límites); si no hay, la web pide coordinar por WhatsApp. La cuenta asignada a un pedido no
cambia después de mostrársela al cliente.

## 4. Confirmación automática (opcional)

En Configuración, "Confirmar solo cuando el comprobante coincide": si la IA lee monto, cuenta y
fecha correctos con confianza ≥ 80, el pedido pasa a pagado y confirmado sin intervención. Está
apagado por defecto porque un comprobante editado puede engañar a la lectura; activarlo solo si
alguien concilia después contra los ingresos reales de cada cuenta. La verificación por API de
Mercado Pago (cruzar ingresos reales) queda como mejora futura.

## 5. Seguridad

- El público no lee ninguna tabla: entra por RPC con código + teléfono (misma clave de teléfono que
  el CRM: +54 9 / 0 / 15 escritos distinto dan lo mismo).
- El bucket `comprobantes` es privado: el público solo sube a la carpeta de su código; el panel ve
  con URLs firmadas de 15 minutos; solo administrador borra.
- Los movimientos de cobro solo se escriben por RPC; el estado del pedido sigue cambiando solo por
  `cambiar_estado_solicitud` (sql/007), que el 012 vuelve a definir con la vía interna habilitada.
- La lectura la decide la base (`comprobante_registrar_lectura`), no la IA: la función solo
  extrae datos. Solo la Edge Function (clave de servicio) puede registrar lecturas.

## 6. Pruebas

```bash
npm i --no-save --prefix scripts @electric-sql/pglite   # una vez
node scripts/test-cobros-sql.mjs                         # 68 pruebas sobre Postgres en memoria
```
