-- ============================================================
-- 028 — PEDIDOS WEB EN EL MISMO CIRCUITO (etapa C, 2026-11-12)
-- Ejecutar DESPUÉS del 027. Idempotente.
--
-- Un pedido web (solicitud) se "pasa al mostrador": se convierte en una
-- venta común y desde ahí sigue el mismo camino que las del local:
--   • Si ya pagó online (transferencia confirmada en Pedidos): la venta
--     queda pagada con el medio "web" (no entra a la caja ni vuelve a
--     sumar en la cuenta bancaria: esa plata ya se registró en Pedidos).
--   • Si no pagó: la venta espera cobro y se cobra en la Caja cuando el
--     cliente viene a retirar (efectivo, tarjeta, mixto…).
--   • La entrega (retiro / envío) sale del pedido y aparece en Entregas.
--   • Si después el cliente paga online, la venta se marca pagada sola;
--     si se anula ese pago, vuelve a esperar cobro (si no salió).
--   • Entregada la venta → el pedido queda "entregado". Anulada la
--     venta → el pedido vuelve a quedar sin venta (se puede volver a pasar
--     o cancelar).
-- Stock: lo descuenta la venta (con las reglas del local). Si el pedido
-- ya lo había descontado al confirmarse, primero se repone, así no se
-- descuenta dos veces.
-- ============================================================

-- ──────────────────────────────────────────────
-- 1) Columnas y medio "web"
-- ──────────────────────────────────────────────
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS origen TEXT NOT NULL DEFAULT 'local';
ALTER TABLE ventas DROP CONSTRAINT IF EXISTS ventas_origen_check;
ALTER TABLE ventas ADD CONSTRAINT ventas_origen_check CHECK (origen IN ('local', 'web'));
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS solicitud_id BIGINT REFERENCES solicitudes(id) ON DELETE SET NULL;
-- Un pedido tiene a lo sumo una venta viva (las anuladas quedan de historia)
CREATE UNIQUE INDEX IF NOT EXISTS uq_ventas_solicitud_viva ON ventas (solicitud_id)
  WHERE solicitud_id IS NOT NULL AND estado <> 'anulada';

ALTER TABLE solicitudes ADD COLUMN IF NOT EXISTS venta_id BIGINT REFERENCES ventas(id) ON DELETE SET NULL;

ALTER TABLE ventas DROP CONSTRAINT IF EXISTS ventas_medio_pago_check;
ALTER TABLE ventas ADD CONSTRAINT ventas_medio_pago_check
  CHECK (medio_pago IN ('efectivo','transferencia','debito','credito','mercadopago','cuenta_corriente','otro','pendiente','mixto','web'));
ALTER TABLE venta_pagos DROP CONSTRAINT IF EXISTS venta_pagos_medio_pago_check;
ALTER TABLE venta_pagos ADD CONSTRAINT venta_pagos_medio_pago_check
  CHECK (medio_pago IN ('efectivo','transferencia','debito','credito','mercadopago','otro','web'));


-- ──────────────────────────────────────────────
-- 2) La caja no asienta lo pagado online (la cuenta bancaria ya filtra por medio)
-- ──────────────────────────────────────────────
DO $patch$
DECLARE d TEXT;
BEGIN
  d := pg_get_functiondef('fn_caja_sincronizar_venta(bigint)'::regprocedure);
  IF position('028: lo pagado online' IN d) = 0 THEN
    IF position('FROM fn_venta_pagado(p_venta_id) p' || chr(10) IN d) = 0 THEN
      RAISE EXCEPTION '028: fn_caja_sincronizar_venta no tiene el texto esperado';
    END IF;
    d := replace(d, 'FROM fn_venta_pagado(p_venta_id) p' || chr(10),
                    'FROM fn_venta_pagado(p_venta_id) p WHERE p.medio <> ''web''  -- 028: lo pagado online no es plata de la caja' || chr(10));
    EXECUTE d;
  END IF;
