-- ============================================================
-- 021 — IMPORTAR ARTÍCULOS DEL SISTEMA ANTERIOR (2026-11-11)
-- Ejecutar en Supabase → SQL Editor, DESPUÉS del 020.
-- Idempotente: se puede correr más de una vez sin romper nada.
--
-- Para pasar el catálogo del sistema viejo (listado "Stock de Artículos")
-- y, más adelante, su lista de precios. La pantalla es Admin → Importar
-- artículos (admin/importar.html): lee el archivo EN EL NAVEGADOR, muestra
-- una vista previa (categorías, marcas, posibles duplicados) y recién ahí
-- manda los artículos de a tandas a productos_importar().
--
-- Reglas:
--   • Cada artículo se identifica por su código del sistema viejo
--     (productos.codigo_anterior). Importar dos veces el mismo archivo no
--     duplica: la segunda vez actualiza.
--   • Un artículo se puede VINCULAR a un producto que ya existe en la web
--     (el mismo producto con otro nombre): no se crea otro.
--   • Los productos nuevos entran INACTIVOS (no se ven en la tienda hasta
--     tener precio y foto) y con el stock como REFERENCIA, sin contar: no
--     frenan ventas y se pasan a "controlado" al contarlos en el local.
--     Negativos → 0. Se pueden vender en el local desde el primer día.
--   • A un producto que ya existía no se le cambia el nombre, el estado
--     ni un stock ya contado; sí se completa lo que le falte (marca,
--     categoría) y el precio si el archivo lo trae.
-- ============================================================

ALTER TABLE productos ADD COLUMN IF NOT EXISTS codigo_anterior TEXT
  CHECK (codigo_anterior IS NULL OR length(btrim(codigo_anterior)) BETWEEN 1 AND 40);
CREATE UNIQUE INDEX IF NOT EXISTS uq_productos_codigo_anterior
  ON productos (lower(btrim(codigo_anterior))) WHERE codigo_anterior IS NOT NULL;


-- Números como vienen en planillas argentinas: "249.999,50", "38000", "1.200", "$ 15.000"
CREATE OR REPLACE FUNCTION fn_importar_num(p TEXT)
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE s TEXT := regexp_replace(coalesce(p, ''), '[\s$]', '', 'g');
BEGIN
  IF s = '' THEN RETURN NULL; END IF;
  IF s LIKE '%,%' THEN s := replace(replace(s, '.', ''), ',', '.');
  ELSIF s ~ '^-?\d{1,3}(\.\d{3})+$' THEN s := replace(s, '.', '');
  END IF;
  RETURN s::numeric;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$$;

