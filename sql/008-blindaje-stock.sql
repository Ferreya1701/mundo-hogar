-- ============================================================
-- 008 — BLINDAJE DE STOCK (2026-07-13)
-- Ejecutar en Supabase → SQL Editor, DESPUÉS del 007.
-- Idempotente: se puede correr más de una vez sin romper nada.
--
-- Qué cierra (ítem C3 del backlog / pregunta 1 del diagnóstico):
--   Hoy un usuario staff logueado puede hacer
--     UPDATE productos SET stock_actual = 999
--   directo por la API REST, salteándose el libro de movimientos.
--   El número queda cambiado sin asiento, sin usuario, sin motivo,
--   y el stock deja de poder reconstruirse desde el historial.
--
-- Cómo lo cierra:
--   1) fn_registrar_movimiento marca su transacción con un flag
--      interno (GUC transaccional 'mh.stock') antes de tocar stock.
--   2) Un trigger sobre productos rechaza cualquier UPDATE que
--      cambie stock_actual sin ese flag, y cualquier INSERT con
--      stock_actual distinto de 0 (el alta siempre nace en 0; la
--      carga inicial entra como movimiento 'carga_inicial').
--
-- Por qué NO se agrega CHECK (stock_actual >= 0) a la columna:
--   el diseño del 007 permite stock negativo explícito (backorder)
--   para productos con permite_venta_sin_stock = true. Un CHECK
--   duro rompería ese caso. El no-negativo ya lo garantiza la
--   función para todos los demás.
--
-- Escape de emergencia (solo administrador de la base, consciente):
--   ALTER TABLE productos DISABLE TRIGGER tr_productos_guard_stock;
--   -- ...corrección excepcional...
--   ALTER TABLE productos ENABLE TRIGGER tr_productos_guard_stock;
--
-- NOTA de numeración: el borrador multi-depósito que estaba en
-- sql/borradores-no-ejecutados/008-multideposito-BORRADOR.sql se
-- renumerará (009+) cuando se decida construirlo. Este 008 es el
-- oficial y ejecutable.
-- ============================================================

-- ──────────────────────────────────────────────
-- 1) fn_registrar_movimiento: igual que en 007, más el flag
--    'mh.stock' que habilita al trigger de abajo.
--    Misma firma (7 parámetros) → CREATE OR REPLACE directo,
--    sin DROP, sin sobrecarga ambigua.
-- ──────────────────────────────────────────────
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
  -- Control de acceso (H1, cerrado en 007):
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

  -- NUEVO (008): habilita el guard de stock SOLO dentro de esta transacción
  PERFORM set_config('mh.stock', '1', true);

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

-- Reafirmar permisos (por si el REPLACE los tocara; idempotente)
REVOKE ALL ON FUNCTION fn_registrar_movimiento(INT,TEXT,INT,TEXT,TEXT,TEXT,BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION fn_registrar_movimiento(INT,TEXT,INT,TEXT,TEXT,TEXT,BOOLEAN) TO authenticated;

-- ──────────────────────────────────────────────
-- 2) GUARD: stock_actual solo cambia por movimiento
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_guard_stock_producto()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF coalesce(NEW.stock_actual, 0) <> 0
       AND coalesce(current_setting('mh.stock', true), '') <> '1' THEN
      RAISE EXCEPTION 'stock_solo_por_movimiento'
        USING HINT = 'El alta nace con stock 0. Cargá el stock inicial con un movimiento de tipo carga_inicial (Inventario → Registrar movimiento).';
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE
  IF NEW.stock_actual IS DISTINCT FROM OLD.stock_actual
     AND coalesce(current_setting('mh.stock', true), '') <> '1' THEN
    RAISE EXCEPTION 'stock_solo_por_movimiento'
      USING HINT = 'El stock no se edita directo: registrá un movimiento (fn_registrar_movimiento) para que quede asentado quién, cuánto y por qué.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tr_productos_guard_stock ON productos;
CREATE TRIGGER tr_productos_guard_stock
  BEFORE INSERT OR UPDATE ON productos
  FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_producto();

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- VERIFICACIÓN RÁPIDA (correr aparte, después de este script):
--   1. UPDATE productos SET stock_actual = 999 WHERE id = 1;
--      → debe fallar con 'stock_solo_por_movimiento'.
--   2. UPDATE productos SET destacado = NOT destacado WHERE id = 1;
--      (y volverlo) → debe funcionar: solo el stock está blindado,
--      el resto del producto se edita normal.
--   3. En el panel: Inventario → Registrar movimiento (entrada de 1)
--      → debe funcionar igual que siempre y dejar su asiento.
--   4. En el panel: crear un producto nuevo con stock inicial
--      → debe crearse y el stock entrar como 'carga_inicial'
--        (una sola vez, sin duplicar).
-- ============================================================
