-- ============================================================
-- 031 — FOTOS PARA REVISAR (placas del Drive) (2026-11-12)
-- Ejecutar DESPUÉS del 023 (usa producto_fotos_guardar). Idempotente.
--
-- Las placas de Canva del Drive ("Catálogo Revendedor") traen la foto del
-- producto con texto encima. Un script (scripts/cargar-fotos-placas.mjs)
-- recorta la foto, lee el título y sugiere a qué producto corresponde.
-- Acá queda cada foto ESPERANDO que una persona confirme:
--
--   • Nada se publica solo: la foto llega al producto recién cuando alguien
--     con permiso de editar productos toca "Es este".
--   • Se puede descartar (foto mala, producto que ya no se vende) y deshacer
--     cualquiera de las dos cosas.
--   • La tabla no se toca a mano desde el panel: solo con estas funciones.
-- ============================================================

CREATE TABLE IF NOT EXISTS fotos_sugeridas (
  id           TEXT PRIMARY KEY,                   -- huella del archivo original
  url          TEXT NOT NULL,                      -- la foto recortada (lo que se publica)
  placa_url    TEXT,                               -- la placa entera, para ver de dónde salió
  carpeta      TEXT,                               -- rubro de la carpeta del Drive
  titulo       TEXT,                               -- lo que dice la placa (leído por OCR)
  ficha        TEXT,
  nivel        TEXT NOT NULL DEFAULT 'dudoso'
               CHECK (nivel IN ('seguro', 'probable', 'dudoso', 'sin_match', 'sin_texto')),
  candidatos   JSONB NOT NULL DEFAULT '[]'::jsonb, -- [{id, nombre, puntos}] el primero es la sugerencia
  estado       TEXT NOT NULL DEFAULT 'pendiente'
               CHECK (estado IN ('pendiente', 'asignada', 'descartada')),
  producto_id  INT REFERENCES productos(id) ON DELETE SET NULL,
  revisada_por UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  revisada_en  TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS fotos_sugeridas_estado_idx ON fotos_sugeridas (estado, nivel);

ALTER TABLE fotos_sugeridas ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "fotos_sugeridas_ver" ON fotos_sugeridas;
CREATE POLICY "fotos_sugeridas_ver" ON fotos_sugeridas FOR SELECT
  USING (fn_tiene_permiso('productos.editar'));
REVOKE INSERT, UPDATE, DELETE ON fotos_sugeridas FROM anon, authenticated;


-- Asignar: la foto pasa a la galería del producto (al principio si
-- p_principal o si el producto no tenía fotos; si no, al final).
CREATE OR REPLACE FUNCTION foto_sugerida_asignar(p_id TEXT, p_producto_id INT, p_principal BOOLEAN DEFAULT false)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  f      fotos_sugeridas;
  v_urls TEXT[];
BEGIN
  IF NOT fn_tiene_permiso('productos.editar') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede cambiar fotos de productos.';
  END IF;
  SELECT * INTO f FROM fotos_sugeridas WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'foto_no_encontrada'; END IF;
  IF f.estado <> 'pendiente' THEN
    RAISE EXCEPTION 'ya_revisada' USING HINT = 'Otra persona ya revisó esta foto.';
  END IF;
  PERFORM 1 FROM productos WHERE id = p_producto_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'producto_no_encontrado'; END IF;

  v_urls := ARRAY(SELECT url FROM producto_imagenes WHERE producto_id = p_producto_id ORDER BY orden, id);
  IF NOT f.url = ANY (v_urls) THEN
    IF cardinality(v_urls) >= 12 THEN
      RAISE EXCEPTION 'demasiadas_fotos' USING HINT = 'Ese producto ya tiene 12 fotos.';
    END IF;
    v_urls := CASE WHEN p_principal OR cardinality(v_urls) = 0 THEN f.url || v_urls ELSE v_urls || f.url END;
    PERFORM producto_fotos_guardar(p_producto_id, v_urls);
  END IF;

  UPDATE fotos_sugeridas SET estado = 'asignada', producto_id = p_producto_id,
         revisada_por = auth.uid(), revisada_en = now() WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'producto_id', p_producto_id, 'principal', v_urls[1] = f.url,
                            'fotos', cardinality(v_urls));
END;
$$;

CREATE OR REPLACE FUNCTION foto_sugerida_descartar(p_id TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT fn_tiene_permiso('productos.editar') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede cambiar fotos de productos.';
  END IF;
  UPDATE fotos_sugeridas SET estado = 'descartada', producto_id = NULL,
         revisada_por = auth.uid(), revisada_en = now()
   WHERE id = p_id AND estado = 'pendiente';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ya_revisada' USING HINT = 'Otra persona ya revisó esta foto.';
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- Deshacer: vuelve a "pendiente". Si estaba asignada, la saca de la galería
-- del producto (las demás fotos quedan como estaban).
CREATE OR REPLACE FUNCTION foto_sugerida_deshacer(p_id TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  f      fotos_sugeridas;
  v_urls TEXT[];
BEGIN
  IF NOT fn_tiene_permiso('productos.editar') THEN
    RAISE EXCEPTION 'sin_permiso' USING HINT = 'Tu usuario no puede cambiar fotos de productos.';
  END IF;
  SELECT * INTO f FROM fotos_sugeridas WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'foto_no_encontrada'; END IF;
  IF f.estado = 'asignada' AND f.producto_id IS NOT NULL THEN
    v_urls := ARRAY(SELECT url FROM producto_imagenes WHERE producto_id = f.producto_id ORDER BY orden, id);
    IF f.url = ANY (v_urls) THEN
      PERFORM producto_fotos_guardar(f.producto_id, array_remove(v_urls, f.url));
    END IF;
  END IF;
  UPDATE fotos_sugeridas SET estado = 'pendiente', producto_id = NULL, revisada_por = NULL, revisada_en = NULL
   WHERE id = p_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE EXECUTE ON FUNCTION foto_sugerida_asignar(TEXT, INT, BOOLEAN), foto_sugerida_descartar(TEXT),
                           foto_sugerida_deshacer(TEXT) FROM anon;
