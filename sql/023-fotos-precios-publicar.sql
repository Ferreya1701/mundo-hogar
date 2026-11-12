-- ============================================================
-- 023 — FOTOS, PRECIOS EN MASA Y PUBLICAR SOLO LO COMPLETO (2026-11-12)
-- Ejecutar en Supabase → SQL Editor, DESPUÉS del 022.
-- Idempotente: se puede correr más de una vez sin romper nada.
--
-- Para la pantalla "Completar productos" y la ficha simplificada:
--   1) Fotos: subir, reemplazar y borrar con el permiso "Crear y editar
--      productos" (antes: solo administrador y encargado por rol, y borrar
--      solo el administrador). Varias fotos por producto, con una
--      principal (la que se ve en la tienda y en el panel).
--   2) producto_fotos_guardar(producto, [urls]): deja la galería del
--      producto exactamente así, en ese orden; la primera es la principal.
--   3) productos_precio_masivo(): cambia precios de muchos productos en
--      UNA operación: porcentaje, sumar un monto o fijar un precio (sirve
--      para poner precio a los que no tienen). Redondeo opcional. Si una
--      oferta queda igual o más cara que el precio nuevo, se apaga.
--   4) productos_publicar(): publica SOLO los que tienen precio, foto y
--      categoría; devuelve cuáles no y por qué. Ocultar no pide nada.
-- ============================================================


-- ──────────────────────────────────────────────
-- 1) Permisos de fotos (Storage + tabla de galería)
-- ──────────────────────────────────────────────
DO $$
BEGIN
  IF to_regclass('storage.objects') IS NOT NULL THEN
    EXECUTE 'DROP POLICY IF EXISTS "imagenes_subida_staff" ON storage.objects';
    EXECUTE $p$CREATE POLICY "imagenes_subida_staff" ON storage.objects FOR INSERT
      WITH CHECK (bucket_id = 'producto-imagenes' AND fn_tiene_permiso('productos.editar'))$p$;
    EXECUTE 'DROP POLICY IF EXISTS "imagenes_actualizar_staff" ON storage.objects';
    EXECUTE $p$CREATE POLICY "imagenes_actualizar_staff" ON storage.objects FOR UPDATE
      USING (bucket_id = 'producto-imagenes' AND fn_tiene_permiso('productos.editar'))$p$;
    EXECUTE 'DROP POLICY IF EXISTS "imagenes_borrar_admin" ON storage.objects';
    EXECUTE $p$CREATE POLICY "imagenes_borrar_admin" ON storage.objects FOR DELETE
      USING (bucket_id = 'producto-imagenes' AND fn_tiene_permiso('productos.editar'))$p$;
  END IF;
END $$;

DROP POLICY IF EXISTS "imagenes_delete_admin" ON producto_imagenes;
CREATE POLICY "imagenes_delete_admin" ON producto_imagenes FOR DELETE
  USING (fn_tiene_permiso('productos.editar'));


-- ──────────────────────────────────────────────
-- 2) Galería de un producto
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION producto_fotos_guardar(p_producto_id INT, p_urls TEXT[])
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_urls TEXT[] := ARRAY(SELECT u FROM unnest(coalesce(p_urls, ARRAY[]::TEXT[])) WITH ORDINALITY AS t(u, i)
                         WHERE nullif(btrim(u), '') IS NOT NULL ORDER BY i);
  v_nom  TEXT;
BEGIN
  IF NOT fn_tiene_permiso('productos.editar') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede cambiar fotos de productos.';
  END IF;
  IF cardinality(v_urls) > 12 THEN
    RAISE EXCEPTION 'demasiadas_fotos' USING HINT = 'Hasta 12 fotos por producto.';
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_urls) u WHERE u !~ '^https?://' OR length(u) > 600) THEN
    RAISE EXCEPTION 'url_invalida' USING HINT = 'Alguna foto no tiene una dirección válida.';
  END IF;
  SELECT nombre INTO v_nom FROM productos WHERE id = p_producto_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'producto_no_encontrado'; END IF;

  DELETE FROM producto_imagenes WHERE producto_id = p_producto_id;
  INSERT INTO producto_imagenes (producto_id, url, alt, es_principal, orden)
  SELECT p_producto_id, u, v_nom, i = 1, i - 1
  FROM unnest(v_urls) WITH ORDINALITY AS t(u, i);

  UPDATE productos SET imagen_principal_url = v_urls[1], updated_by = auth.uid() WHERE id = p_producto_id;

  RETURN jsonb_build_object('ok', true, 'producto_id', p_producto_id, 'fotos', cardinality(v_urls),
                            'principal', v_urls[1]);
