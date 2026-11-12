-- ============================================================
-- 022 — REPARAR fn_registrar_movimiento EN PRODUCCIÓN (2026-11-12)
-- Ejecutar en Supabase → SQL Editor. Idempotente.
--
-- Qué pasó: en producción la función que asienta movimientos de stock
-- había quedado en la versión del 007 (sin el paso del 008 que marca la
-- transacción con 'mh.stock'), mientras que el control del 008
-- (tr_productos_guard_stock) sí estaba activo. Resultado: cualquier
-- movimiento de stock fallaba con "stock_solo_por_movimiento" (contar,
-- vender un producto controlado, recibir compras, importar stock). No se
-- notó porque todavía no había ventas ni productos contados. Se detectó
-- el 2026-11-12 al importar el catálogo: comparando las 99 funciones de
-- producción con las del repo, esta era la única distinta.
--
-- Qué hace: agrega SOLO el paso que falta, justo antes de actualizar el
-- stock. No toca el resto de la función (incluido el permiso del 016).
-- Si la función ya lo tiene (como en una base armada desde el repo), no
-- hace nada.
-- ============================================================

DO $migr$
DECLARE
  v_def    TEXT := pg_get_functiondef('fn_registrar_movimiento(integer,text,integer,text,text,text,boolean)'::regprocedure);
  v_antes  TEXT := '  UPDATE productos SET stock_actual = v_stock_new, updated_by = auth.uid()';
  v_despues TEXT := E'  -- NUEVO (008): habilita el guard de stock SOLO dentro de esta transacción\n'
                 || E'  PERFORM set_config(''mh.stock'', ''1'', true);\n\n'
                 || '  UPDATE productos SET stock_actual = v_stock_new, updated_by = auth.uid()';
BEGIN
  IF position('mh.stock' IN v_def) > 0 THEN
    RAISE NOTICE '022: fn_registrar_movimiento ya habilita el guard de stock, no hay nada que hacer';
  ELSIF position(v_antes IN v_def) > 0 THEN
    EXECUTE replace(v_def, v_antes, v_despues);
  ELSE
    RAISE EXCEPTION '022: no encontré la actualización de stock esperada en fn_registrar_movimiento. Revisar a mano.';
  END IF;
END
$migr$;

-- Para revisar al correrlo: tiene que dar true
SELECT pg_get_functiondef('fn_registrar_movimiento(integer,text,integer,text,text,text,boolean)'::regprocedure) LIKE '%mh.stock%'
       AS movimientos_de_stock_habilitados;
