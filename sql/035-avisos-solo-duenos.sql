-- ============================================================
-- 035 — "Avisos del banco" solo para los dueños del sistema (2026-11-16)
-- ------------------------------------------------------------
-- Las direcciones secretas de reenvío, el código de Gmail y la configuración
-- de la verificación (confirmar solo, minutos de espera, tolerancia, mails de
-- alerta) los ven y cambian solo los dueños del sistema (sql/033).
-- Sin cambios: el staff de ventas sigue leyendo minutos/tolerancia (el detalle
-- del pedido los usa), los avisos de su pedido y las alertas.
-- Requiere 001..034. Idempotente.
-- ============================================================

DROP POLICY IF EXISTS "cca_admin" ON cuentas_cobro_avisos;
DROP POLICY IF EXISTS "cca_duenos" ON cuentas_cobro_avisos;
CREATE POLICY "cca_duenos" ON cuentas_cobro_avisos FOR SELECT USING (fn_es_dueno_sistema());

DROP POLICY IF EXISTS "avisos_config_admin" ON cobros_avisos_config;
DROP POLICY IF EXISTS "avisos_config_duenos" ON cobros_avisos_config;
CREATE POLICY "avisos_config_duenos" ON cobros_avisos_config FOR UPDATE
  USING (fn_es_dueno_sistema()) WITH CHECK (fn_es_dueno_sistema());

CREATE OR REPLACE FUNCTION cuenta_avisos_regenerar(p_cuenta_id BIGINT)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_t TEXT := fn_avisos_token_nuevo();
BEGIN
  IF NOT fn_es_dueno_sistema() THEN RAISE EXCEPTION 'sin_permiso'; END IF;
  INSERT INTO cuentas_cobro_avisos (cuenta_cobro_id, token) VALUES (p_cuenta_id, v_t)
  ON CONFLICT (cuenta_cobro_id) DO UPDATE
     SET token = v_t, gmail_codigo = NULL, gmail_link = NULL, gmail_en = NULL,
         primer_aviso_en = NULL, ultimo_aviso_en = NULL, ultimo_mail_en = NULL, alerta_caida_en = NULL;
  RETURN v_t;
END;
$$;
REVOKE ALL ON FUNCTION cuenta_avisos_regenerar(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cuenta_avisos_regenerar(BIGINT) TO authenticated;
