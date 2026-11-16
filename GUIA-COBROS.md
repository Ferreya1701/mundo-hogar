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
   terminal): `npx supabase db query --linked --project-ref vduinkzeneokkqzdgxig -f sql/012-cobros.sql`.
   O pegarlo en el SQL Editor del panel de Supabase.
2. **Lectura automática (opcional pero recomendada):** desplegar la Edge Function
   `leer-comprobante` igual que `asistente` (ver `GUIA-ASISTENTE-IA.md`): Edge Functions → Deploy a
   new function → nombre exacto `leer-comprobante` → pegar `supabase/functions/leer-comprobante/index.ts`.
   Con la CLI: `npx supabase functions deploy leer-comprobante --project-ref vduinkzeneokkqzdgxig --no-verify-jwt --use-api`
   (ya desplegada). Necesita el secreto `ANTHROPIC_API_KEY` (hoy el proyecto NO lo tiene):
   `npx supabase secrets set ANTHROPIC_API_KEY=sk-ant-... --project-ref vduinkzeneokkqzdgxig`.
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

## 7. Las cuentas bancarias en la caja del local (sql/025, 2026-11-12)
En **Crear venta**, al cobrar por **Transferencia** o **Mercado Pago**, la cuenta ya no se elige de una
lista: la **asigna el sistema con el mismo reparto que el carrito de la web** (punto 3): la que tiene
cupo diario y mensual para ese monto y viene más descansada según su peso; si ninguna tiene cupo, la
de respaldo. La web y la caja comparten los cupos.

Cómo se usa:
1. Se arma el ticket y se elige Transferencia (o Mercado Pago). Aparece **"El cliente transfiere $X a
   ALIAS"**, con titular, banco y botón Copiar.
2. El cliente transfiere y muestra el comprobante. Se controla que sea a **esa** cuenta y por ese monto.
   Opcional: anotar el N° de operación.
3. Cobrar. La venta queda asentada como cobro de esa cuenta.

Para prevenir problemas:
- **Reserva:** al mostrar la cuenta, el monto queda reservado 15 minutos. Dos cajas (o la caja y un
  pedido web) no reciben al mismo tiempo la misma cuenta "casi llena".
- **Si cambia el total** del ticket, la cuenta se vuelve a pedir sola (puede cambiar). No deja cobrar
  con una cuenta pedida para otro monto.
- **"Otra cuenta":** si el cliente no puede transferir a la asignada, se pide otra con cupo.
- **Sin cupo en ninguna** y sin respaldo: lo avisa antes de que el cliente transfiera.
- **La caja nunca frena:** si la plata ya fue a una cuenta, la venta se registra en esa cuenta aunque
  pase el límite, y avisa para que el administrador lo vea.
- **Anular la venta o quitarle productos devuelve el cupo** (movimiento de anulación en la misma cuenta).
- **Cierre de caja:** la pantalla Caja muestra cuánto entró a cada cuenta en el día, para controlarlo
  contra el homebanking.
- La vendedora ve alias/CBU, titular y banco; **no** ve CUIT, límites ni cuánto lleva cada cuenta.
- Las ventas del local cuentan en el resumen de Cuentas bancarias y en la **liquidación del mes**, igual
  que los pedidos web pagados (hoy la comisión está en 0%).
- Sin ninguna cuenta activa cargada, todo sigue como antes (transferencia sin cuenta).

Pruebas: `node scripts/test-caja-cuentas-sql.mjs` (34).

## 8. Verificación con el aviso del banco (sql/032, 2026-11-16)

Un comprobante es una captura y se puede editar. La prueba de que la plata entró es el mail que el
banco o Mercado Pago le manda a quien **recibe** ("Recibiste una transferencia de $X"). Sin pasarela
y sin comisión: cada titular reenvía esos mails a la dirección secreta de su cuenta y el sistema los
empareja con el pedido por **cuenta + importe** (los centavos son únicos por cuenta, punto 2).