END
$patch$;


-- ──────────────────────────────────────────────
-- 3) Lo comprometido por pedidos web: no cuenta lo que ya pasó a venta
--    (la venta ya descontó el stock)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION stock_comprometido(p productos)
RETURNS INT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(sum(i.cantidad), 0)::int
    FROM solicitud_items i
    JOIN solicitudes s ON s.id = i.solicitud_id
   WHERE i.producto_id = p.id
     AND NOT s.stock_descontado
     AND s.venta_id IS NULL
     AND s.estado NOT IN ('cancelado','entregado')
     AND s.estado_pago IN ('pendiente','comprobante_recibido','en_revision')
     AND (s.estado_pago <> 'pendiente' OR s.pago_vence_en IS NULL OR s.pago_vence_en > now())
$$;
GRANT EXECUTE ON FUNCTION stock_comprometido(productos) TO anon, authenticated;


-- ──────────────────────────────────────────────
-- 4) Marcar / desmarcar una venta como pagada online
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_venta_pago_web(p_venta_id BIGINT, p_pagada BOOLEAN)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v   ventas%ROWTYPE;
  s   solicitudes%ROWTYPE;
BEGIN
  SELECT * INTO v FROM ventas WHERE id = p_venta_id FOR UPDATE;
  IF NOT FOUND OR v.estado = 'anulada' THEN RETURN false; END IF;

  IF p_pagada THEN
    IF v.estado <> 'pendiente_cobro' THEN RETURN false; END IF;
    SELECT * INTO s FROM solicitudes WHERE id = v.solicitud_id;
    IF NOT FOUND OR s.estado_pago <> 'pagado' OR coalesce(s.monto_pagado, 0) < v.total - 1 THEN RETURN false; END IF;
    DELETE FROM venta_pagos WHERE venta_id = v.id;
    INSERT INTO venta_pagos (venta_id, medio_pago, monto, monto_original, cuenta_cobro_id, orden)
    VALUES (v.id, 'web', v.total, greatest(v.total, 0.01), s.cuenta_cobro_id, 1);
    UPDATE ventas SET estado = 'cerrada', medio_pago = 'web', cuenta_cobro_id = NULL,
                      cobrada_en = coalesce(s.pagado_en, now()), cobrada_por = NULL,
                      cobrada_por_nombre = 'Pago online'
     WHERE id = v.id;
    RETURN true;
  ELSE
    IF v.estado <> 'cerrada' OR v.medio_pago <> 'web' THEN RETURN false; END IF;
    IF v.entrega_estado = 'entregado' THEN
      RAISE EXCEPTION 'venta_entregada'
        USING HINT = format('La mercadería de la venta %s ya salió. Anulá la venta o cobrá la diferencia antes de anular el pago.', v.codigo);
    END IF;
    DELETE FROM venta_pagos WHERE venta_id = v.id;
    UPDATE ventas SET estado = 'pendiente_cobro', medio_pago = 'pendiente', cobrada_en = NULL,
                      cobrada_por = NULL, cobrada_por_nombre = NULL
     WHERE id = v.id;
    RETURN true;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION fn_venta_pago_web(BIGINT, BOOLEAN) FROM PUBLIC, anon, authenticated;


-- ──────────────────────────────────────────────
-- 5) Pasar un pedido web al mostrador
--    p_o: { items: [{id, precio}], entrega: {...como en Crear venta}, notas }
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pedido_a_venta(p_solicitud_id BIGINT, p_o JSONB DEFAULT '{}'::jsonb)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  s        solicitudes%ROWTYPE;
  r        RECORD;
  v_items  JSONB := '[]'::jsonb;
  v_falta  TEXT[] := '{}';
  v_precio NUMERIC;
  v_ent    JSONB;
  v_res    JSONB;
  v_id     BIGINT;
  v_total  NUMERIC;
  v_pagada BOOLEAN := false;
  v_prev   TEXT := current_setting('mh.interno', true);