END;
$$;


-- ──────────────────────────────────────────────
-- 3) Precios en masa
-- ──────────────────────────────────────────────
-- p: { ids: [..], modo: 'porcentaje'|'sumar'|'fijar', valor, redondeo: 0|10|50|100|500|1000 }
--   porcentaje / sumar: solo a los que YA tienen precio.
--   fijar: a todos los elegidos (para poner el primer precio).
CREATE OR REPLACE FUNCTION productos_precio_masivo(p JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_ids    INT[];
  v_modo   TEXT := p->>'modo';
  v_valor  NUMERIC;
  v_red    INT := coalesce(nullif(p->>'redondeo', '')::int, 0);
  v_n      INT;
  v_salt   INT;
  v_ofer   INT;
BEGIN
  IF NOT fn_tiene_permiso('productos.editar') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede cambiar precios.';
  END IF;
  v_ids := ARRAY(SELECT DISTINCT (jsonb_array_elements_text(p->'ids'))::int);
  IF cardinality(v_ids) = 0 OR cardinality(v_ids) > 5000 THEN
    RAISE EXCEPTION 'seleccion_invalida' USING HINT = 'Elegí entre 1 y 5000 productos.';
  END IF;
  IF v_modo NOT IN ('porcentaje', 'sumar', 'fijar') THEN RAISE EXCEPTION 'modo_invalido'; END IF;
  v_valor := fn_importar_num(p->>'valor');
  IF v_valor IS NULL OR (v_modo = 'fijar' AND v_valor <= 0) OR (v_modo = 'porcentaje' AND v_valor <= -100)
     OR abs(v_valor) > 100000000 THEN
    RAISE EXCEPTION 'valor_invalido' USING HINT = 'Revisá el número.';
  END IF;
  IF v_red NOT IN (0, 10, 50, 100, 500, 1000) THEN v_red := 0; END IF;

  DROP TABLE IF EXISTS _nuevos;
  CREATE TEMP TABLE _nuevos ON COMMIT DROP AS
  SELECT id, precio_minorista AS antes,
         CASE v_modo
           WHEN 'fijar'      THEN v_valor
           WHEN 'sumar'      THEN precio_minorista + v_valor
           ELSE                   precio_minorista * (1 + v_valor / 100)
         END AS nuevo
  FROM productos
  WHERE id = ANY (v_ids) AND (v_modo = 'fijar' OR coalesce(precio_minorista, 0) > 0);

  UPDATE _nuevos SET nuevo = CASE WHEN v_red > 0 THEN round(nuevo / v_red) * v_red ELSE round(nuevo, 2) END;
  DELETE FROM _nuevos WHERE nuevo <= 0;

  -- Ofertas que quedarían iguales o más caras que el precio nuevo: se apagan
  UPDATE productos pr SET en_oferta = false
  FROM _nuevos n WHERE pr.id = n.id AND pr.en_oferta AND coalesce(pr.precio_oferta, 0) >= n.nuevo;
  GET DIAGNOSTICS v_ofer = ROW_COUNT;

  UPDATE productos pr SET precio_minorista = n.nuevo, updated_by = auth.uid()
  FROM _nuevos n WHERE pr.id = n.id AND pr.precio_minorista IS DISTINCT FROM n.nuevo;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_salt := cardinality(v_ids) - (SELECT count(*) FROM _nuevos);

  INSERT INTO historial_actividad (accion, entidad, entidad_id, descripcion, usuario_id, valores_nuevos)
  VALUES ('actualizar', 'productos', NULL,
          format('Precios en masa (%s %s): %s cambiados, %s salteados', v_modo, v_valor, v_n, v_salt),
          auth.uid(), jsonb_build_object('modo', v_modo, 'valor', v_valor, 'redondeo', v_red,
                                         'cambios', (SELECT jsonb_agg(jsonb_build_object('id', id, 'antes', antes, 'nuevo', nuevo)) FROM _nuevos)));

  RETURN jsonb_build_object('ok', true, 'cambiados', v_n, 'salteados', v_salt, 'ofertas_apagadas', v_ofer);
END;
$$;


-- ──────────────────────────────────────────────
-- 4) Publicar solo lo completo
-- ──────────────────────────────────────────────
-- p_publicar = true: activa los que tienen precio, foto y categoría; el resto
-- vuelve en "faltan" con el motivo. false: oculta (inactivo) sin condiciones.
CREATE OR REPLACE FUNCTION productos_publicar(p_ids INT[], p_publicar BOOLEAN)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_n      INT;
  v_faltan JSONB;
