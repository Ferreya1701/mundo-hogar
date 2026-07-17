-- ============================================================
-- 007 — NÚCLEO DE STOCK ↔ VENTAS (diseño 2026-07-13)
-- Ejecutar en Supabase → SQL Editor, DESPUÉS del 006.
-- Idempotente: se puede correr más de una vez sin romper nada.
--
-- Qué hace:
--   1) Cierra el agujero de seguridad de fn_registrar_movimiento
--      (hoy cualquier visitante anónimo puede alterar stock vía REST)
--   2) Conecta las solicitudes al stock:
--      confirmar → descuenta (salida_venta) / cancelar → repone
--   3) Máquina de estados con transiciones válidas + bitácora
--      (tabla solicitud_eventos) + bloqueo del UPDATE directo de estado
-- ============================================================

-- ──────────────────────────────────────────────
-- 1) COLUMNA DE IDEMPOTENCIA + TABLA DE EVENTOS
-- ──────────────────────────────────────────────
ALTER TABLE solicitudes ADD COLUMN IF NOT EXISTS stock_descontado BOOLEAN NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS solicitud_eventos (
  id              BIGSERIAL PRIMARY KEY,
  solicitud_id    BIGINT NOT NULL REFERENCES solicitudes(id) ON DELETE CASCADE,
  estado_anterior TEXT,
  estado_nuevo    TEXT NOT NULL,
  detalle         TEXT,
  usuario_id      UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_sol_eventos_solicitud ON solicitud_eventos(solicitud_id);

ALTER TABLE solicitud_eventos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "sol_eventos_select_staff" ON solicitud_eventos;
CREATE POLICY "sol_eventos_select_staff" ON solicitud_eventos FOR SELECT
  USING (auth.uid() IS NOT NULL);
-- Sin políticas de INSERT/UPDATE/DELETE: solo escribe la RPC (SECURITY DEFINER). Inmutable.

-- ──────────────────────────────────────────────
-- 2) fn_registrar_movimiento SEGURA
--    - exige rol staff (administrador / encargado_stock)…
--    - …salvo llamada interna de una RPC de dominio (GUC transaccional)
--    - p_permitir_negativo: solo lo usa la vía interna (backorder explícito)
--    NOTA: se DROPea la firma vieja para no dejar una sobrecarga ambigua en PostgREST.
-- ──────────────────────────────────────────────
DROP FUNCTION IF EXISTS fn_registrar_movimiento(INT, TEXT, INT, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION fn_registrar_movimiento(
  p_producto_id        INT,
  p_tipo               TEXT,
  p_cantidad           INT,
  p_motivo             TEXT DEFAULT NULL,
  p_observacion        TEXT DEFAULT NULL,
  p_referencia         TEXT DEFAULT NULL,
  p_permitir_negativo  BOOLEAN DEFAULT false
)
RETURNS movimientos_inventario LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_interno    BOOLEAN := coalesce(current_setting('mh.interno', true), '') = '1';
  v_stock_ant  INT;
  v_stock_new  INT;
  v_delta      INT;
  v_result     movimientos_inventario;
BEGIN
  -- Control de acceso (H1 de la auditoría 2026-07-13):
  IF NOT v_interno AND coalesce(fn_get_user_role(), '') NOT IN ('administrador','encargado_stock') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Solo administrador o encargado de stock pueden registrar movimientos.';
  END IF;
  -- El flag de negativo solo vale para la vía interna (confirmación de venta con permite_venta_sin_stock)
  IF p_permitir_negativo AND NOT v_interno THEN
    p_permitir_negativo := false;
  END IF;

  SELECT stock_actual INTO v_stock_ant
  FROM productos WHERE id = p_producto_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Producto no encontrado: %', p_producto_id;
  END IF;

  CASE p_tipo
    WHEN 'carga_inicial','entrada_compra','ajuste_positivo','devolucion_cliente'
      THEN v_delta :=  ABS(p_cantidad);
    WHEN 'salida_venta','ajuste_negativo','devolucion_proveedor','producto_danado','perdida'
      THEN v_delta := -ABS(p_cantidad);
    ELSE v_delta := p_cantidad; -- transferencia/correccion: valor firmado
  END CASE;

  v_stock_new := v_stock_ant + v_delta;

  IF v_stock_new < 0 AND NOT p_permitir_negativo THEN
    RAISE EXCEPTION 'Stock insuficiente. Actual: %, Movimiento: %', v_stock_ant, v_delta;
  END IF;

  UPDATE productos SET stock_actual = v_stock_new, updated_by = auth.uid()
  WHERE id = p_producto_id;

  INSERT INTO movimientos_inventario
    (producto_id, tipo, cantidad, stock_anterior, stock_posterior,
     motivo, observacion, referencia, usuario_id)
  VALUES
    (p_producto_id, p_tipo, ABS(p_cantidad), v_stock_ant, v_stock_new,
     p_motivo, p_observacion, p_referencia, auth.uid())
  RETURNING * INTO v_result;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION fn_registrar_movimiento(INT,TEXT,INT,TEXT,TEXT,TEXT,BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION fn_registrar_movimiento(INT,TEXT,INT,TEXT,TEXT,TEXT,BOOLEAN) TO authenticated;

-- ──────────────────────────────────────────────
-- 3) RPC DE DOMINIO: cambiar_estado_solicitud
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION cambiar_estado_solicitud(
  p_solicitud_id BIGINT,
  p_nuevo_estado TEXT
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $func$
DECLARE
  v_sol        solicitudes%ROWTYPE;
  v_item       RECORD;
  v_faltantes  JSONB := '[]'::jsonb;
  v_movs       INT := 0;
  v_permitidas TEXT[];
BEGIN
  IF coalesce(fn_get_user_role(), '') NOT IN ('administrador','vendedor') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu rol no puede cambiar estados de solicitudes.';
  END IF;

  SELECT * INTO v_sol FROM solicitudes WHERE id = p_solicitud_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'solicitud_no_encontrada';
  END IF;

  -- Máquina de estados (entregable 03, D3)
  v_permitidas := CASE v_sol.estado
    WHEN 'nueva'              THEN ARRAY['contactado','cotizacion_enviada','confirmado','cancelado']
    WHEN 'contactado'         THEN ARRAY['cotizacion_enviada','confirmado','cancelado']
    WHEN 'cotizacion_enviada' THEN ARRAY['confirmado','cancelado']
    WHEN 'confirmado'         THEN ARRAY['en_preparacion','entregado','cancelado']
    WHEN 'en_preparacion'     THEN ARRAY['entregado','cancelado']
    ELSE ARRAY[]::TEXT[]      -- entregado / cancelado: terminales
  END;

  IF p_nuevo_estado = v_sol.estado THEN
    RETURN jsonb_build_object('ok', true, 'estado', v_sol.estado, 'sin_cambios', true);
  END IF;
  IF NOT (p_nuevo_estado = ANY (v_permitidas)) THEN
    RAISE EXCEPTION 'transicion_invalida'
      USING HINT = format('No se puede pasar de "%s" a "%s".', v_sol.estado, p_nuevo_estado);
  END IF;

  -- Habilita la vía interna para fn_registrar_movimiento y el guard de estado
  PERFORM set_config('mh.interno', '1', true);  -- true = solo esta transacción

  -- CONFIRMAR → descuenta stock (una sola vez por solicitud)
  IF p_nuevo_estado = 'confirmado' AND NOT v_sol.stock_descontado THEN
    -- Pre-chequeo agrupado por producto (error amigable con el detalle completo)
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'producto_id', t.producto_id, 'nombre', t.nombre,
             'pedido', t.pedido, 'disponible', t.stock_actual)), '[]'::jsonb)
      INTO v_faltantes
      FROM (
        SELECT i.producto_id, min(p.nombre) AS nombre,
               sum(i.cantidad)::int AS pedido, min(p.stock_actual) AS stock_actual
          FROM solicitud_items i
          JOIN productos p ON p.id = i.producto_id
         WHERE i.solicitud_id = v_sol.id
           AND p.seguimiento_inventario
           AND NOT p.permite_venta_sin_stock
         GROUP BY i.producto_id
        HAVING sum(i.cantidad) > min(p.stock_actual)
      ) t;

    IF jsonb_array_length(v_faltantes) > 0 THEN
      RAISE EXCEPTION 'stock_insuficiente'
        USING DETAIL = v_faltantes::text,
              HINT = 'Ajustá el stock en Inventario o cancelá la solicitud.';
    END IF;

    FOR v_item IN
      SELECT i.producto_id, i.cantidad, p.permite_venta_sin_stock
        FROM solicitud_items i
        JOIN productos p ON p.id = i.producto_id
       WHERE i.solicitud_id = v_sol.id
         AND p.seguimiento_inventario
    LOOP
      PERFORM fn_registrar_movimiento(
        v_item.producto_id, 'salida_venta', v_item.cantidad,
        'Solicitud confirmada', NULL, v_sol.codigo, v_item.permite_venta_sin_stock);
      v_movs := v_movs + 1;
    END LOOP;

    UPDATE solicitudes SET stock_descontado = true WHERE id = v_sol.id;
  END IF;

  -- CANCELAR una solicitud ya descontada → repone
  IF p_nuevo_estado = 'cancelado' AND v_sol.stock_descontado THEN
    FOR v_item IN
      SELECT i.producto_id, i.cantidad
        FROM solicitud_items i
        JOIN productos p ON p.id = i.producto_id
       WHERE i.solicitud_id = v_sol.id
         AND p.seguimiento_inventario
    LOOP
      PERFORM fn_registrar_movimiento(
        v_item.producto_id, 'devolucion_cliente', v_item.cantidad,
        'Solicitud cancelada', NULL, v_sol.codigo, false);
      v_movs := v_movs + 1;
    END LOOP;

    UPDATE solicitudes SET stock_descontado = false WHERE id = v_sol.id;
  END IF;

  UPDATE solicitudes
     SET estado = p_nuevo_estado,
         atendido_por = coalesce(atendido_por, auth.uid())
   WHERE id = v_sol.id;

  INSERT INTO solicitud_eventos (solicitud_id, estado_anterior, estado_nuevo, detalle, usuario_id)
  VALUES (v_sol.id, v_sol.estado, p_nuevo_estado,
          CASE WHEN v_movs > 0 THEN format('%s movimiento(s) de stock', v_movs) END,
          auth.uid());

  RETURN jsonb_build_object('ok', true, 'estado', p_nuevo_estado, 'movimientos', v_movs);
