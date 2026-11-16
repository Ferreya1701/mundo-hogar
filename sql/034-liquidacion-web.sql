-- ============================================================
-- 034 — Liquidación solo de pedidos web, comisión solo para los dueños (2026-11-16)
-- ------------------------------------------------------------
-- • La liquidación mensual cuenta SOLO los cobros de pedidos web (movimientos
--   con pedido). Las ventas del local (Crear venta / caja) no entran.
-- • El administrador del local ve las liquidaciones (totales por mes y por
--   cuenta) pero NO el porcentaje ni la comisión: esas dos columnas solo las
--   leen los dueños del sistema (sql/033), con liquidaciones_comision().
-- • Cerrar un mes lo hacen solo los dueños (el cierre calcula la comisión).
-- • comision_estimada_mes(): lo cobrado por pedidos web en el mes y la
--   comisión estimada, solo para los dueños.
--
-- Requiere 001..033. Idempotente.
-- ============================================================

-- Columnas a la vista del panel: todo menos porcentaje y comisión
REVOKE ALL ON liquidaciones FROM anon, authenticated;
GRANT SELECT (id, periodo, total_cobrado, detalle, cerrada_por, created_at) ON liquidaciones TO authenticated;

CREATE OR REPLACE FUNCTION liquidaciones_comision()
RETURNS TABLE (id BIGINT, porcentaje NUMERIC, comision NUMERIC)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT fn_es_dueno_sistema() THEN RAISE EXCEPTION 'sin_permiso'; END IF;
  RETURN QUERY SELECT l.id, l.porcentaje, l.comision FROM liquidaciones l;
END;
$$;
REVOKE ALL ON FUNCTION liquidaciones_comision() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION liquidaciones_comision() TO authenticated;

CREATE OR REPLACE FUNCTION comision_estimada_mes()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_desde TIMESTAMP := date_trunc('month', fn_mh_local(now()));
  v_total NUMERIC;
  v_n     INT;
  v_pct   NUMERIC;
BEGIN
  IF NOT fn_es_dueno_sistema() THEN RAISE EXCEPTION 'sin_permiso'; END IF;
  SELECT coalesce(sum(CASE WHEN tipo = 'cobro' THEN monto ELSE -monto END), 0),
         count(*) FILTER (WHERE tipo = 'cobro')
    INTO v_total, v_n
    FROM movimientos_cobro
   WHERE solicitud_id IS NOT NULL AND fn_mh_local(fecha) >= v_desde;
  SELECT coalesce(comision_pct, 0) INTO v_pct FROM config_duenos WHERE id = 1;
  RETURN jsonb_build_object('total_web', v_total, 'cobros_web', v_n, 'porcentaje', coalesce(v_pct, 0),
                            'comision', round(v_total * coalesce(v_pct, 0) / 100, 2));
END;
$$;
REVOKE ALL ON FUNCTION comision_estimada_mes() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION comision_estimada_mes() TO authenticated;

-- Cierre de liquidación (sql/033): solo dueños y solo pedidos web
CREATE OR REPLACE FUNCTION cerrar_liquidacion(p_periodo TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_desde TIMESTAMP;
  v_hasta TIMESTAMP;
  v_pct   NUMERIC;
  v_total NUMERIC;
  v_det   JSONB;
  v_id    BIGINT;
BEGIN
  IF NOT fn_es_dueno_sistema() THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'La liquidación la cierran los dueños del sistema.';
  END IF;
  IF p_periodo !~ '^\d{4}-\d{2}$' THEN RAISE EXCEPTION 'periodo_invalido'; END IF;
  IF EXISTS (SELECT 1 FROM liquidaciones WHERE periodo = p_periodo) THEN
    RAISE EXCEPTION 'liquidacion_ya_cerrada' USING HINT = 'Ese período ya está cerrado.';
  END IF;
  v_desde := to_timestamp(p_periodo || '-01', 'YYYY-MM-DD')::timestamp;
  v_hasta := v_desde + interval '1 month';
  IF v_hasta > fn_mh_local(now()) THEN
    RAISE EXCEPTION 'periodo_abierto' USING HINT = 'El mes todavía no terminó.';
  END IF;
  SELECT coalesce(comision_pct, 0) INTO v_pct FROM config_duenos WHERE id = 1;

  WITH m AS (
    SELECT mc.cuenta_cobro_id, c.nombre, c.titular,
           sum(CASE WHEN mc.tipo = 'cobro' THEN mc.monto ELSE -mc.monto END) AS total,
           count(*) FILTER (WHERE mc.tipo = 'cobro') AS cobros,
           count(*) FILTER (WHERE mc.tipo = 'anulacion') AS anulaciones
      FROM movimientos_cobro mc JOIN cuentas_cobro c ON c.id = mc.cuenta_cobro_id
     WHERE mc.solicitud_id IS NOT NULL   -- solo pedidos web (no ventas del local)
       AND fn_mh_local(mc.fecha) >= v_desde AND fn_mh_local(mc.fecha) < v_hasta
     GROUP BY mc.cuenta_cobro_id, c.nombre, c.titular
  )
  SELECT coalesce(sum(total), 0),
         coalesce(jsonb_agg(jsonb_build_object('cuenta_id', cuenta_cobro_id, 'nombre', nombre, 'titular', titular,
                  'total', total, 'cobros', cobros, 'anulaciones', anulaciones) ORDER BY nombre), '[]'::jsonb)
    INTO v_total, v_det FROM m;

  INSERT INTO liquidaciones (periodo, porcentaje, total_cobrado, comision, detalle, cerrada_por)
  VALUES (p_periodo, v_pct, v_total, round(v_total * v_pct / 100, 2),
          jsonb_build_object('cuentas', v_det,
            'pedidos', (SELECT coalesce(jsonb_agg(jsonb_build_object('codigo', s.codigo, 'monto', mc.monto, 'tipo', mc.tipo,
                               'fecha', mc.fecha, 'cuenta_id', mc.cuenta_cobro_id) ORDER BY mc.fecha), '[]'::jsonb)
                          FROM movimientos_cobro mc JOIN solicitudes s ON s.id = mc.solicitud_id
                         WHERE fn_mh_local(mc.fecha) >= v_desde AND fn_mh_local(mc.fecha) < v_hasta)),
          auth.uid())
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'periodo', p_periodo, 'total_cobrado', v_total,
                            'porcentaje', v_pct, 'comision', round(v_total * v_pct / 100, 2));
END;
$$;
REVOKE ALL ON FUNCTION cerrar_liquidacion(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cerrar_liquidacion(TEXT) TO authenticated;
