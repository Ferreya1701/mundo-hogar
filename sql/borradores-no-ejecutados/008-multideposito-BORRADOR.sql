-- ============================================================
-- ⚠️ BORRADOR — NO EJECUTAR EN PRODUCCIÓN ⚠️
-- 008 — Multi-depósito, reservas e idempotencia (diseño 2026-07-13)
-- Estado: PROTOTIPO, no probado contra datos reales.
-- Implementa el modelo de 03_MODELO_PROPUESTO.md, Etapa 0. Ese documento es
-- material interno y no vive en el repo: está en la carpeta del proyecto, en
-- 01_DOCUMENTACION/investigacion-2026-07-13/sistema-stock/.
-- Requiere 001-007 ya aplicados. Pensado para ejecutar en un proyecto
-- Supabase de DESARROLLO/staging primero, nunca directo en el productivo.
-- ============================================================

-- ──────────────────────────────────────────────
-- 1) DEPÓSITOS (Etapa 0: un único "Principal", compatible con lo existente)
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS depositos (
  id          SERIAL PRIMARY KEY,
  nombre      TEXT NOT NULL UNIQUE,
  tipo        TEXT NOT NULL DEFAULT 'deposito'
                CHECK (tipo IN ('local','deposito','vehiculo','virtual')),
  activo      BOOLEAN NOT NULL DEFAULT true,
  es_principal BOOLEAN NOT NULL DEFAULT false,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_deposito_principal
  ON depositos (es_principal) WHERE es_principal;

INSERT INTO depositos (nombre, tipo, es_principal)
VALUES ('Principal', 'deposito', true)
ON CONFLICT (nombre) DO NOTHING;

-- ──────────────────────────────────────────────
-- 2) STOCK POR DEPÓSITO (caché derivada — nunca se escribe a mano)
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stock_por_deposito (
  producto_id INT NOT NULL REFERENCES productos(id) ON DELETE CASCADE,
  deposito_id INT NOT NULL REFERENCES depositos(id) ON DELETE RESTRICT,
  cantidad    INT NOT NULL DEFAULT 0 CHECK (cantidad >= 0),
  PRIMARY KEY (producto_id, deposito_id)
);

ALTER TABLE stock_por_deposito ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "stock_deposito_select_auth" ON stock_por_deposito;
CREATE POLICY "stock_deposito_select_auth" ON stock_por_deposito FOR SELECT
  USING (auth.uid() IS NOT NULL);
-- Sin políticas de escritura para ningún rol: solo el trigger de abajo (SECURITY DEFINER) la toca.

-- ──────────────────────────────────────────────
-- 3) EXTENSIÓN DE movimientos_inventario
-- ──────────────────────────────────────────────
ALTER TABLE movimientos_inventario
  ADD COLUMN IF NOT EXISTS deposito_id         INT REFERENCES depositos(id),
  ADD COLUMN IF NOT EXISTS deposito_destino_id INT REFERENCES depositos(id),
  ADD COLUMN IF NOT EXISTS clave_idempotencia  TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS uq_mov_idempotencia
  ON movimientos_inventario (clave_idempotencia) WHERE clave_idempotencia IS NOT NULL;

-- Backfill: todo movimiento histórico queda asignado al depósito Principal
UPDATE movimientos_inventario
   SET deposito_id = (SELECT id FROM depositos WHERE es_principal)
 WHERE deposito_id IS NULL;

-- ──────────────────────────────────────────────
-- 4) TRIGGER: recalcula stock_por_deposito ante cada movimiento
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_aplicar_movimiento_deposito()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_delta INT;
BEGIN
  v_delta := NEW.stock_posterior - NEW.stock_anterior;

  INSERT INTO stock_por_deposito (producto_id, deposito_id, cantidad)
  VALUES (NEW.producto_id, NEW.deposito_id, GREATEST(v_delta, 0))
  ON CONFLICT (producto_id, deposito_id)
    DO UPDATE SET cantidad = stock_por_deposito.cantidad + v_delta;

  IF NEW.tipo = 'transferencia' AND NEW.deposito_destino_id IS NOT NULL THEN
    INSERT INTO stock_por_deposito (producto_id, deposito_id, cantidad)
    VALUES (NEW.producto_id, NEW.deposito_destino_id, GREATEST(-v_delta, 0))
    ON CONFLICT (producto_id, deposito_id)
      DO UPDATE SET cantidad = stock_por_deposito.cantidad + (-v_delta);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tr_mov_aplicar_deposito ON movimientos_inventario;
CREATE TRIGGER tr_mov_aplicar_deposito
  AFTER INSERT ON movimientos_inventario
  FOR EACH ROW EXECUTE FUNCTION fn_aplicar_movimiento_deposito();