BEGIN
  IF NOT fn_tiene_permiso('pedidos.gestionar') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede gestionar pedidos web.';
  END IF;
  IF NOT fn_tiene_permiso('ventas.crear') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede registrar ventas.';
  END IF;
  SELECT * INTO s FROM solicitudes WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'pedido_no_encontrado'; END IF;
  IF s.venta_id IS NOT NULL THEN
    RAISE EXCEPTION 'pedido_ya_en_venta'
      USING HINT = format('Este pedido ya es la venta %s.', (SELECT codigo FROM ventas WHERE id = s.venta_id));
  END IF;
  IF s.estado IN ('cancelado', 'entregado') THEN
    RAISE EXCEPTION 'pedido_cerrado' USING HINT = 'El pedido está cancelado o ya se entregó.';
  END IF;

  -- Ítems con su precio (el del pedido, o el corregido en el panel)
  FOR r IN SELECT i.* FROM solicitud_items i WHERE i.solicitud_id = s.id ORDER BY i.id LOOP
    v_precio := NULL;
    BEGIN
      SELECT nullif(x->>'precio', '')::numeric INTO v_precio
        FROM jsonb_array_elements(coalesce(p_o->'items', '[]'::jsonb)) x
       WHERE (x->>'id')::bigint = r.id LIMIT 1;
    EXCEPTION WHEN OTHERS THEN v_precio := NULL;
    END;
    v_precio := coalesce(v_precio, r.precio_unitario);
    IF v_precio IS NULL OR v_precio < 0 THEN v_falta := v_falta || r.nombre; CONTINUE; END IF;
    v_items := v_items || jsonb_build_object('producto_id', r.producto_id, 'nombre', r.nombre,
                                             'cantidad', r.cantidad, 'precio_unitario', v_precio);
  END LOOP;
  IF array_length(v_falta, 1) > 0 THEN
    RAISE EXCEPTION 'precio_requerido'
      USING HINT = 'Falta el precio de: ' || array_to_string(v_falta, ', ') || '.';
  END IF;
  IF jsonb_array_length(v_items) = 0 THEN RAISE EXCEPTION 'venta_vacia' USING HINT = 'El pedido no tiene productos.'; END IF;

  -- Si el pedido ya había descontado stock (al confirmarse), se repone: lo descuenta la venta
  IF s.stock_descontado THEN
    PERFORM set_config('mh.interno', '1', true);
    FOR r IN SELECT i.producto_id, i.cantidad FROM solicitud_items i JOIN productos p ON p.id = i.producto_id
              WHERE i.solicitud_id = s.id AND p.seguimiento_inventario LOOP
      PERFORM fn_registrar_movimiento(r.producto_id, 'devolucion_cliente', r.cantidad,
                                      'Pedido web pasa a venta', NULL, s.codigo, false);
    END LOOP;
    UPDATE solicitudes SET stock_descontado = false WHERE id = s.id;
    PERFORM set_config('mh.interno', coalesce(v_prev, ''), true);
  END IF;

  -- Entrega: la del panel, o la del pedido
  v_ent := coalesce(p_o->'entrega', CASE WHEN s.tipo_entrega = 'envio'
    THEN jsonb_build_object('tipo', 'envio', 'direccion', s.direccion, 'localidad', s.localidad,
                            'destinatario', s.cliente_nombre, 'telefono', s.telefono)
    ELSE jsonb_build_object('tipo', 'retiro') END);

  v_res := venta_registrar(jsonb_build_object(
    'items', v_items, 'cliente_nombre', s.cliente_nombre, 'cliente_telefono', s.telefono,
    'notas', left(concat_ws(' · ', 'Pedido web ' || s.codigo, nullif(btrim(coalesce(p_o->>'notas', '')), ''),
                            nullif(btrim(coalesce(s.observaciones, '')), '')), 400),
    'entrega', v_ent));
  v_id := (v_res->>'id')::bigint;

  UPDATE ventas SET origen = 'web', solicitud_id = s.id WHERE id = v_id RETURNING total INTO v_total;

  PERFORM set_config('mh.interno', '1', true);
  UPDATE solicitudes SET venta_id = v_id,
         estado = CASE WHEN estado IN ('nueva','contactado','cotizacion_enviada') THEN 'confirmado' ELSE estado END,
         atendido_por = coalesce(atendido_por, auth.uid())
   WHERE id = s.id;
  PERFORM set_config('mh.interno', coalesce(v_prev, ''), true);

  IF s.estado_pago = 'pagado' THEN
    IF coalesce(s.monto_pagado, 0) < v_total - 1 THEN
      RAISE EXCEPTION 'pago_web_incompleto'
        USING HINT = format('El cliente pagó %s online y la venta suma %s. Corregí los precios o anulá el pago en Pedidos.',
                            to_char(s.monto_pagado, 'FM999G999G999'), to_char(v_total, 'FM999G999G999'));
    END IF;
    v_pagada := fn_venta_pago_web(v_id, true);
  END IF;

  INSERT INTO solicitud_eventos (solicitud_id, estado_anterior, estado_nuevo, detalle, usuario_id)
  VALUES (s.id, s.estado, (SELECT estado FROM solicitudes WHERE id = s.id),
          format('Pasó al mostrador: venta %s%s', v_res->>'codigo', CASE WHEN v_pagada THEN ' (ya pagada online)' ELSE ' (se cobra en la caja)' END),
          auth.uid());

  RETURN v_res || jsonb_build_object('estado', CASE WHEN v_pagada THEN 'cerrada' ELSE 'pendiente_cobro' END,
                                     'medio_pago', CASE WHEN v_pagada THEN 'web' ELSE v_res->>'medio_pago' END,
                                     'pagada_online', v_pagada, 'solicitud_codigo', s.codigo);
