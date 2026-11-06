-- ============================================================
-- 015 — QUÉ VE CADA ROL (2026-11-06)
-- Ejecutar en Supabase → SQL Editor, DESPUÉS del 014.
-- Idempotente: se puede correr más de una vez sin romper nada.
--
-- Por qué existe: varias tablas solo pedían "estar logueado"
-- (auth.uid() IS NOT NULL). Eso dejaba que un vendedor leyera con su
-- sesión cosas del administrador aunque la pantalla no las mostrara,
-- que una cuenta DESACTIVADA siguiera leyendo si entraba por fuera del
-- panel, y que el costo y el proveedor de los productos activos fueran
-- legibles por CUALQUIERA en internet (la tienda lee productos con la
-- clave pública).
--
-- Qué cambia:
--   E) "Staff" = cuenta ACTIVA con rol (fn_get_user_role() IS NOT NULL),
--      no solo "logueado". Una cuenta desactivada no lee nada.
--   A) Ventas: el vendedor ve solo las suyas; administrador y encargado
--      de stock ven todas.
--   B) Costos y compras: solo administrador y encargado de stock.
--      El costo y el proveedor de cada producto pasan a producto_costos
--      (con permisos propios). Las columnas productos.precio_costo y
--      productos.proveedor quedan siempre vacías: lo que se escriba ahí
--      (formulario viejo, compras, importación) se muda solo a
--      producto_costos.
--   C) Cuentas bancarias: la tabla completa (CUIT, límites, peso, notas)
--      solo el administrador. El resto del staff usa la vista
--      cuentas_cobro_staff: nombre, titular y alias (o CBU si no hay
--      alias), que es lo mismo que ve el cliente al pagar.
--   D) Historial de actividad: lo lee solo el administrador.
-- ============================================================


-- ──────────────────────────────────────────────
-- E) Staff = cuenta activa con rol
-- ──────────────────────────────────────────────
DROP POLICY IF EXISTS "productos_select_public" ON productos;
CREATE POLICY "productos_select_public" ON productos FOR SELECT
  USING (estado = 'activo' OR fn_get_user_role() IS NOT NULL);

DROP POLICY IF EXISTS "movimientos_select_auth" ON movimientos_inventario;
CREATE POLICY "movimientos_select_auth" ON movimientos_inventario FOR SELECT
  USING (fn_get_user_role() IS NOT NULL);

DROP POLICY IF EXISTS "solicitudes_select_staff" ON solicitudes;
CREATE POLICY "solicitudes_select_staff" ON solicitudes FOR SELECT
  USING (fn_get_user_role() IS NOT NULL);

DROP POLICY IF EXISTS "solicitud_items_select_staff" ON solicitud_items;
CREATE POLICY "solicitud_items_select_staff" ON solicitud_items FOR SELECT
  USING (fn_get_user_role() IS NOT NULL);

DROP POLICY IF EXISTS "sol_eventos_select_staff" ON solicitud_eventos;
CREATE POLICY "sol_eventos_select_staff" ON solicitud_eventos FOR SELECT
  USING (fn_get_user_role() IS NOT NULL);

DROP POLICY IF EXISTS "comprobantes_select_staff" ON comprobantes;
CREATE POLICY "comprobantes_select_staff" ON comprobantes FOR SELECT
  USING (fn_get_user_role() IS NOT NULL);

-- Archivos de comprobantes (solo existe en Supabase, no en las pruebas)
DO $$
BEGIN
  IF to_regclass('storage.objects') IS NOT NULL THEN
    EXECUTE 'DROP POLICY IF EXISTS "comprobantes_lectura_staff" ON storage.objects';
    EXECUTE $p$CREATE POLICY "comprobantes_lectura_staff" ON storage.objects FOR SELECT
      USING (bucket_id = 'comprobantes' AND fn_get_user_role() IS NOT NULL)$p$;
  END IF;
END $$;


-- ──────────────────────────────────────────────
-- A) Ventas: cada vendedor ve las suyas
-- ──────────────────────────────────────────────
DROP POLICY IF EXISTS "ventas_select_staff" ON ventas;
CREATE POLICY "ventas_select_staff" ON ventas FOR SELECT
  USING (fn_get_user_role() IN ('administrador', 'encargado_stock')
         OR (fn_get_user_role() = 'vendedor' AND vendedor_id = auth.uid()));

-- Los renglones siguen a su venta (la subconsulta respeta la política de ventas)
DROP POLICY IF EXISTS "venta_items_select_staff" ON venta_items;
CREATE POLICY "venta_items_select_staff" ON venta_items FOR SELECT
  USING (EXISTS (SELECT 1 FROM ventas v WHERE v.id = venta_items.venta_id));


-- ──────────────────────────────────────────────
-- B) Compras: solo administrador y encargado de stock
-- ──────────────────────────────────────────────
DROP POLICY IF EXISTS "compras_select_staff" ON compras;
CREATE POLICY "compras_select_staff" ON compras FOR SELECT USING (fn_es_staff_stock());

DROP POLICY IF EXISTS "compra_items_select_staff" ON compra_items;
CREATE POLICY "compra_items_select_staff" ON compra_items FOR SELECT USING (fn_es_staff_stock());

DROP POLICY IF EXISTS "compra_recep_select_staff" ON compra_recepciones;
CREATE POLICY "compra_recep_select_staff" ON compra_recepciones FOR SELECT USING (fn_es_staff_stock());

DROP POLICY IF EXISTS "compra_recep_items_select_staff" ON compra_recepcion_items;
CREATE POLICY "compra_recep_items_select_staff" ON compra_recepcion_items FOR SELECT USING (fn_es_staff_stock());


