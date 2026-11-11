-- ============================================================
-- 017 — DATOS FISCALES PARA TICKETS Y RECIBOS (2026-11-11)
-- Ejecutar en Supabase → SQL Editor, DESPUÉS del 016.
-- Idempotente: se puede correr más de una vez sin romper nada.
--
-- Lo que va impreso en el encabezado del ticket de compra y del recibo:
-- CUIT, domicilio, ingresos brutos, inicio de actividades y condición
-- frente al IVA. Se editan en Configuración (solo administrador), sin
-- tocar código. Se cargan con los datos del negocio SOLO si están vacíos:
-- volver a correr el script no pisa lo que se haya cambiado después.
--
-- Son datos públicos por naturaleza (van en cada comprobante), así que
-- se leen con la misma regla que el resto de site_settings.
-- ============================================================

-- CUIT válido: 11 dígitos y dígito verificador correcto (módulo 11).
CREATE OR REPLACE FUNCTION fn_cuit_valido(p TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_pesos INT[] := ARRAY[5,4,3,2,7,6,5,4,3,2];
  v_suma  INT := 0;
  v_dv    INT;
BEGIN
  IF p IS NULL OR p !~ '^\d{11}$' THEN RETURN false; END IF;
  FOR i IN 1..10 LOOP
    v_suma := v_suma + substr(p, i, 1)::int * v_pesos[i];
  END LOOP;
  v_dv := 11 - (v_suma % 11);
  v_dv := CASE v_dv WHEN 11 THEN 0 WHEN 10 THEN 9 ELSE v_dv END;
  RETURN v_dv = substr(p, 11, 1)::int;
END;
$$;

ALTER TABLE site_settings ADD COLUMN IF NOT EXISTS cuit                TEXT;
ALTER TABLE site_settings ADD COLUMN IF NOT EXISTS domicilio_fiscal    TEXT;
ALTER TABLE site_settings ADD COLUMN IF NOT EXISTS ingresos_brutos     TEXT;
ALTER TABLE site_settings ADD COLUMN IF NOT EXISTS inicio_actividades  DATE;
ALTER TABLE site_settings ADD COLUMN IF NOT EXISTS condicion_iva       TEXT;
-- Texto libre al pie del ticket (ej. política de cambios). Opcional.
ALTER TABLE site_settings ADD COLUMN IF NOT EXISTS ticket_pie          TEXT;

ALTER TABLE site_settings DROP CONSTRAINT IF EXISTS site_settings_cuit_valido;
ALTER TABLE site_settings ADD CONSTRAINT site_settings_cuit_valido
  CHECK (cuit IS NULL OR fn_cuit_valido(cuit));

ALTER TABLE site_settings DROP CONSTRAINT IF EXISTS site_settings_condicion_iva;
ALTER TABLE site_settings ADD CONSTRAINT site_settings_condicion_iva
  CHECK (condicion_iva IS NULL OR condicion_iva IN ('responsable_inscripto', 'monotributo', 'exento'));

ALTER TABLE site_settings DROP CONSTRAINT IF EXISTS site_settings_textos_fiscales;
ALTER TABLE site_settings ADD CONSTRAINT site_settings_textos_fiscales
  CHECK (coalesce(length(domicilio_fiscal), 0) <= 200
     AND coalesce(length(ingresos_brutos), 0) <= 40
     AND coalesce(length(ticket_pie), 0) <= 300);

-- Datos del negocio (solo donde todavía no hay nada cargado)
INSERT INTO site_settings (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
UPDATE site_settings SET
  cuit               = coalesce(cuit, '20356530781'),
  domicilio_fiscal   = coalesce(domicilio_fiscal, 'Blas Parera 9961'),
  ingresos_brutos    = coalesce(ingresos_brutos, '0116724067'),
  inicio_actividades = coalesce(inicio_actividades, DATE '2015-07-01'),
  condicion_iva      = coalesce(condicion_iva, 'responsable_inscripto')
WHERE id = 1;

NOTIFY pgrst, 'reload schema';

-- Para revisar al correrlo
SELECT nombre_tienda, cuit, domicilio_fiscal, ingresos_brutos, inicio_actividades, condicion_iva
FROM site_settings WHERE id = 1;
