-- ============================================================
-- 024 — UBICACIÓN DEL STOCK (2026-11-12)
-- Ejecutar en Supabase → SQL Editor, DESPUÉS del 023.
-- Idempotente: se puede correr más de una vez sin romper nada.
--
-- Dónde está guardado cada producto. Cada producto tiene UNA ubicación,
-- elegida de una lista que arma el negocio: un LUGAR (local, depósito…)
-- y, si hace falta, un SECTOR adentro (estante, fila, góndola).
--   Ej.: "Local Blas Parera", "Depósito 1 · Fila B", "Depósito 2 · Altillo".
--
-- No divide el stock por lugar: dice dónde ir a buscar el producto.
-- (productos.ubicacion, el texto libre de antes, queda como "detalle":
--  "caja 4, arriba".)
--
-- Se ve en Productos, Crear venta y la ficha; en Contar stock se puede
-- filtrar por ubicación y, al guardar un conteo, dejar ubicado todo lo
-- contado ("Estoy contando en…").
--
-- Quién: ver, todo el staff. Ubicar productos y armar la lista: quien
-- tenga "Crear y editar productos", "Contar stock" o "Ajuste manual".
-- ============================================================

CREATE TABLE IF NOT EXISTS ubicaciones (
  id         SERIAL PRIMARY KEY,
  lugar      TEXT NOT NULL CHECK (length(btrim(lugar)) BETWEEN 2 AND 60),
  sector     TEXT CHECK (sector IS NULL OR length(btrim(sector)) BETWEEN 1 AND 60),
  activo     BOOLEAN NOT NULL DEFAULT true,
  orden      INT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_ubicaciones ON ubicaciones (lower(btrim(lugar)), lower(btrim(coalesce(sector, ''))));

ALTER TABLE productos ADD COLUMN IF NOT EXISTS ubicacion_id INT REFERENCES ubicaciones(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_productos_ubicacion ON productos (ubicacion_id);

CREATE OR REPLACE FUNCTION fn_puede_ubicar()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT fn_tiene_permiso('productos.editar') OR fn_tiene_permiso('stock.contar') OR fn_tiene_permiso('stock.ajustar')
$$;

-- Texto para mostrar: "Lugar · Sector"
CREATE OR REPLACE FUNCTION fn_ubicacion_texto(u ubicaciones)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT btrim(u.lugar) || CASE WHEN nullif(btrim(coalesce(u.sector, '')), '') IS NULL THEN '' ELSE ' · ' || btrim(u.sector) END
$$;

ALTER TABLE ubicaciones ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "ubicaciones_select" ON ubicaciones;
CREATE POLICY "ubicaciones_select" ON ubicaciones FOR SELECT USING (fn_get_user_role() IS NOT NULL);
DROP POLICY IF EXISTS "ubicaciones_insert" ON ubicaciones;
CREATE POLICY "ubicaciones_insert" ON ubicaciones FOR INSERT WITH CHECK (fn_puede_ubicar());
DROP POLICY IF EXISTS "ubicaciones_update" ON ubicaciones;
CREATE POLICY "ubicaciones_update" ON ubicaciones FOR UPDATE USING (fn_puede_ubicar()) WITH CHECK (fn_puede_ubicar());
-- No se borran (se desactivan): así un producto nunca queda apuntando a nada sin querer.
REVOKE ALL ON ubicaciones FROM anon;
REVOKE DELETE, TRUNCATE ON ubicaciones FROM authenticated;
GRANT SELECT, INSERT, UPDATE ON ubicaciones TO authenticated;
GRANT USAGE ON SEQUENCE ubicaciones_id_seq TO authenticated;

-- Ubicar uno o muchos productos (p_ubicacion_id NULL = quitar la ubicación)
CREATE OR REPLACE FUNCTION productos_ubicar(p_ids INT[], p_ubicacion_id INT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n INT;
BEGIN
  IF NOT fn_puede_ubicar() THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede cambiar la ubicación de los productos.';
  END IF;
  IF p_ids IS NULL OR cardinality(p_ids) = 0 OR cardinality(p_ids) > 5000 THEN
    RAISE EXCEPTION 'seleccion_invalida' USING HINT = 'Elegí entre 1 y 5000 productos.';
  END IF;
  IF p_ubicacion_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM ubicaciones WHERE id = p_ubicacion_id AND activo) THEN
    RAISE EXCEPTION 'ubicacion_invalida' USING HINT = 'Esa ubicación no existe o está desactivada.';
  END IF;
  UPDATE productos SET ubicacion_id = p_ubicacion_id, updated_by = auth.uid()
  WHERE id = ANY (p_ids) AND ubicacion_id IS DISTINCT FROM p_ubicacion_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'ubicados', v_n);
END;
$$;
REVOKE ALL ON FUNCTION productos_ubicar(INT[], INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION productos_ubicar(INT[], INT) TO authenticated;
REVOKE ALL ON FUNCTION fn_puede_ubicar() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_puede_ubicar() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

SELECT (SELECT count(*) FROM ubicaciones) AS ubicaciones,
       (SELECT count(*) FROM productos WHERE ubicacion_id IS NOT NULL) AS productos_ubicados;