-- ──────────────────────────────────────────────
-- 5) RESERVAS DE STOCK (no descuenta físico; resta de "disponible")
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS reservas_stock (
  id           BIGSERIAL PRIMARY KEY,
  producto_id  INT NOT NULL REFERENCES productos(id) ON DELETE RESTRICT,
  deposito_id  INT NOT NULL REFERENCES depositos(id),
  solicitud_id BIGINT REFERENCES solicitudes(id) ON DELETE CASCADE,
  cantidad     INT NOT NULL CHECK (cantidad > 0),
  estado       TEXT NOT NULL DEFAULT 'activa'
                 CHECK (estado IN ('activa','liberada','consumida')),
  expira_at    TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_reservas_producto ON reservas_stock(producto_id, deposito_id)
  WHERE estado = 'activa';

ALTER TABLE reservas_stock ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "reservas_select_staff" ON reservas_stock;
CREATE POLICY "reservas_select_staff" ON reservas_stock FOR SELECT
  USING (auth.uid() IS NOT NULL);

-- Vista de conveniencia: disponible = físico − reservado activo
CREATE OR REPLACE VIEW v_stock_disponible AS
SELECT sd.producto_id, sd.deposito_id, sd.cantidad AS fisico,
       coalesce(r.reservado, 0) AS reservado,
       sd.cantidad - coalesce(r.reservado, 0) AS disponible
FROM stock_por_deposito sd
LEFT JOIN (
  SELECT producto_id, deposito_id, sum(cantidad) AS reservado
  FROM reservas_stock WHERE estado = 'activa'
  GROUP BY producto_id, deposito_id
) r USING (producto_id, deposito_id);

-- ──────────────────────────────────────────────
-- 6) CONTEOS DE INVENTARIO
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS conteos_inventario (
  id          BIGSERIAL PRIMARY KEY,
  deposito_id INT NOT NULL REFERENCES depositos(id),
  estado      TEXT NOT NULL DEFAULT 'abierto' CHECK (estado IN ('abierto','cerrado')),
  usuario_id  UUID REFERENCES auth.users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  cerrado_at  TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS conteo_lineas (
  id               BIGSERIAL PRIMARY KEY,
  conteo_id        BIGINT NOT NULL REFERENCES conteos_inventario(id) ON DELETE CASCADE,
  producto_id      INT NOT NULL REFERENCES productos(id),
  cantidad_contada INT NOT NULL CHECK (cantidad_contada >= 0),
  cantidad_esperada INT
);

ALTER TABLE conteos_inventario ENABLE ROW LEVEL SECURITY;
ALTER TABLE conteo_lineas      ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "conteos_staff" ON conteos_inventario;
CREATE POLICY "conteos_staff" ON conteos_inventario FOR ALL
  USING (fn_get_user_role() IN ('administrador','encargado_stock'));
DROP POLICY IF EXISTS "conteo_lineas_staff" ON conteo_lineas;
CREATE POLICY "conteo_lineas_staff" ON conteo_lineas FOR ALL
  USING (fn_get_user_role() IN ('administrador','encargado_stock'));

-- Cerrar un conteo genera ajustes automáticos por cada diferencia (nunca UPDATE directo).
CREATE OR REPLACE FUNCTION fn_cerrar_conteo(p_conteo_id BIGINT)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_dep INT; v_linea RECORD; v_diff INT; v_ajustes INT := 0;
BEGIN
  SELECT deposito_id INTO v_dep FROM conteos_inventario WHERE id = p_conteo_id AND estado = 'abierto';
  IF NOT FOUND THEN RAISE EXCEPTION 'conteo_no_encontrado_o_ya_cerrado'; END IF;

  FOR v_linea IN
    SELECT cl.producto_id, cl.cantidad_contada,
           coalesce(sd.cantidad, 0) AS actual
    FROM conteo_lineas cl
    LEFT JOIN stock_por_deposito sd
      ON sd.producto_id = cl.producto_id AND sd.deposito_id = v_dep
    WHERE cl.conteo_id = p_conteo_id
  LOOP
    v_diff := v_linea.cantidad_contada - v_linea.actual;
    IF v_diff <> 0 THEN
      PERFORM set_config('mh.interno', '1', true);
      PERFORM fn_registrar_movimiento(
        v_linea.producto_id,
        CASE WHEN v_diff > 0 THEN 'ajuste_positivo' ELSE 'ajuste_negativo' END,
        abs(v_diff), 'Conteo de inventario #' || p_conteo_id, NULL, NULL, false);
      v_ajustes := v_ajustes + 1;
    END IF;
  END LOOP;

  UPDATE conteos_inventario SET estado = 'cerrado', cerrado_at = now() WHERE id = p_conteo_id;
  RETURN v_ajustes;
END;
$$;

REVOKE ALL ON FUNCTION fn_cerrar_conteo(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION fn_cerrar_conteo(BIGINT) TO authenticated;

-- ============================================================
-- NOTA: fn_registrar_movimiento necesita ganar p_deposito_id y
-- p_clave_idempotencia (no incluido acá para no romper la firma
-- ya usada por 007; se define como paso separado 008b cuando
-- se decida avanzar con esta etapa). Este archivo es un PROTOTIPO
-- de diseño, no un script listo para pegar en el SQL Editor.
-- ============================================================