END;
$$;
REVOKE ALL ON FUNCTION pedido_a_venta(BIGINT, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION pedido_a_venta(BIGINT, JSONB) TO authenticated;


-- ──────────────────────────────────────────────
-- 6) Pedido ↔ venta se mantienen al día
-- ──────────────────────────────────────────────
-- 6a) Cambia el pago online del pedido → la venta lo acompaña
CREATE OR REPLACE FUNCTION fn_tr_solicitud_pago_a_venta()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.venta_id IS NULL OR NEW.estado_pago IS NOT DISTINCT FROM OLD.estado_pago THEN RETURN NEW; END IF;
  IF NEW.estado_pago = 'pagado' THEN
    IF NOT fn_venta_pago_web(NEW.venta_id, true) THEN
      INSERT INTO solicitud_eventos (solicitud_id, estado_anterior, estado_nuevo, detalle, usuario_id)
      VALUES (NEW.id, NEW.estado, NEW.estado,
              'Pago online confirmado, pero la venta no quedó pagada sola (ya estaba cobrada o el monto no alcanza): revisar en Ventas',
              auth.uid());
    END IF;
  ELSIF OLD.estado_pago = 'pagado' THEN
    PERFORM fn_venta_pago_web(NEW.venta_id, false);
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION fn_tr_solicitud_pago_a_venta() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS tr_solicitud_pago_a_venta ON solicitudes;
CREATE TRIGGER tr_solicitud_pago_a_venta AFTER UPDATE OF estado_pago ON solicitudes
  FOR EACH ROW EXECUTE FUNCTION fn_tr_solicitud_pago_a_venta();

-- 6b) La venta se entrega / se deshace / se anula → el pedido lo acompaña
CREATE OR REPLACE FUNCTION fn_tr_venta_a_solicitud()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prev TEXT := current_setting('mh.interno', true);
  v_est  TEXT;
  v_det  TEXT;
