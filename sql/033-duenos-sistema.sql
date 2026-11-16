-- ============================================================
-- 033 — Dueños del sistema y "Configuración web" (2026-11-16)
-- ------------------------------------------------------------
-- Los dueños del sistema (quienes desarrollan y mantienen la web, no el
-- administrador del local) son los únicos que ven y cambian la
-- "Configuración web" de cobros: cobros activos, confirmación solo con
-- comprobante, plazo para pagar, instrucciones al cliente y su comisión.
--
-- • duenos_sistema: quiénes son. Se cargan a mano (el repo es público, los
--   mails no van acá):  INSERT INTO duenos_sistema (user_id)
--                        SELECT id FROM auth.users WHERE email IN ('…', '…');
-- • La comisión sale de site_settings (que es pública) y pasa a config_duenos.
-- • Un administrador que no es dueño no puede cambiar esas columnas de
--   site_settings (lo frena la base, no solo la pantalla).
--
-- Requiere 001..032. Idempotente.
-- ============================================================

CREATE TABLE IF NOT EXISTS duenos_sistema (
  user_id    UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  creado_en  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION fn_es_dueno_sistema()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM duenos_sistema d JOIN profiles p ON p.id = d.user_id
     WHERE d.user_id = auth.uid() AND p.activo AND p.rol = 'administrador')
$$;
REVOKE ALL ON FUNCTION fn_es_dueno_sistema() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION fn_es_dueno_sistema() TO authenticated;

ALTER TABLE duenos_sistema ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "duenos_ver" ON duenos_sistema;
CREATE POLICY "duenos_ver" ON duenos_sistema FOR SELECT USING (fn_es_dueno_sistema());
REVOKE ALL ON duenos_sistema FROM anon, authenticated;
GRANT SELECT ON duenos_sistema TO authenticated;

-- Configuración privada de los dueños
CREATE TABLE IF NOT EXISTS config_duenos (
  id            INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  comision_pct  NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (comision_pct BETWEEN 0 AND 100),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- Se trae la comisión que estaba a la vista (solo la primera vez)
INSERT INTO config_duenos (id, comision_pct)
SELECT 1, coalesce((SELECT comision_pct FROM site_settings WHERE id = 1), 0)
ON CONFLICT (id) DO NOTHING;
ALTER TABLE config_duenos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "config_duenos_ver" ON config_duenos;
CREATE POLICY "config_duenos_ver" ON config_duenos FOR SELECT USING (fn_es_dueno_sistema());
DROP POLICY IF EXISTS "config_duenos_editar" ON config_duenos;
CREATE POLICY "config_duenos_editar" ON config_duenos FOR UPDATE
  USING (fn_es_dueno_sistema()) WITH CHECK (fn_es_dueno_sistema());
REVOKE ALL ON config_duenos FROM anon, authenticated;
GRANT SELECT, UPDATE ON config_duenos TO authenticated;

-- La columna vieja queda en 0 (site_settings la lee cualquiera); ya no se usa.
UPDATE site_settings SET comision_pct = 0 WHERE id = 1 AND comision_pct <> 0;
COMMENT ON COLUMN site_settings.comision_pct IS 'En desuso desde sql/033: la comisión está en config_duenos (privada).';

-- Solo los dueños cambian la configuración web de cobros
CREATE OR REPLACE FUNCTION fn_tr_site_settings_config_web()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT fn_es_dueno_sistema() AND (
       NEW.cobros_activos        IS DISTINCT FROM OLD.cobros_activos
    OR NEW.cobros_plazo_horas    IS DISTINCT FROM OLD.cobros_plazo_horas
    OR NEW.cobros_auto_confirmar IS DISTINCT FROM OLD.cobros_auto_confirmar
    OR NEW.cobros_instrucciones  IS DISTINCT FROM OLD.cobros_instrucciones
    OR NEW.comision_pct          IS DISTINCT FROM OLD.comision_pct) THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'La configuración web la cambian solo los dueños del sistema.';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION fn_tr_site_settings_config_web() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS tr_site_settings_config_web ON site_settings;
CREATE TRIGGER tr_site_settings_config_web BEFORE UPDATE ON site_settings
  FOR EACH ROW EXECUTE FUNCTION fn_tr_site_settings_config_web();

-- Cierre de liquidación (sql/012) con la comisión de config_duenos
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
  IF coalesce(fn_get_user_role(), '') <> 'administrador' THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Solo un administrador puede cerrar liquidaciones.';
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
     WHERE fn_mh_local(mc.fecha) >= v_desde AND fn_mh_local(mc.fecha) < v_hasta
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
                          FROM movimientos_cobro mc LEFT JOIN solicitudes s ON s.id = mc.solicitud_id
                         WHERE fn_mh_local(mc.fecha) >= v_desde AND fn_mh_local(mc.fecha) < v_hasta)),
          auth.uid())
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'periodo', p_periodo, 'total_cobrado', v_total,
                            'porcentaje', v_pct, 'comision', round(v_total * v_pct / 100, 2));
END;
$$;
REVOKE ALL ON FUNCTION cerrar_liquidacion(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cerrar_liquidacion(TEXT) TO authenticated;