-- p: { items: [ { codigo*, nombre*, marca, proveedor, categoria_id, stock, precio,
--                 vincular_producto_id } ] }   (hasta 200 por llamada)
-- Devuelve por renglón: accion = creado | actualizado | vinculado | error.
CREATE OR REPLACE FUNCTION productos_importar(p JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_items  JSONB := coalesce(p->'items', '[]'::jsonb);
  v_it     JSONB;
  v_cod    TEXT;
  v_nom    TEXT;
  v_prod   productos%ROWTYPE;
  v_id     INT;
  v_vinc   INT;
  v_stock  INT;
  v_precio NUMERIC(12,2);
  v_cat    INT;
  v_sku    TEXT;
  v_acc    TEXT;
  v_out    JSONB := '[]'::jsonb;
  v_c      INT := 0; v_a INT := 0; v_v INT := 0; v_e INT := 0;
  v_err    TEXT;
  v_hint   TEXT;
BEGIN
  IF NOT fn_tiene_permiso('productos.editar') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede crear ni editar productos.';
  END IF;
  IF jsonb_typeof(v_items) <> 'array' OR jsonb_array_length(v_items) = 0 OR jsonb_array_length(v_items) > 200 THEN
    RAISE EXCEPTION 'items_invalidos' USING HINT = 'Mandá entre 1 y 200 artículos por vez.';
  END IF;

  FOR v_it IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_cod := nullif(left(btrim(coalesce(v_it->>'codigo', '')), 40), '');
    v_nom := left(btrim(regexp_replace(coalesce(v_it->>'nombre', ''), '\s+', ' ', 'g')), 200);
    BEGIN
      IF v_cod IS NULL THEN RAISE EXCEPTION 'codigo_requerido' USING HINT = 'Falta el código.'; END IF;
      v_stock  := greatest(coalesce(round(fn_importar_num(v_it->>'stock'))::int, 0), 0);
      v_precio := round(fn_importar_num(v_it->>'precio'), 2);
      IF v_precio IS NOT NULL AND v_precio <= 0 THEN v_precio := NULL; END IF;
      v_cat    := nullif(v_it->>'categoria_id', '')::int;
      IF v_cat IS NOT NULL AND NOT EXISTS (SELECT 1 FROM categorias WHERE id = v_cat) THEN v_cat := NULL; END IF;
      v_vinc   := nullif(v_it->>'vincular_producto_id', '')::int;

      -- ¿Ya existe? Primero el vínculo elegido, después el código anterior
      v_prod := NULL;
      IF v_vinc IS NOT NULL THEN
        SELECT * INTO v_prod FROM productos WHERE id = v_vinc FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'producto_no_encontrado' USING HINT = 'El producto a vincular ya no existe.'; END IF;
        IF v_prod.codigo_anterior IS NOT NULL AND lower(btrim(v_prod.codigo_anterior)) <> lower(v_cod) THEN
          RAISE EXCEPTION 'ya_vinculado' USING HINT = format('%s ya está vinculado al código %s.', v_prod.nombre, v_prod.codigo_anterior);
        END IF;
      ELSE
        SELECT * INTO v_prod FROM productos WHERE lower(btrim(codigo_anterior)) = lower(v_cod) FOR UPDATE;
      END IF;

      IF v_prod.id IS NULL THEN
        -- Nuevo: SKU = código viejo si está libre; si no, MH-xxxxx
        IF length(v_nom) < 2 THEN RAISE EXCEPTION 'nombre_invalido' USING HINT = 'Falta la descripción.'; END IF;
        v_sku := CASE WHEN EXISTS (SELECT 1 FROM productos WHERE lower(sku) = lower(v_cod)) THEN NULL ELSE v_cod END;
        v_id := fn_producto_crear_basico(jsonb_build_object(
                  'nombre', v_nom, 'sku', v_sku, 'categoria_id', v_cat,
                  'marca', v_it->>'marca', 'proveedor', v_it->>'proveedor',
                  'precio_minorista', v_precio, 'estado', 'inactivo'));
        UPDATE productos SET codigo_anterior = v_cod WHERE id = v_id;
        v_acc := 'creado'; v_c := v_c + 1;
      ELSE
        v_id := v_prod.id;
        UPDATE productos SET
          codigo_anterior  = v_cod,
          marca            = coalesce(marca, nullif(left(btrim(coalesce(v_it->>'marca', '')), 80), '')),
          categoria_id     = coalesce(categoria_id, v_cat),
          precio_minorista = coalesce(v_precio, precio_minorista),
          updated_by       = auth.uid()
        WHERE id = v_id;
        IF nullif(btrim(coalesce(v_it->>'proveedor', '')), '') IS NOT NULL THEN
          INSERT INTO producto_costos (producto_id, proveedor) VALUES (v_id, left(btrim(v_it->>'proveedor'), 200))
          ON CONFLICT (producto_id) DO UPDATE SET proveedor = coalesce(producto_costos.proveedor, EXCLUDED.proveedor);
        END IF;
        IF v_vinc IS NOT NULL AND v_prod.codigo_anterior IS NULL THEN
          v_acc := 'vinculado'; v_v := v_v + 1;
        ELSE
          v_acc := 'actualizado'; v_a := v_a + 1;
        END IF;
      END IF;

      -- Stock de referencia: solo en productos sin contar y que estén en 0
      SELECT * INTO v_prod FROM productos WHERE id = v_id;
      IF v_stock > 0 AND NOT v_prod.stock_controlado AND v_prod.stock_actual = 0 THEN
        PERFORM set_config('mh.interno', '1', true);
        PERFORM fn_registrar_movimiento(v_id, 'carga_inicial', v_stock, 'Stock del sistema anterior',
                                        'Importación: referencia, sin contar', v_cod, false);
        PERFORM set_config('mh.interno', '', true);
      END IF;

      v_out := v_out || jsonb_build_object('codigo', v_cod, 'accion', v_acc, 'producto_id', v_id,
                                           'sku', (SELECT sku FROM productos WHERE id = v_id));
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT;
      v_err := SQLERRM; v_e := v_e + 1;
      v_out := v_out || jsonb_build_object('codigo', v_cod, 'accion', 'error', 'error', v_err, 'detalle', coalesce(v_hint, ''));
    END;
  END LOOP;

  INSERT INTO historial_actividad (accion, entidad, entidad_id, descripcion, usuario_id)
  VALUES ('importar', 'productos', NULL,
          format('Importación de artículos: %s nuevos, %s actualizados, %s vinculados, %s con error', v_c, v_a, v_v, v_e),
          auth.uid());

  RETURN jsonb_build_object('ok', v_e = 0, 'creados', v_c, 'actualizados', v_a, 'vinculados', v_v,
                            'errores', v_e, 'items', v_out);
END;
$$;
REVOKE ALL ON FUNCTION productos_importar(JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION productos_importar(JSONB) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT count(*) FILTER (WHERE codigo_anterior IS NOT NULL) AS productos_con_codigo_anterior FROM productos;