### Cómo decide
| Situación | Qué pasa |
|---|---|
| Comprobante coincide **y** llega el aviso por el mismo importe (en cualquier orden) | Pago confirmado solo, por lo que entró de verdad |
| Comprobante coincide y en **7 min** no llegó el aviso | Alerta en el panel y por mail para revisar a mano. Sigue esperando: si el aviso llega después, se confirma solo y la alerta se cierra |
| Diferencia de hasta **$50** (configurable) | Se acepta y queda anotada ("pagó $2 menos"). Más que eso: no coincide |
| Comprobante que no coincide, ilegible o sin leer | Alerta para revisar ya (sin leer: a los 7 min) |
| Mismo archivo de comprobante en otro pedido / hora anterior a habilitar el pago | No coincide |
| La IA ve señales de edición | Queda anotado (solo en el panel) y no confirma sin aviso |
| Entró plata y no hay pedido que coincida (30 min) | Alerta "entraron $X sin pedido": asignarla o descartarla en Cuentas bancarias → Avisos del banco. Las transferencias de la caja del local se reconocen solas |
| Una cuenta que mandaba avisos deja de mandarlos (2 pedidos sin aviso en 24 h) | Alerta "el reenvío de X parece caído" |
| Aviso de un remitente que no es un banco conocido | Se guarda pero **nunca** confirma solo (podría ser un mail trucho) |

Todo se configura en **Cuentas bancarias → Avisos del banco**: confirmar solo sí/no, minutos de espera,
tolerancia y mail de alertas. Ahí está también la dirección de cada cuenta, su estado (✅ verificando /
⏳ falta confirmar Gmail / ⚪ sin configurar), el código de confirmación que manda Gmail y el instructivo.

### Activar (una sola vez)
1. **Base:** ejecutar `sql/032-avisos-banco.sql` (idempotente; requiere 001..031). Ya ejecutado en producción (2026-11-16).
2. **Clave compartida:** generar una (`openssl rand -hex 24`) y cargarla en los dos lados:
   - Supabase: `npx supabase secrets set AVISOS_CLAVE=<clave> --project-ref vduinkzeneokkqzdgxig`
   - Cloudflare: Workers → mundo-hogar → Settings → Variables and Secrets → Add → Secret `AVISOS_CLAVE`.
   Recomendado también `ANTHROPIC_API_KEY` en Supabase (sin ella los avisos se leen con reglas simples).
3. **Edge Functions:** `npx supabase functions deploy avisos-banco --project-ref vduinkzeneokkqzdgxig --no-verify-jwt --use-api`
   y volver a desplegar `leer-comprobante` (ahora manda la huella del archivo y las señales de edición).
4. **Recepción de mails (Cloudflare → Email → Email Routing):** se activa en el dominio principal
   `mundohogarstf.com` (2026-11-16: el dueño confirmó que nadie usa casillas @mundohogarstf.com, así que
   se reemplazaron los MX de GoDaddy por los de Cloudflare). Regla *Catch-all* → **Send to a Worker** →
   `mundo-hogar`. El Worker solo acepta `c-<token>@mundohogarstf.com` y rechaza el resto. Si algún día
   se quiere una casilla real (ej. `ventas@`), se agrega una regla propia antes del catch-all.
5. **Mails de alerta:** en Email Routing → *Destination addresses* agregar y verificar el mail del dueño;
   después sumar a `wrangler.jsonc` `"send_email": [{ "name": "MAIL_ALERTAS" }]` (push) y cargar ese mail
   en el panel. Sin esto, las alertas salen solo en el panel.
6. **Cada titular** sigue los 5 pasos del panel (activar avisos en el banco, reenvío en Gmail, código,
   filtro). Unos 5 minutos por persona.

### Piezas
- `worker/index.js`: `email()` recibe en `c-<token>@mundohogarstf.com`; `scheduled()` cada minuto
  (cron en `wrangler.jsonc`) pide la revisión y manda los mails.
- `supabase/functions/avisos-banco`: arma el mail, la IA saca monto / ordenante / nº de operación,
  detecta la confirmación de Gmail. La base decide (`aviso_registrar`, `fn_aviso_emparejar`,
  `fn_cobros_conciliar`, `cobros_revisar`).
- Panel: recuadro de alertas abajo a la derecha en cualquier módulo (`admin/js/alertas-cobros.js`, cada
  minuto; opcional notificación del sistema), estado del aviso en el detalle del pedido.

Pruebas: `node scripts/test-avisos-banco-sql.mjs` (63).