END;
$func$;

REVOKE ALL ON FUNCTION cambiar_estado_solicitud(BIGINT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cambiar_estado_solicitud(BIGINT, TEXT) TO authenticated;

-- ──────────────────────────────────────────────
-- 4) GUARD: el estado solo cambia por la RPC
--    (defensa en profundidad: bloquea el UPDATE directo vía REST,
--     incluso con sesión de staff)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_guard_estado_solicitud()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.estado IS DISTINCT FROM OLD.estado
     AND coalesce(current_setting('mh.interno', true), '') <> '1' THEN
    RAISE EXCEPTION 'estado_solo_por_rpc'
      USING HINT = 'Usá la función cambiar_estado_solicitud (mantiene el stock consistente).';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tr_solicitudes_guard_estado ON solicitudes;
CREATE TRIGGER tr_solicitudes_guard_estado
  BEFORE UPDATE ON solicitudes FOR EACH ROW EXECUTE FUNCTION fn_guard_estado_solicitud();

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- VERIFICACIÓN RÁPIDA (opcional, correr aparte):
--   1. Como anónimo, POST /rest/v1/rpc/fn_registrar_movimiento → debe dar "sin_permiso".
--   2. En el panel, Inventario → Registrar movimiento → debe seguir funcionando igual.
--   3. Solicitud de prueba → confirmar → el stock baja y aparece el movimiento
--      salida_venta con referencia MH-…; cancelar → vuelve con devolucion_cliente.
--   4. Confirmar dos veces la misma solicitud → no descuenta dos veces.
-- ============================================================