-- ──────────────────────────────────────────────
-- B) Costo y proveedor de cada producto, aparte
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS producto_costos (
  producto_id   INT PRIMARY KEY REFERENCES productos(id) ON DELETE CASCADE,
  precio_costo  NUMERIC(12,2) CHECK (precio_costo IS NULL OR precio_costo >= 0),
  proveedor     TEXT CHECK (proveedor IS NULL OR length(proveedor) <= 200),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by    UUID REFERENCES auth.users(id) ON DELETE SET NULL
);

ALTER TABLE producto_costos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "producto_costos_staff_stock" ON producto_costos;
CREATE POLICY "producto_costos_staff_stock" ON producto_costos FOR ALL
  USING (fn_es_staff_stock()) WITH CHECK (fn_es_staff_stock());
REVOKE ALL ON producto_costos FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON producto_costos TO authenticated;

CREATE OR REPLACE FUNCTION fn_producto_costos_touch()
RETURNS TRIGGER LANGUAGE plpgsql AS $func$
BEGIN
  NEW.updated_at := now();
  NEW.updated_by := coalesce(auth.uid(), NEW.updated_by);
  RETURN NEW;
END;
$func$;
DROP TRIGGER IF EXISTS tr_producto_costos_touch ON producto_costos;
CREATE TRIGGER tr_producto_costos_touch
  BEFORE INSERT OR UPDATE ON producto_costos FOR EACH ROW EXECUTE FUNCTION fn_producto_costos_touch();

-- Lo que se escriba en productos.precio_costo / productos.proveedor se muda
-- a producto_costos y la fila de productos queda vacía en esas columnas.
-- Así siguen andando las compras (sql/013), la importación y cualquier
-- formulario viejo, sin que el dato quede a la vista de la tienda.
CREATE OR REPLACE FUNCTION fn_productos_mudar_costos()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $func$
BEGIN
  INSERT INTO producto_costos (producto_id, precio_costo, proveedor)
  VALUES (NEW.id, NEW.precio_costo, nullif(btrim(NEW.proveedor), ''))
  ON CONFLICT (producto_id) DO UPDATE SET
    precio_costo = coalesce(EXCLUDED.precio_costo, producto_costos.precio_costo),
    proveedor    = coalesce(EXCLUDED.proveedor,    producto_costos.proveedor);
  UPDATE productos SET precio_costo = NULL, proveedor = NULL WHERE id = NEW.id;
  RETURN NULL;
END;
$func$;

-- Mudanza de lo que ya hay (antes de crear el trigger)
INSERT INTO producto_costos (producto_id, precio_costo, proveedor)
SELECT id, precio_costo, nullif(btrim(proveedor), '')
FROM productos
WHERE precio_costo IS NOT NULL OR nullif(btrim(proveedor), '') IS NOT NULL
ON CONFLICT (producto_id) DO UPDATE SET
  precio_costo = coalesce(EXCLUDED.precio_costo, producto_costos.precio_costo),
  proveedor    = coalesce(EXCLUDED.proveedor,    producto_costos.proveedor);
UPDATE productos SET precio_costo = NULL, proveedor = NULL
WHERE precio_costo IS NOT NULL OR proveedor IS NOT NULL;

DROP TRIGGER IF EXISTS tr_productos_mudar_costos ON productos;
CREATE TRIGGER tr_productos_mudar_costos
  AFTER INSERT OR UPDATE OF precio_costo, proveedor ON productos
  FOR EACH ROW WHEN (NEW.precio_costo IS NOT NULL OR NEW.proveedor IS NOT NULL)
  EXECUTE FUNCTION fn_productos_mudar_costos();

REVOKE ALL ON FUNCTION fn_productos_mudar_costos() FROM PUBLIC, anon, authenticated;


-- ──────────────────────────────────────────────
-- C) Cuentas bancarias
-- ──────────────────────────────────────────────
-- La tabla completa: solo el administrador (su política FOR ALL del 012
-- ya incluye leer). Se quita la lectura para todo el staff.
DROP POLICY IF EXISTS "cuentas_cobro_select_staff" ON cuentas_cobro;

-- Lo que necesita el resto del staff para cobrar y pasarle los datos al
-- cliente. Vista con los permisos de su dueño: el filtro de staff va adentro.
CREATE OR REPLACE VIEW cuentas_cobro_staff AS
SELECT c.id, c.nombre, c.titular, c.alias,
       CASE WHEN nullif(btrim(c.alias), '') IS NULL THEN c.cvu END AS cvu,
       c.banco, c.activa, c.orden
FROM cuentas_cobro c
WHERE fn_get_user_role() IS NOT NULL;

REVOKE ALL ON cuentas_cobro_staff FROM PUBLIC, anon;
GRANT SELECT ON cuentas_cobro_staff TO authenticated;


-- ──────────────────────────────────────────────
-- D) Historial de actividad
-- ──────────────────────────────────────────────
DROP POLICY IF EXISTS "historial_select_auth" ON historial_actividad;
CREATE POLICY "historial_select_auth" ON historial_actividad FOR SELECT
  USING (fn_get_user_role() = 'administrador');

DROP POLICY IF EXISTS "historial_insert_auth" ON historial_actividad;
CREATE POLICY "historial_insert_auth" ON historial_actividad FOR INSERT
  WITH CHECK (fn_get_user_role() IS NOT NULL);


NOTIFY pgrst, 'reload schema';

-- Para revisar al correrlo: cuántos costos se mudaron y que la tienda ya no los ve.
SELECT
  (SELECT count(*) FROM producto_costos)                                   AS costos_guardados_aparte,
  (SELECT count(*) FROM productos WHERE precio_costo IS NOT NULL
                                     OR proveedor IS NOT NULL)             AS costos_que_quedan_a_la_vista;