BEGIN
  IF NOT fn_tiene_permiso('productos.editar') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede publicar ni ocultar productos.';
  END IF;
  IF p_ids IS NULL OR cardinality(p_ids) = 0 OR cardinality(p_ids) > 5000 THEN
    RAISE EXCEPTION 'seleccion_invalida' USING HINT = 'Elegí entre 1 y 5000 productos.';
  END IF;

  IF NOT p_publicar THEN
    UPDATE productos SET estado = 'inactivo', updated_by = auth.uid()
    WHERE id = ANY (p_ids) AND estado = 'activo';
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN jsonb_build_object('ok', true, 'ocultados', v_n);
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'nombre', nombre, 'falta',
           array_remove(ARRAY[
             CASE WHEN coalesce(precio_minorista, 0) <= 0 THEN 'precio' END,
             CASE WHEN nullif(btrim(coalesce(imagen_principal_url, '')), '') IS NULL THEN 'foto' END,
             CASE WHEN categoria_id IS NULL THEN 'categoría' END], NULL)) ORDER BY nombre), '[]'::jsonb)
    INTO v_faltan
  FROM productos
  WHERE id = ANY (p_ids) AND estado <> 'archivado'
    AND (coalesce(precio_minorista, 0) <= 0 OR nullif(btrim(coalesce(imagen_principal_url, '')), '') IS NULL OR categoria_id IS NULL);

  UPDATE productos SET estado = 'activo', updated_by = auth.uid()
  WHERE id = ANY (p_ids) AND estado = 'inactivo'
    AND coalesce(precio_minorista, 0) > 0
    AND nullif(btrim(coalesce(imagen_principal_url, '')), '') IS NOT NULL
    AND categoria_id IS NOT NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  IF v_n > 0 THEN
    INSERT INTO historial_actividad (accion, entidad, entidad_id, descripcion, usuario_id)
    VALUES ('actualizar', 'productos', NULL, format('Publicó %s productos', v_n), auth.uid());
  END IF;

  RETURN jsonb_build_object('ok', true, 'publicados', v_n, 'faltan', v_faltan);
END;
$$;

REVOKE ALL ON FUNCTION producto_fotos_guardar(INT, TEXT[])  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION productos_precio_masivo(JSONB)        FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION productos_publicar(INT[], BOOLEAN)    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION producto_fotos_guardar(INT, TEXT[]) TO authenticated;
GRANT EXECUTE ON FUNCTION productos_precio_masivo(JSONB)      TO authenticated;
GRANT EXECUTE ON FUNCTION productos_publicar(INT[], BOOLEAN)  TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT (SELECT count(*) FROM productos WHERE estado = 'inactivo' AND coalesce(precio_minorista, 0) <= 0) AS inactivos_sin_precio,
       (SELECT count(*) FROM productos WHERE estado = 'inactivo' AND imagen_principal_url IS NULL)       AS inactivos_sin_foto;