BEGIN
  IF NEW.solicitud_id IS NULL THEN RETURN NEW; END IF;
  SELECT estado INTO v_est FROM solicitudes WHERE id = NEW.solicitud_id AND venta_id = NEW.id;
  IF NOT FOUND THEN RETURN NEW; END IF;
  PERFORM set_config('mh.interno', '1', true);

  IF NEW.estado = 'anulada' AND OLD.estado <> 'anulada' THEN
    UPDATE solicitudes SET venta_id = NULL,
           estado = CASE WHEN estado = 'entregado' THEN 'confirmado' ELSE estado END
     WHERE id = NEW.solicitud_id;
    v_det := format('Venta %s anulada: el pedido quedó sin venta (se puede volver a pasar o cancelar)', NEW.codigo);
  ELSIF NEW.entrega_estado = 'entregado' AND OLD.entrega_estado IS DISTINCT FROM 'entregado' THEN
    UPDATE solicitudes SET estado = 'entregado' WHERE id = NEW.solicitud_id;
    v_det := format('Entregado (venta %s)', NEW.codigo);
  ELSIF OLD.entrega_estado = 'entregado' AND NEW.entrega_estado IS DISTINCT FROM 'entregado' AND v_est = 'entregado' THEN
    UPDATE solicitudes SET estado = 'confirmado' WHERE id = NEW.solicitud_id;
    v_det := format('Se deshizo la entrega (venta %s)', NEW.codigo);
  END IF;

  IF v_det IS NOT NULL THEN
    INSERT INTO solicitud_eventos (solicitud_id, estado_anterior, estado_nuevo, detalle, usuario_id)
    VALUES (NEW.solicitud_id, v_est, (SELECT estado FROM solicitudes WHERE id = NEW.solicitud_id), v_det, auth.uid());
  END IF;
  PERFORM set_config('mh.interno', coalesce(v_prev, ''), true);
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION fn_tr_venta_a_solicitud() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS tr_venta_a_solicitud ON ventas;
CREATE TRIGGER tr_venta_a_solicitud AFTER UPDATE OF estado, entrega_estado ON ventas
  FOR EACH ROW EXECUTE FUNCTION fn_tr_venta_a_solicitud();

-- 6c) Un pedido que ya es venta no se cancela ni se entrega desde Pedidos
DO $patch$
DECLARE d TEXT; a TEXT;
BEGIN
  d := pg_get_functiondef('cambiar_estado_solicitud(bigint,text)'::regprocedure);
  IF position('028: pedido en venta' IN d) = 0 THEN
    a := 'RAISE EXCEPTION ''solicitud_no_encontrada'';' || chr(10) || '  END IF;';
    IF position(a IN d) = 0 THEN RAISE EXCEPTION '028: cambiar_estado_solicitud no tiene el texto esperado'; END IF;
    d := replace(d, a, a || $x$

  -- 028: pedido en venta → se maneja desde la venta (Caja / Entregas / Ventas)
  IF v_sol.venta_id IS NOT NULL AND NOT v_interno AND p_nuevo_estado NOT IN ('en_preparacion') THEN
    RAISE EXCEPTION 'pedido_en_venta'
      USING HINT = format('Este pedido ya es la venta %s: se entrega desde Entregas y se cancela anulando la venta.',
                          (SELECT codigo FROM ventas WHERE id = v_sol.venta_id));
  END IF;$x$);
    EXECUTE d;
  END IF;
END
$patch$;


-- ──────────────────────────────────────────────
-- 7) Índices
-- ──────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_ventas_origen_pend ON ventas (fecha) WHERE origen = 'web' AND estado = 'pendiente_cobro';

NOTIFY pgrst, 'reload schema';

SELECT (SELECT count(*) FROM solicitudes WHERE estado NOT IN ('cancelado','entregado')) AS pedidos_abiertos,
       (SELECT count(*) FROM ventas WHERE origen = 'web') AS ventas_web;
