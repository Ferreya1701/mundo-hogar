-- ============================================================
-- MUNDO HOGAR — SETUP COMPLETO DE SUPABASE (un solo archivo)
-- Generado: 2026-06-30 03:27:17
-- Cómo usarlo: Supabase → SQL Editor → New query → pegar TODO → Run.
-- Es re-ejecutable (no borra ni duplica datos).
-- Después de correrlo: crear el usuario admin (ver SUPABASE_SETUP.md).
-- ============================================================



-- ============================================================
-- LIMPIEZA SEGURA de un intento anterior (esquema en inglés, vacío).
-- Solo actúa si detecta el 'profiles' viejo (columna full_name).
-- En un re-run normal (nuestro profiles usa 'nombre') NO hace nada.
-- ============================================================
DO $LIMPIEZA$
DECLARE r RECORD;
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
            WHERE table_schema='public' AND table_name='profiles' AND column_name='full_name') THEN
    -- quitar disparadores personalizados sobre auth.users del intento anterior
    FOR r IN SELECT tgname FROM pg_trigger
             WHERE tgrelid='auth.users'::regclass AND NOT tgisinternal LOOP
      EXECUTE format('DROP TRIGGER IF EXISTS %I ON auth.users', r.tgname);
    END LOOP;
    -- quitar el profiles viejo (estaba vacío) para recrearlo con nuestra estructura
    DROP TABLE IF EXISTS public.profiles CASCADE;
  END IF;
END
$LIMPIEZA$;

-- ============================================================
-- Mundo Hogar — Esquema de base de datos v1.0
-- Ejecutar en: Supabase Dashboard → SQL Editor
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ──────────────────────────────────────────────
-- PERFILES (extiende auth.users de Supabase)
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS profiles (
  id              UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  nombre          TEXT NOT NULL,
  email           TEXT,
  rol             TEXT NOT NULL DEFAULT 'vendedor'
                    CHECK (rol IN ('administrador', 'encargado_stock', 'vendedor')),
  activo          BOOLEAN NOT NULL DEFAULT true,
  avatar_url      TEXT,
  ultimo_acceso   TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ──────────────────────────────────────────────
-- CATEGORÍAS
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS categorias (
  id          SERIAL PRIMARY KEY,
  nombre      TEXT NOT NULL,
  slug        TEXT NOT NULL UNIQUE,
  descripcion TEXT,
  imagen_url  TEXT,
  activo      BOOLEAN NOT NULL DEFAULT true,
  orden       INT NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ──────────────────────────────────────────────
-- SUBCATEGORÍAS
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS subcategorias (
  id           SERIAL PRIMARY KEY,
  categoria_id INT NOT NULL REFERENCES categorias(id) ON DELETE RESTRICT,
  nombre       TEXT NOT NULL,
  slug         TEXT NOT NULL,
  descripcion  TEXT,
  activo       BOOLEAN NOT NULL DEFAULT true,
  orden        INT NOT NULL DEFAULT 0,
  UNIQUE(categoria_id, slug)
);

-- ──────────────────────────────────────────────
-- PRODUCTOS
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS productos (
  id                        SERIAL PRIMARY KEY,
  sku                       TEXT UNIQUE,
  codigo_barras             TEXT,
  nombre                    TEXT NOT NULL,
  slug                      TEXT UNIQUE,
  descripcion_corta         TEXT,
  descripcion               TEXT,
  categoria_id              INT REFERENCES categorias(id) ON DELETE SET NULL,
  subcategoria_id           INT REFERENCES subcategorias(id) ON DELETE SET NULL,
  marca                     TEXT,
  precio_costo              NUMERIC(12,2),
  precio_minorista          NUMERIC(12,2),
  precio_mayorista          NUMERIC(12,2),
  precio_oferta             NUMERIC(12,2),
  en_oferta                 BOOLEAN NOT NULL DEFAULT false,
  stock_actual              INT NOT NULL DEFAULT 0,
  stock_minimo              INT NOT NULL DEFAULT 0,
  unidad                    TEXT NOT NULL DEFAULT 'unidad',
  ubicacion                 TEXT,
  proveedor                 TEXT,
  permite_venta_sin_stock   BOOLEAN NOT NULL DEFAULT false,
  seguimiento_inventario    BOOLEAN NOT NULL DEFAULT true,
  estado                    TEXT NOT NULL DEFAULT 'activo'
                              CHECK (estado IN ('activo', 'inactivo', 'archivado')),
  destacado                 BOOLEAN NOT NULL DEFAULT false,
  es_nuevo                  BOOLEAN NOT NULL DEFAULT false,
  peso                      NUMERIC(10,3),
  alto                      NUMERIC(10,2),
  ancho                     NUMERIC(10,2),
  profundidad               NUMERIC(10,2),
  material                  TEXT,
  color                     TEXT,
  garantia                  TEXT,
  etiquetas                 TEXT[] DEFAULT '{}',
  observaciones             TEXT,
  imagen_principal_url      TEXT,
  created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by                UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_by                UUID REFERENCES auth.users(id) ON DELETE SET NULL
);

-- ──────────────────────────────────────────────
-- IMÁGENES DE PRODUCTOS
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS producto_imagenes (
  id           SERIAL PRIMARY KEY,
  producto_id  INT NOT NULL REFERENCES productos(id) ON DELETE CASCADE,
  url          TEXT NOT NULL,
  alt          TEXT,
  es_principal BOOLEAN NOT NULL DEFAULT false,
  orden        INT NOT NULL DEFAULT 0,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ──────────────────────────────────────────────
-- MOVIMIENTOS DE INVENTARIO
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS movimientos_inventario (
  id              SERIAL PRIMARY KEY,
  producto_id     INT NOT NULL REFERENCES productos(id) ON DELETE RESTRICT,
  tipo            TEXT NOT NULL CHECK (tipo IN (
                    'carga_inicial', 'entrada_compra', 'salida_venta',
                    'ajuste_positivo', 'ajuste_negativo',
                    'devolucion_cliente', 'devolucion_proveedor',
                    'producto_danado', 'perdida', 'transferencia', 'correccion'
                  )),
  cantidad        INT NOT NULL,
  stock_anterior  INT NOT NULL,
  stock_posterior INT NOT NULL,
  motivo          TEXT,
  observacion     TEXT,
  referencia      TEXT,
  usuario_id      UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ──────────────────────────────────────────────
-- HISTORIAL DE ACTIVIDAD (auditoría)
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS historial_actividad (
  id                  SERIAL PRIMARY KEY,
  accion              TEXT NOT NULL,
  entidad             TEXT,
  entidad_id          TEXT,
  descripcion         TEXT,
  valores_anteriores  JSONB,
  valores_nuevos      JSONB,
  usuario_id          UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ──────────────────────────────────────────────
-- ÍNDICES
-- ──────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_productos_categoria  ON productos(categoria_id);
CREATE INDEX IF NOT EXISTS idx_productos_estado     ON productos(estado);
CREATE INDEX IF NOT EXISTS idx_productos_sku        ON productos(sku) WHERE sku IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_mov_producto         ON movimientos_inventario(producto_id);
CREATE INDEX IF NOT EXISTS idx_mov_created          ON movimientos_inventario(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_hist_usuario         ON historial_actividad(usuario_id);
CREATE INDEX IF NOT EXISTS idx_hist_created         ON historial_actividad(created_at DESC);

-- ──────────────────────────────────────────────
-- FUNCIÓN: updated_at automático
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER tr_productos_updated_at
  BEFORE UPDATE ON productos FOR EACH ROW EXECUTE FUNCTION fn_updated_at();
CREATE OR REPLACE TRIGGER tr_categorias_updated_at
  BEFORE UPDATE ON categorias FOR EACH ROW EXECUTE FUNCTION fn_updated_at();
CREATE OR REPLACE TRIGGER tr_profiles_updated_at
  BEFORE UPDATE ON profiles FOR EACH ROW EXECUTE FUNCTION fn_updated_at();

-- ──────────────────────────────────────────────
-- FUNCIÓN: crear perfil automáticamente
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_create_profile()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO profiles (id, email, nombre, rol)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'nombre', split_part(NEW.email, '@', 1)),
    COALESCE(NEW.raw_user_meta_data->>'rol', 'vendedor')
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER tr_auth_user_created
  AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION fn_create_profile();

-- ──────────────────────────────────────────────
-- FUNCIÓN: obtener rol del usuario actual
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_get_user_role()
RETURNS TEXT LANGUAGE SQL STABLE SECURITY DEFINER AS $$
  SELECT rol FROM profiles WHERE id = auth.uid() AND activo = true;
$$;

-- ──────────────────────────────────────────────
-- FUNCIÓN: registrar movimiento y actualizar stock (transacción atómica)
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_registrar_movimiento(
  p_producto_id   INT,
  p_tipo          TEXT,
  p_cantidad      INT,
  p_motivo        TEXT DEFAULT NULL,
  p_observacion   TEXT DEFAULT NULL,
  p_referencia    TEXT DEFAULT NULL
)
RETURNS movimientos_inventario LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_stock_ant  INT;
  v_stock_new  INT;
  v_delta      INT;
  v_result     movimientos_inventario;
BEGIN
  SELECT stock_actual INTO v_stock_ant
  FROM productos WHERE id = p_producto_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Producto no encontrado: %', p_producto_id;
  END IF;

  -- Determinar delta (positivo = suma, negativo = resta)
  CASE p_tipo
    WHEN 'carga_inicial','entrada_compra','ajuste_positivo','devolucion_cliente'
      THEN v_delta :=  ABS(p_cantidad);
    WHEN 'salida_venta','ajuste_negativo','devolucion_proveedor','producto_danado','perdida'
      THEN v_delta := -ABS(p_cantidad);
    ELSE v_delta := p_cantidad; -- transferencia/correccion: valor firmado
  END CASE;

  v_stock_new := v_stock_ant + v_delta;

  IF v_stock_new < 0 THEN
    RAISE EXCEPTION 'Stock insuficiente. Actual: %, Movimiento: %', v_stock_ant, v_delta;
  END IF;

  UPDATE productos SET stock_actual = v_stock_new, updated_by = auth.uid()
  WHERE id = p_producto_id;

  INSERT INTO movimientos_inventario
    (producto_id, tipo, cantidad, stock_anterior, stock_posterior,
     motivo, observacion, referencia, usuario_id)
  VALUES
    (p_producto_id, p_tipo, ABS(p_cantidad), v_stock_ant, v_stock_new,
     p_motivo, p_observacion, p_referencia, auth.uid())
  RETURNING * INTO v_result;

  RETURN v_result;
END;
$$;


-- ============================================================
-- EXTENSIÓN: columnas extra de productos + tablas nuevas
-- ============================================================
ALTER TABLE productos ADD COLUMN IF NOT EXISTS orden                     INT NOT NULL DEFAULT 0;
ALTER TABLE productos ADD COLUMN IF NOT EXISTS mas_vendido               BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE productos ADD COLUMN IF NOT EXISTS disponible_minorista      BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE productos ADD COLUMN IF NOT EXISTS disponible_mayorista      BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE productos ADD COLUMN IF NOT EXISTS cantidad_minima_mayorista INT;
ALTER TABLE productos ADD COLUMN IF NOT EXISTS oferta_inicio             TIMESTAMPTZ;
ALTER TABLE productos ADD COLUMN IF NOT EXISTS oferta_fin                TIMESTAMPTZ;
ALTER TABLE productos ADD COLUMN IF NOT EXISTS descuento_porcentaje      INT;
CREATE INDEX IF NOT EXISTS idx_productos_destacado ON productos(destacado) WHERE destacado = true;
CREATE INDEX IF NOT EXISTS idx_productos_orden     ON productos(orden);

-- BANNERS
CREATE TABLE IF NOT EXISTS banners (
  id                  SERIAL PRIMARY KEY,
  titulo              TEXT,
  subtitulo           TEXT,
  imagen_desktop_url  TEXT,
  imagen_mobile_url   TEXT,
  texto_boton         TEXT,
  url_boton           TEXT,
  posicion            TEXT NOT NULL DEFAULT 'hero',
  alineacion          TEXT NOT NULL DEFAULT 'left',
  fondo               TEXT,
  orden               INT NOT NULL DEFAULT 0,
  activo              BOOLEAN NOT NULL DEFAULT true,
  inicia_en           TIMESTAMPTZ,
  termina_en          TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- CONTENIDO EDITABLE (textos del sitio): clave -> valor
CREATE TABLE IF NOT EXISTS site_content (
  id          SERIAL PRIMARY KEY,
  clave       TEXT NOT NULL UNIQUE,
  valor       TEXT,
  grupo       TEXT,
  etiqueta    TEXT,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- CONFIGURACIÓN GENERAL (una sola fila, id = 1)
CREATE TABLE IF NOT EXISTS site_settings (
  id                        INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  nombre_tienda             TEXT,
  whatsapp                  TEXT,
  telefono                  TEXT,
  email                     TEXT,
  direccion                 TEXT,
  horarios                  TEXT,
  redes                     JSONB NOT NULL DEFAULT '{}'::jsonb,
  moneda                    TEXT NOT NULL DEFAULT 'ARS',
  mensaje_promo             TEXT,
  compra_minima_mayorista   NUMERIC(12,2),
  envio_info                TEXT,
  modo_mantenimiento        BOOLEAN NOT NULL DEFAULT false,
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE TRIGGER tr_banners_updated_at      BEFORE UPDATE ON banners      FOR EACH ROW EXECUTE FUNCTION fn_updated_at();
CREATE OR REPLACE TRIGGER tr_site_content_updated_at BEFORE UPDATE ON site_content FOR EACH ROW EXECUTE FUNCTION fn_updated_at();
CREATE OR REPLACE TRIGGER tr_site_settings_updated_at BEFORE UPDATE ON site_settings FOR EACH ROW EXECUTE FUNCTION fn_updated_at();

-- ============================================================
-- Mundo Hogar — Row Level Security (RLS)
-- Ejecutar DESPUÉS de 001-schema.sql
-- ============================================================

-- Habilitar RLS en todas las tablas
ALTER TABLE profiles             ENABLE ROW LEVEL SECURITY;
ALTER TABLE categorias           ENABLE ROW LEVEL SECURITY;
ALTER TABLE subcategorias        ENABLE ROW LEVEL SECURITY;
ALTER TABLE productos            ENABLE ROW LEVEL SECURITY;
ALTER TABLE producto_imagenes    ENABLE ROW LEVEL SECURITY;
ALTER TABLE movimientos_inventario ENABLE ROW LEVEL SECURITY;
ALTER TABLE historial_actividad  ENABLE ROW LEVEL SECURITY;

-- ──────────────────────────────────────────────
-- PROFILES
-- ──────────────────────────────────────────────
DROP POLICY IF EXISTS "profiles_select_own" ON profiles;
CREATE POLICY "profiles_select_own" ON profiles FOR SELECT USING (id = auth.uid());

DROP POLICY IF EXISTS "profiles_select_admin" ON profiles;
CREATE POLICY "profiles_select_admin" ON profiles FOR SELECT USING (fn_get_user_role() = 'administrador');

DROP POLICY IF EXISTS "profiles_update_own" ON profiles;
CREATE POLICY "profiles_update_own" ON profiles FOR UPDATE USING (id = auth.uid());

DROP POLICY IF EXISTS "profiles_update_admin" ON profiles;
CREATE POLICY "profiles_update_admin" ON profiles FOR UPDATE USING (fn_get_user_role() = 'administrador');

DROP POLICY IF EXISTS "profiles_insert_admin" ON profiles;
CREATE POLICY "profiles_insert_admin" ON profiles FOR INSERT WITH CHECK (fn_get_user_role() = 'administrador');

-- ──────────────────────────────────────────────
-- CATEGORÍAS — lectura pública
-- ──────────────────────────────────────────────
DROP POLICY IF EXISTS "categorias_select_public" ON categorias;
CREATE POLICY "categorias_select_public" ON categorias FOR SELECT USING (true);

DROP POLICY IF EXISTS "categorias_insert_admin" ON categorias;
CREATE POLICY "categorias_insert_admin" ON categorias FOR INSERT WITH CHECK (fn_get_user_role() = 'administrador');

DROP POLICY IF EXISTS "categorias_update_admin" ON categorias;
CREATE POLICY "categorias_update_admin" ON categorias FOR UPDATE USING (fn_get_user_role() = 'administrador');

DROP POLICY IF EXISTS "categorias_delete_admin" ON categorias;
CREATE POLICY "categorias_delete_admin" ON categorias FOR DELETE USING (fn_get_user_role() = 'administrador');

-- ──────────────────────────────────────────────
-- SUBCATEGORÍAS — lectura pública
-- ──────────────────────────────────────────────
DROP POLICY IF EXISTS "subcategorias_select_public" ON subcategorias;
CREATE POLICY "subcategorias_select_public" ON subcategorias FOR SELECT USING (true);

DROP POLICY IF EXISTS "subcategorias_insert_admin" ON subcategorias;
CREATE POLICY "subcategorias_insert_admin" ON subcategorias FOR INSERT WITH CHECK (fn_get_user_role() = 'administrador');

DROP POLICY IF EXISTS "subcategorias_update_admin" ON subcategorias;
CREATE POLICY "subcategorias_update_admin" ON subcategorias FOR UPDATE USING (fn_get_user_role() = 'administrador');

DROP POLICY IF EXISTS "subcategorias_delete_admin" ON subcategorias;
CREATE POLICY "subcategorias_delete_admin" ON subcategorias FOR DELETE USING (fn_get_user_role() = 'administrador');

-- ──────────────────────────────────────────────
-- PRODUCTOS
--   - Público: sólo activos
--   - Autenticado: todos (admin/encargado pueden modificar)
-- ──────────────────────────────────────────────
DROP POLICY IF EXISTS "productos_select_public" ON productos;
CREATE POLICY "productos_select_public" ON productos FOR SELECT
  USING (estado = 'activo' OR auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "productos_insert_staff" ON productos;
CREATE POLICY "productos_insert_staff" ON productos FOR INSERT
  WITH CHECK (fn_get_user_role() IN ('administrador','encargado_stock'));

DROP POLICY IF EXISTS "productos_update_staff" ON productos;
CREATE POLICY "productos_update_staff" ON productos FOR UPDATE
  USING (fn_get_user_role() IN ('administrador','encargado_stock'));

DROP POLICY IF EXISTS "productos_delete_admin" ON productos;
CREATE POLICY "productos_delete_admin" ON productos FOR DELETE
  USING (fn_get_user_role() = 'administrador');

-- ──────────────────────────────────────────────
-- IMÁGENES DE PRODUCTOS — lectura pública
-- ──────────────────────────────────────────────
DROP POLICY IF EXISTS "imagenes_select_public" ON producto_imagenes;
CREATE POLICY "imagenes_select_public" ON producto_imagenes FOR SELECT USING (true);

DROP POLICY IF EXISTS "imagenes_insert_staff" ON producto_imagenes;
CREATE POLICY "imagenes_insert_staff" ON producto_imagenes FOR INSERT
  WITH CHECK (fn_get_user_role() IN ('administrador','encargado_stock'));

DROP POLICY IF EXISTS "imagenes_update_staff" ON producto_imagenes;
CREATE POLICY "imagenes_update_staff" ON producto_imagenes FOR UPDATE
  USING (fn_get_user_role() IN ('administrador','encargado_stock'));

DROP POLICY IF EXISTS "imagenes_delete_admin" ON producto_imagenes;
CREATE POLICY "imagenes_delete_admin" ON producto_imagenes FOR DELETE
  USING (fn_get_user_role() = 'administrador');

-- ──────────────────────────────────────────────
-- MOVIMIENTOS — sólo autenticados
-- (no se permiten UPDATE/DELETE: el historial es inmutable)
-- ──────────────────────────────────────────────
DROP POLICY IF EXISTS "movimientos_select_auth" ON movimientos_inventario;
CREATE POLICY "movimientos_select_auth" ON movimientos_inventario FOR SELECT
  USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "movimientos_insert_staff" ON movimientos_inventario;
CREATE POLICY "movimientos_insert_staff" ON movimientos_inventario FOR INSERT
  WITH CHECK (fn_get_user_role() IN ('administrador','encargado_stock'));

-- ──────────────────────────────────────────────
-- HISTORIAL — sólo autenticados
-- ──────────────────────────────────────────────
DROP POLICY IF EXISTS "historial_select_auth" ON historial_actividad;
CREATE POLICY "historial_select_auth" ON historial_actividad FOR SELECT
  USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "historial_insert_auth" ON historial_actividad;
CREATE POLICY "historial_insert_auth" ON historial_actividad FOR INSERT
  WITH CHECK (auth.uid() IS NOT NULL);


-- ============================================================
-- RLS de tablas nuevas (lectura pública / escritura admin)
-- ============================================================
ALTER TABLE banners       ENABLE ROW LEVEL SECURITY;
ALTER TABLE site_content  ENABLE ROW LEVEL SECURITY;
ALTER TABLE site_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "banners_select_public" ON banners;
CREATE POLICY "banners_select_public" ON banners FOR SELECT
  USING (activo = true OR auth.uid() IS NOT NULL);
DROP POLICY IF EXISTS "banners_write_admin" ON banners;
CREATE POLICY "banners_write_admin" ON banners FOR ALL
  USING (fn_get_user_role() = 'administrador')
  WITH CHECK (fn_get_user_role() = 'administrador');

DROP POLICY IF EXISTS "content_select_public" ON site_content;
CREATE POLICY "content_select_public" ON site_content FOR SELECT USING (true);
DROP POLICY IF EXISTS "content_write_admin" ON site_content;
CREATE POLICY "content_write_admin" ON site_content FOR ALL
  USING (fn_get_user_role() = 'administrador')
  WITH CHECK (fn_get_user_role() = 'administrador');

DROP POLICY IF EXISTS "settings_select_public" ON site_settings;
CREATE POLICY "settings_select_public" ON site_settings FOR SELECT USING (true);
DROP POLICY IF EXISTS "settings_write_admin" ON site_settings;
CREATE POLICY "settings_write_admin" ON site_settings FOR ALL
  USING (fn_get_user_role() = 'administrador')
  WITH CHECK (fn_get_user_role() = 'administrador');


-- ============================================================
-- BUCKETS DE STORAGE (carpetas de imágenes, públicas para lectura)
-- ============================================================
INSERT INTO storage.buckets (id, name, public) VALUES
  ('producto-imagenes','producto-imagenes', true),
  ('banners','banners', true),
  ('categorias','categorias', true)
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- Mundo Hogar — Políticas de Storage para imágenes
-- Ejecutar DESPUÉS de crear el bucket 'producto-imagenes' en
-- Supabase Dashboard → Storage → New bucket (Public = ON)
-- ============================================================

-- Lectura pública (cualquiera puede ver las imágenes)
DROP POLICY IF EXISTS "imagenes_publicas_lectura" ON storage.objects;
CREATE POLICY "imagenes_publicas_lectura" ON storage.objects FOR SELECT
  USING (bucket_id = 'producto-imagenes');

-- Solo usuarios autenticados con rol staff pueden subir
DROP POLICY IF EXISTS "imagenes_subida_staff" ON storage.objects;
CREATE POLICY "imagenes_subida_staff" ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'producto-imagenes'
    AND auth.uid() IS NOT NULL
    AND fn_get_user_role() IN ('administrador','encargado_stock')
  );

-- Solo admins pueden borrar imágenes
DROP POLICY IF EXISTS "imagenes_borrar_admin" ON storage.objects;
CREATE POLICY "imagenes_borrar_admin" ON storage.objects FOR DELETE
  USING (
    bucket_id = 'producto-imagenes'
    AND fn_get_user_role() = 'administrador'
  );


-- ============================================================
-- DATOS: categorías
-- ============================================================
INSERT INTO categorias (nombre, slug, activo, orden) VALUES
  ('Electrodomésticos',     'electrodomesticos',    true, 1),
  ('Herramientas',          'herramientas',          true, 2),
  ('Tecnología y Celulares','tecnologia-celulares',  true, 3),
  ('Muebles y Hogar',       'muebles-hogar',         true, 4),
  ('Cuidado Personal',      'cuidado-personal',      true, 5),
  ('Salud',                 'salud',                 true, 6),
  ('Seguridad',             'seguridad',             true, 7)
ON CONFLICT (slug) DO UPDATE SET nombre = EXCLUDED.nombre, orden = EXCLUDED.orden;


-- ============================================================
-- DATOS: productos (importados del catálogo actual, 140 items)
-- Re-ejecutable: ON CONFLICT (slug) DO NOTHING no pisa cambios del panel.
-- ============================================================
INSERT INTO productos (nombre, slug, descripcion, categoria_id, imagen_principal_url, estado, destacado, es_nuevo, orden)
SELECT v.nombre, v.slug, v.descripcion, c.id, v.imagen, v.estado, v.destacado, v.es_nuevo, v.orden
FROM (VALUES
  ('Rulero/rizador rosa fucsia doble barril','cuidado-personal-img_0065','Rizador de pelo doble barril en rosa fucsia. Crea ondas y rulos parejos de forma rápida y sencilla.','cuidado-personal','/images/productos/cuidado-personal/IMG_0065.jpg','activo',false,false,1),
  ('Secador de pelo Yelmo lila Thermal Ion','cuidado-personal-img_0314','Secador de pelo Yelmo Thermal Ion en lila. Tecnología iónica para un secado más rápido y con menos frizz.','cuidado-personal','/images/productos/cuidado-personal/IMG_0314.jpg','activo',false,false,2),
  ('Secador de pelo Yelmo negro/antracita','cuidado-personal-img_0316','Secador de pelo Yelmo en negro antracita. Potencia y varias temperaturas para un peinado profesional en casa.','cuidado-personal','/images/productos/cuidado-personal/IMG_0316.jpg','activo',false,false,3),
  ('Cepillo secador volumizador Westinghouse','cuidado-personal-img_0550','Cepillo secador y volumizador Westinghouse. Seca y da volumen al mismo tiempo, en un solo paso.','cuidado-personal','/images/productos/cuidado-personal/IMG_0550.jpg','activo',false,false,4),
  ('Trimmer/recortadora de pelo dorado','cuidado-personal-img_0624','Recortadora/trimmer de pelo en acabado dorado. Ideal para barba, patillas y contornos prolijos.','cuidado-personal','/images/productos/cuidado-personal/IMG_0624.jpg','activo',false,false,5),
  ('Secador Westinghouse negro/dorado + plancha','cuidado-personal-img_0629','Set Westinghouse en negro y dorado: secador de pelo más planchita. Todo para tu peinado en un combo.','cuidado-personal','/images/productos/cuidado-personal/IMG_0629.jpg','activo',false,false,6),
  ('Planchita de pelo KANJI HOME plateada','cuidado-personal-img_0640','Planchita de pelo Kanji Home en plateado. Placas que alisan de forma pareja y cuidan el cabello.','cuidado-personal','/images/productos/cuidado-personal/IMG_0640.jpg','activo',false,false,7),
  ('Plancha onduladora/waver Yelmo gris/azul','cuidado-personal-img_0923','Onduladora/waver Yelmo en gris y azul. Conseguí ondas marcadas y con estilo en pocos minutos.','cuidado-personal','/images/productos/cuidado-personal/IMG_0923.jpg','activo',false,false,8),
  ('Kit Ultracomb Devotion secador + plancha','cuidado-personal-img_0932','Kit Ultracomb Devotion: secador de pelo más planchita. El combo completo para peinarte como en la peluquería.','cuidado-personal','/images/productos/cuidado-personal/IMG_0932.jpg','activo',true,false,9),
  ('Plancha de pelo Yelmo fucsia','cuidado-personal-img_0967','Planchita de pelo Yelmo en fucsia. Calienta rápido y alisa con un acabado suave y brillante.','cuidado-personal','/images/productos/cuidado-personal/IMG_0967.jpg','activo',false,false,10),
  ('Tocador / mesa de maquillaje con espejo rebatible','muebles-hogar-34735970_005_05app','Tocador con espejo rebatible y espacio de guardado. Tu rincón ideal para maquillarte y organizar accesorios.','muebles-hogar','/images/productos/muebles-hogar/34735970_005_05app.jpg','activo',false,false,11),
  ('Monocomando de cocina extensible cromado','muebles-hogar-d20c2a9f-4788-44d7-a7bb-54018e918674','Grifería monocomando para cocina con caño extensible y acabado cromado. Práctica, moderna y resistente.','muebles-hogar','/images/productos/muebles-hogar/D20C2A9F-4788-44D7-A7BB-54018E918674.jpg','activo',false,false,12),
  ('Colchón Deseo Mistyc + sommier','muebles-hogar-d6ab70f7-b61f-455b-a1a5-dbaa5d33ac92','Colchón Deseo Mistyc con sommier. Descanso firme y confortable para tu habitación.','muebles-hogar','/images/productos/muebles-hogar/D6AB70F7-B61F-455B-A1A5-DBAA5D33AC92.jpg','activo',false,false,13),
  ('Colchón 1 plaza azul/celeste con sommier','muebles-hogar-img_0036','Colchón de 1 plaza con sommier en tonos azul y celeste. Ideal para cuartos juveniles o de invitados.','muebles-hogar','/images/productos/muebles-hogar/IMG_0036.jpg','activo',false,false,14),
  ('Colchón 1 plaza azul/celeste con sommier','muebles-hogar-img_0038','Conjunto de colchón y sommier de 1 plaza en azul y celeste. Confort y soporte para un buen descanso.','muebles-hogar','/images/productos/muebles-hogar/IMG_0038.jpg','archivado',false,false,15),
  ('Sofá 2 cuerpos gris oscuro','muebles-hogar-img_0053','Sofá de 2 cuerpos en gris oscuro. Comodidad y diseño moderno para tu living.','muebles-hogar','/images/productos/muebles-hogar/IMG_0053.jpg','activo',true,false,16),
  ('Termo Stanley verde menta con taza','muebles-hogar-img_0061','Termo Stanley en verde menta con taza. Mantiene la temperatura por horas, ideal para el mate o el café.','muebles-hogar','/images/productos/muebles-hogar/IMG_0061.jpg','activo',false,false,17),
  ('Termo acero inox con asa negra','muebles-hogar-img_0063','Termo de acero inoxidable con asa negra. Resistente y con excelente conservación de temperatura.','muebles-hogar','/images/productos/muebles-hogar/IMG_0063.jpg','activo',false,false,18),
  ('Ropero placard de melamina blanco 3 puertas','muebles-hogar-img_0074(1)','Ropero placard de melamina blanco de 3 puertas, con amplio espacio de guardado.','muebles-hogar','/images/productos/muebles-hogar/IMG_0074(1).jpg','archivado',false,false,19),
  ('Ropero placard de melamina blanco 3 puertas','muebles-hogar-img_0074','Ropero placard de melamina blanco de 3 puertas. Mucho espacio de guardado con un diseño limpio y prolijo.','muebles-hogar','/images/productos/muebles-hogar/IMG_0074.jpg','activo',false,false,20),
  ('Bicicleta AZR mountain bike negra/azul','muebles-hogar-img_0076','Bicicleta mountain bike AZR en negro y azul. Lista para la ciudad o los caminos de tierra.','muebles-hogar','/images/productos/muebles-hogar/IMG_0076.jpg','activo',false,false,21),
  ('Canilla extensible cromada tipo industrial','muebles-hogar-img_0089','Canilla de cocina extensible estilo industrial con acabado cromado. Diseño moderno y muy funcional.','muebles-hogar','/images/productos/muebles-hogar/IMG_0089.jpg','activo',false,false,22),
  ('Silla de jardín plástico negra','muebles-hogar-img_0395','Silla de jardín de plástico resistente en negro. Liviana, apilable y fácil de limpiar.','muebles-hogar','/images/productos/muebles-hogar/IMG_0395.jpg','activo',false,false,23),
  ('Silla gamer CL negro/blanco','muebles-hogar-img_0507','Silla gamer CL en negro y blanco. Respaldo ergonómico y reclinable para largas sesiones de juego o trabajo.','muebles-hogar','/images/productos/muebles-hogar/IMG_0507.jpg','activo',false,false,24),
  ('Silla gamer CL negro con luces RGB','muebles-hogar-img_0523','Silla gamer CL en negro con luces RGB. Comodidad ergonómica y estilo gamer para tu setup.','muebles-hogar','/images/productos/muebles-hogar/IMG_0523.jpg','activo',false,false,25),
  ('Canilla monomando alta cromada','muebles-hogar-img_0554','Canilla monomando alta con acabado cromado. Ideal para piletas amplias, con diseño elegante.','muebles-hogar','/images/productos/muebles-hogar/IMG_0554.jpg','activo',false,false,26),
  ('Silla negra estilo Masters plástico','muebles-hogar-img_0682','Silla estilo Masters en plástico negro. Diseño moderno y versátil para comedor o escritorio.','muebles-hogar','/images/productos/muebles-hogar/IMG_0682.jpg','activo',false,false,27),
  ('Colchón + sommier gris/rojo/negro','muebles-hogar-img_0756','Conjunto de colchón y sommier en gris, rojo y negro. Soporte firme para un descanso reparador.','muebles-hogar','/images/productos/muebles-hogar/IMG_0756.jpg','activo',false,false,28),
  ('Colchón + sommier marrón','muebles-hogar-img_0778','Conjunto de colchón y sommier en tono marrón. Confort y prolijidad para tu dormitorio.','muebles-hogar','/images/productos/muebles-hogar/IMG_0778.jpg','activo',false,false,29),
  ('Medidor de presión / tensiómetro Ecopower','salud-e640e3fb-ad86-496c-930f-c7776e358907','Tensiómetro Ecopower para medir la presión arterial en casa de forma simple y precisa.','salud','/images/productos/salud/E640E3FB-AD86-496C-930F-C7776E358907.jpg','activo',false,false,30),
  ('Tensiómetro digital Ecopower','salud-img_0572','Tensiómetro digital Ecopower con pantalla de fácil lectura. Controlá tu presión cómodamente en casa.','salud','/images/productos/salud/IMG_0572.jpg','activo',true,false,31),
  ('Nebulizador de pistón Ecopower','salud-img_0581','Nebulizador de pistón Ecopower. Eficaz y confiable para tratamientos respiratorios de toda la familia.','salud','/images/productos/salud/IMG_0581.jpg','activo',false,false,32),
  ('Balanza personal digital vidrio KANJI','salud-img_0609','Balanza personal digital Kanji con plataforma de vidrio templado. Pesaje preciso y diseño moderno.','salud','/images/productos/salud/IMG_0609.jpg','activo',false,false,33),
  ('Soldadora inverter NOVA 220V','herramientas-384df2ee-688a-401f-8a67-b1dfaceff21f','Soldadora inverter NOVA 220V. Compacta y potente para trabajos de soldadura en el hogar o el taller.','herramientas','/images/productos/herramientas/384DF2EE-688A-401F-8A67-B1DFACEFF21F.jpg','activo',false,false,34),
  ('Juego de pinza + alicate INGCO 2 piezas Cr-V','herramientas-78558b38-4ddf-4199-b7c0-a7a48a508cb7','Juego INGCO de 2 piezas (pinza más alicate) en acero Cr-V. Herramientas resistentes para uso diario.','herramientas','/images/productos/herramientas/78558B38-4DDF-4199-B7C0-A7A48A508CB7.jpg','activo',false,false,35),
  ('Combo esencial INGCO: bolso + pinzas + llave + martillo','herramientas-8e761b2d-6a07-4a6d-b46e-0180ee629098','Combo esencial INGCO: bolso, pinzas, llave y martillo. El kit básico para arrancar tu caja de herramientas.','herramientas','/images/productos/herramientas/8E761B2D-6A07-4A6D-B46E-0180EE629098.jpg','activo',false,false,36),
  ('Podadora portátil KANJI TOOLS 18V a batería','herramientas-95ea78eb-4456-418c-8c45-4577847b008d','Podadora portátil Kanji Tools 18V a batería. Sin cables y liviana para mantener tu jardín al día.','herramientas','/images/productos/herramientas/95EA78EB-4456-418C-8C45-4577847B008D.jpg','activo',false,false,37),
  ('Escalera de aluminio articulada multiposición','herramientas-ae15c1ee-9816-4df3-bb59-28c7a1c92f1e','Escalera de aluminio articulada multiposición. Se adapta a varias formas para distintos trabajos en altura.','herramientas','/images/productos/herramientas/AE15C1EE-9816-4DF3-BB59-28C7A1C92F1E.jpg','activo',false,false,38),
  ('Taladro / atornillador inalámbrico KANJI TOOLS','herramientas-atornilladora-21-01','Taladro atornillador inalámbrico Kanji Tools. Práctico y versátil para perforar y atornillar sin cables.','herramientas','/images/productos/herramientas/atornilladora-21-01.jpg','activo',true,false,39),
  ('Escalera de aluminio articulada multiposición','herramientas-b36173e0-6d5a-4b99-a90f-441346e7e1ae','Escalera de aluminio articulada multiposición. Resistente y segura para distintos trabajos en altura.','herramientas','/images/productos/herramientas/B36173E0-6D5A-4B99-A90F-441346E7E1AE.jpg','archivado',false,false,40),
  ('Juego de 4 pinzas INGCO','herramientas-e741a135-0921-4191-90d1-a90ddaf07e36','Juego de 4 pinzas INGCO. Distintos modelos para cubrir las tareas más comunes con calidad profesional.','herramientas','/images/productos/herramientas/E741A135-0921-4191-90D1-A90DDAF07E36.jpg','activo',false,false,41),
  ('Cortatubos de PVC INGCO Automatic Open','herramientas-hpc0442','Cortatubos de PVC INGCO con apertura automática. Cortes limpios y precisos en caños plásticos.','herramientas','/images/productos/herramientas/HPC0442.jpg','activo',false,false,42),
  ('Sierra caladora KANJI TOOLS negra','herramientas-img_0178','Sierra caladora Kanji Tools en negro. Para cortes rectos y curvos en madera, plástico y más.','herramientas','/images/productos/herramientas/IMG_0178.jpg','activo',false,false,43),
  ('Amoladora angular Black+Decker naranja/negro','herramientas-img_0357','Amoladora angular Black+Decker. Potencia para cortar y desbastar metal, mampostería y más.','herramientas','/images/productos/herramientas/IMG_0357.jpg','activo',true,false,44),
  ('Inflador a batería INGCO 20V con bolso','herramientas-img_0363','Inflador a batería INGCO 20V con bolso. Inflá neumáticos y pelotas donde estés, sin cables.','herramientas','/images/productos/herramientas/IMG_0363.jpg','activo',false,false,45),
  ('Cutter/trincheta INGCO HKNS1806','herramientas-img_0371','Cutter/trincheta INGCO HKNS1806. Cuchilla retráctil resistente para cortes precisos y seguros.','herramientas','/images/productos/herramientas/IMG_0371.jpg','activo',false,false,46),
  ('Set 2 pinzas INGCO pinza diagonal','herramientas-img_0372','Set INGCO de 2 pinzas con pinza diagonal. Herramientas firmes para corte y agarre.','herramientas','/images/productos/herramientas/IMG_0372.jpg','activo',false,false,47),
  ('Hidrolavadora a batería INGCO','herramientas-img_0376','Hidrolavadora a batería INGCO. Limpieza a presión sin depender de un enchufe.','herramientas','/images/productos/herramientas/IMG_0376.jpg','activo',false,false,48),
  ('Taladro/atornilladora Bauen 20V','herramientas-img_0431','Taladro atornillador Bauen 20V a batería. Potencia y autonomía para tus proyectos.','herramientas','/images/productos/herramientas/IMG_0431.jpg','activo',false,false,49),
  ('Pistola de calor KANJI TOOLS','herramientas-pistola-de-calor-01','Pistola de calor Kanji Tools. Ideal para remover pintura, termocontraer y trabajos de bricolaje.','herramientas','/images/productos/herramientas/pistola-de-calor-01.jpg','activo',false,false,50),
  ('Rotomartillo KANJI TOOLS con mango auxiliar','herramientas-rotomartillo-01','Rotomartillo Kanji Tools con mango auxiliar. Perforá hormigón y mampostería con potencia y control.','herramientas','/images/productos/herramientas/rotomartillo-01.jpg','activo',false,false,51),
  ('Auriculares gamer Kanji Z-32','tecnologia-celulares-43033a6a-9636-4539-814a-bc391b025f34','Auriculares gamer Kanji Z-32 con micrófono. Sonido envolvente y comodidad para tus partidas.','tecnologia-celulares','/images/productos/tecnologia-celulares/43033A6A-9636-4539-814A-BC391B025F34.jpg','activo',false,false,52),
  ('Cámara Smart IP Kanjinet 1 antena visión nocturna','tecnologia-celulares-8a0dec27-0250-431d-b3e5-3824f7986e70','Cámara IP smart Kanjinet con visión nocturna. Vigilá tu casa o negocio desde el celular.','tecnologia-celulares','/images/productos/tecnologia-celulares/8A0DEC27-0250-431D-B3E5-3824F7986E70.jpg','activo',false,false,53),
  ('Cámara Smart IP Kanjinet 2 antenas lente 3.6 mm','tecnologia-celulares-a4d7066f-1779-475c-8e48-0dcb0372035c','Cámara IP smart Kanjinet de 2 antenas y lente 3.6 mm. Mejor alcance y nitidez para tu seguridad.','tecnologia-celulares','/images/productos/tecnologia-celulares/A4D7066F-1779-475C-8E48-0DCB0372035C.jpg','activo',false,false,54),
  ('Soporte para TV de pie con ruedas','tecnologia-celulares-d525e660-8c21-4d90-8575-d0114553e150','Soporte de pie con ruedas para TV. Movés tu pantalla a cualquier ambiente con facilidad.','tecnologia-celulares','/images/productos/tecnologia-celulares/D525E660-8C21-4D90-8575-D0114553E150.jpg','activo',false,false,55),
  ('Auriculares TWS inalámbricos negros','tecnologia-celulares-img_0127','Auriculares TWS inalámbricos en negro. Libertad total y buen sonido para el día a día.','tecnologia-celulares','/images/productos/tecnologia-celulares/IMG_0127.jpg','activo',false,false,56),
  ('Soporte TV para pared LED/LCD/PDP','tecnologia-celulares-img_0429','Soporte de pared para TV LED, LCD y PDP. Fijación firme y prolija para tu televisor.','tecnologia-celulares','/images/productos/tecnologia-celulares/IMG_0429.jpg','activo',false,false,57),
  ('Tablet con funda transparente verde lima','tecnologia-celulares-img_0618','Tablet con funda protectora transparente en verde lima. Lista para estudiar, navegar y entretenerte.','tecnologia-celulares','/images/productos/tecnologia-celulares/IMG_0618.jpg','activo',false,false,58),
  ('Funda/case para tablet verde lima origami','tecnologia-celulares-img_0619','Funda tipo origami para tablet en verde lima. Protege la pantalla y sirve de soporte.','tecnologia-celulares','/images/productos/tecnologia-celulares/IMG_0619.jpg','activo',false,false,59),
  ('Smart TV Enova Google TV 50"','tecnologia-celulares-img_1431','Smart TV Enova de 50 pulgadas con Google TV. Todas tus apps y contenidos en una pantalla grande.','tecnologia-celulares','/images/productos/tecnologia-celulares/IMG_1431.jpg','activo',true,false,60),
  ('Máquina de copos de azúcar KANJI HOME','electrodomesticos-2333683e-52cc-47c3-aa50-483e7519104f','Máquina de copos de azúcar (algodón de azúcar) Kanji Home. Diversión dulce para cumpleaños y eventos.','electrodomesticos','/images/productos/electrodomesticos/2333683E-52CC-47C3-AA50-483E7519104F.jpg','activo',false,false,61),
  ('Heladera Telefunken 220 lt con dispenser de agua','electrodomesticos-3d218783-8f19-4d43-8b04-17b5cfcf68a4','Heladera Telefunken de 220 litros con dispenser de agua. Capacidad y practicidad para toda la familia.','electrodomesticos','/images/productos/electrodomesticos/3D218783-8F19-4D43-8B04-17B5CFCF68A4.jpg','activo',true,false,62),
  ('Dispenser de agua frío/calor Telefunken blanco','electrodomesticos-602527a1-d779-4377-bbb3-78d7dd7f6007','Dispenser de agua frío/calor Telefunken blanco. Agua a la temperatura justa en todo momento.','electrodomesticos','/images/productos/electrodomesticos/602527A1-D779-4377-BBB3-78D7DD7F6007.jpg','activo',false,false,63),
  ('Frigobar retro 50 lt KANJI HOME negro','electrodomesticos-7d7a06b5-a447-49f1-8110-2a551aeb3e64','Frigobar retro Kanji Home de 50 litros en negro. Compacto y con estilo para oficina, cuarto o bar.','electrodomesticos','/images/productos/electrodomesticos/7D7A06B5-A447-49F1-8110-2A551AEB3E64.jpg','activo',false,false,64),
  ('Lavarropas automático VITTA 6 kg Inverter gris','electrodomesticos-7f7759a6-173d-4ac7-96e2-c00dfe9ecee7','Lavarropas automático Vitta de 6 kg con motor Inverter, en gris. Lavado eficiente y silencioso.','electrodomesticos','/images/productos/electrodomesticos/7F7759A6-173D-4AC7-96E2-C00DFE9ECEE7.jpg','activo',true,false,65),
  ('Cocina a gas PEABODY negra 4 hornallas','electrodomesticos-img_0031','Cocina a gas Peabody de 4 hornallas en negro. Horno amplio y diseño moderno para tu cocina.','electrodomesticos','/images/productos/electrodomesticos/IMG_0031.jpg','activo',false,false,66),
  ('Cafetera de cápsulas KANJI HOME blanca/negra','electrodomesticos-img_0064','Cafetera de cápsulas Kanji Home en blanco y negro. Tu café listo en segundos.','electrodomesticos','/images/productos/electrodomesticos/IMG_0064.jpg','activo',false,false,67),
  ('Balanza comercial Vestax Ecostar 40 kg','electrodomesticos-img_0068','Balanza comercial Vestax Ecostar de hasta 40 kg. Precisa y robusta para tu negocio.','electrodomesticos','/images/productos/electrodomesticos/IMG_0068.jpg','activo',false,false,68),
  ('Urna/percoladora grande inox con canilla','electrodomesticos-img_0070','Percoladora/urna de acero inoxidable con canilla. Ideal para servir café o agua caliente en cantidad.','electrodomesticos','/images/productos/electrodomesticos/IMG_0070.jpg','activo',false,false,69),
  ('Freezer horizontal KANJI HOME blanco','electrodomesticos-img_0114','Freezer horizontal Kanji Home blanco. Gran capacidad de congelado para el hogar o el comercio.','electrodomesticos','/images/productos/electrodomesticos/IMG_0114.jpg','activo',false,false,70),
  ('Air fryer doble canasta Westinghouse negro','electrodomesticos-img_0156','Freidora de aire Westinghouse de doble canasta, en negro. Cociná dos cosas a la vez con poco aceite.','electrodomesticos','/images/productos/electrodomesticos/IMG_0156.jpg','activo',true,false,71),
  ('Air fryer doble canasta Westinghouse abierto','electrodomesticos-img_0159','Freidora de aire Westinghouse de doble canasta. Dos cestos independientes para preparar comidas completas.','electrodomesticos','/images/productos/electrodomesticos/IMG_0159.jpg','activo',false,false,72),
  ('Batidora de pie con bowl KANJI HOME blanca','electrodomesticos-img_0173','Batidora de pie Kanji Home con bowl, en blanco. Mezclá y batí sin esfuerzo para tus recetas.','electrodomesticos','/images/productos/electrodomesticos/IMG_0173.jpg','activo',false,false,73),
  ('Air fryer KANJI HOME negro/inox','electrodomesticos-img_0180','Freidora de aire Kanji Home en negro e inox. Frituras más sanas con poco o nada de aceite.','electrodomesticos','/images/productos/electrodomesticos/IMG_0180.jpg','activo',false,false,74),
  ('Sandwichera/grill 3-en-1 negra con placas','electrodomesticos-img_0185','Sandwichera y grill 3 en 1 con placas intercambiables, en negro. Tostados, wafles y grillados en un solo equipo.','electrodomesticos','/images/productos/electrodomesticos/IMG_0185.jpg','activo',false,false,75),
  ('Máquina para pasta KANJI HOME roja','electrodomesticos-img_0190','Máquina para pasta Kanji Home en rojo. Hacé fideos caseros de forma fácil y divertida.','electrodomesticos','/images/productos/electrodomesticos/IMG_0190.jpg','activo',false,false,76),
  ('Pava eléctrica KANJI inox/negra','electrodomesticos-img_0195','Pava eléctrica Kanji en acero inoxidable y negro. Agua caliente rápida con apagado automático.','electrodomesticos','/images/productos/electrodomesticos/IMG_0195.jpg','activo',false,false,77),
  ('Espumador de leche Ultracomb EL-8501 inox','electrodomesticos-img_0265','Espumador de leche Ultracomb EL-8501 en inox. Espuma cremosa para tus cafés tipo cafetería.','electrodomesticos','/images/productos/electrodomesticos/IMG_0265.jpg','activo',false,false,78),
  ('Aspiradora Yelmo gris/rosa multiciclónica','electrodomesticos-img_0280','Aspiradora multiciclónica Yelmo en gris y rosa. Potencia de succión sin perder fuerza.','electrodomesticos','/images/productos/electrodomesticos/IMG_0280.jpg','activo',false,false,79),
  ('Cafetera espresso Ultracomb con pantalla táctil','electrodomesticos-img_0283','Cafetera espresso Ultracomb con pantalla táctil. Café de calidad barista en tu casa.','electrodomesticos','/images/productos/electrodomesticos/IMG_0283.jpg','activo',false,false,80),
  ('Anafe de inducción Ultracomb negro 1 hornalla','electrodomesticos-img_0285','Anafe de inducción Ultracomb de 1 hornalla, en negro. Cocción rápida, segura y eficiente.','electrodomesticos','/images/productos/electrodomesticos/IMG_0285.jpg','activo',false,false,81),
  ('Air fryer Yelmo lila/violeta redondo','electrodomesticos-img_0289','Freidora de aire Yelmo redonda en lila. Color y diseño para una cocina más saludable.','electrodomesticos','/images/productos/electrodomesticos/IMG_0289.jpg','activo',false,false,82),
  ('Air fryer Yelmo verde menta cuadrado','electrodomesticos-img_0292','Freidora de aire Yelmo cuadrada en verde menta. Frituras crocantes con menos aceite.','electrodomesticos','/images/productos/electrodomesticos/IMG_0292.jpg','activo',false,false,83),
  ('Air fryer Yelmo lila/violeta cuadrado','electrodomesticos-img_0295','Freidora de aire Yelmo cuadrada en violeta. Práctica, moderna y con mucho color.','electrodomesticos','/images/productos/electrodomesticos/IMG_0295.jpg','activo',false,false,84),
  ('Cortadora de fiambre/embutidos Ultracomb inox','electrodomesticos-img_0303','Cortadora de fiambres y embutidos Ultracomb en inox. Fetas parejas de fiambres en casa.','electrodomesticos','/images/productos/electrodomesticos/IMG_0303.jpg','activo',false,false,85),
  ('Procesadora/ralladora Ultracomb blanca/roja','electrodomesticos-img_0306','Procesadora y ralladora Ultracomb en blanco y rojo. Picá, rallá y procesá en minutos.','electrodomesticos','/images/productos/electrodomesticos/IMG_0306.jpg','activo',false,false,86),
  ('Yogurtera Ultracomb inox con 7 frasquitos','electrodomesticos-img_0312','Yogurtera Ultracomb en inox con 7 frasquitos. Yogur casero y natural para toda la semana.','electrodomesticos','/images/productos/electrodomesticos/IMG_0312.jpg','activo',false,false,87),
  ('Anafe vitrocerámica Ultracomb AN-E604 4 hornallas','electrodomesticos-img_0318','Anafe vitrocerámica Ultracomb AN-E604 de 4 hornallas. Superficie elegante y fácil de limpiar.','electrodomesticos','/images/productos/electrodomesticos/IMG_0318.jpg','activo',false,false,88),
  ('Mixer de mano Liliana EasyHome blanco/negro','electrodomesticos-img_0391','Mixer de mano Liliana EasyHome en blanco y negro. Licuá y procesá directo en la olla o el vaso.','electrodomesticos','/images/productos/electrodomesticos/IMG_0391.jpg','activo',false,false,89),
  ('Microondas KANJI HOME blanco/negro cerrado','electrodomesticos-img_0595','Microondas Kanji Home en blanco y negro. Calentá y cociná con varias potencias.','electrodomesticos','/images/productos/electrodomesticos/IMG_0595.jpg','activo',false,false,90),
  ('Microondas KANJI HOME blanco/negro abierto','electrodomesticos-img_0596','Microondas Kanji Home con amplio interior. Práctico para el día a día de tu cocina.','electrodomesticos','/images/productos/electrodomesticos/IMG_0596.jpg','activo',false,false,91),
  ('Plancha a vapor KANJI HOME verde/azul oscuro','electrodomesticos-img_0599','Plancha a vapor Kanji Home en verde y azul. Vapor potente para prendas sin arrugas.','electrodomesticos','/images/productos/electrodomesticos/IMG_0599.jpg','activo',false,false,92),
  ('Set de ollas marmoladas negras + sartén','electrodomesticos-img_0604','Set de ollas marmoladas en negro con sartén. Antiadherentes y resistentes para cocinar a diario.','electrodomesticos','/images/productos/electrodomesticos/IMG_0604.jpg','activo',false,false,93),
  ('Set de ollas crema con asas/tapa madera','electrodomesticos-img_0606','Set de ollas crema con asas y tapas tipo madera. Diseño cálido y práctico para tu cocina.','electrodomesticos','/images/productos/electrodomesticos/IMG_0606.jpg','activo',false,false,94),
  ('Secarropas centrífuga Codini 6,5 kg blanca','electrodomesticos-img_0754','Secarropas centrífugo Codini de 6,5 kg en blanco. Quita el agua de la ropa en minutos.','electrodomesticos','/images/productos/electrodomesticos/IMG_0754.jpg','activo',false,false,95),
  ('Secarropas + lavarropas Codini dúo blanco','electrodomesticos-img_0759','Dúo Codini: lavarropas más secarropas en blanco. La solución completa para el lavado en poco espacio.','electrodomesticos','/images/productos/electrodomesticos/IMG_0759.jpg','activo',false,false,96),
  ('Lavarropas carga superior Codini blanco','electrodomesticos-img_0765','Lavarropas de carga superior Codini en blanco. Práctico, resistente y fácil de usar.','electrodomesticos','/images/productos/electrodomesticos/IMG_0765.jpg','activo',false,false,97),
  ('Anafe vitrocerámica Ultracomb AN-E604','electrodomesticos-img_0817','Anafe vitrocerámica Ultracomb AN-E604. Cocción pareja y superficie fácil de limpiar.','electrodomesticos','/images/productos/electrodomesticos/IMG_0817.jpg','activo',false,false,98),
  ('Calefactor eléctrico cerámico/cuarzo negro','electrodomesticos-img_0909','Calefactor eléctrico cerámico/cuarzo en negro. Calor rápido para los días más fríos.','electrodomesticos','/images/productos/electrodomesticos/IMG_0909.jpg','activo',false,false,99),
  ('Batidora de mano Yelmo celeste/turquesa','electrodomesticos-img_0922','Batidora de mano Yelmo en celeste. Liviana y práctica para batir y mezclar.','electrodomesticos','/images/productos/electrodomesticos/IMG_0922.jpg','activo',false,false,100),
  ('Air fryer Yelmo violeta con ventana negra','electrodomesticos-img_0941','Freidora de aire Yelmo en violeta con ventana. Mirá la cocción sin abrir, con menos aceite.','electrodomesticos','/images/productos/electrodomesticos/IMG_0941.jpg','activo',false,false,101),
  ('Licuadora de vidrio Yelmo rosa/salmón','electrodomesticos-img_0942','Licuadora con jarra de vidrio Yelmo en rosa salmón. Licuados y batidos resistentes y con estilo.','electrodomesticos','/images/productos/electrodomesticos/IMG_0942.jpg','activo',false,false,102),
  ('Pava eléctrica Ultracomb inox 1,7 L','electrodomesticos-img_0946','Pava eléctrica Ultracomb de 1,7 L en inox. Hierve rápido con apagado automático de seguridad.','electrodomesticos','/images/productos/electrodomesticos/IMG_0946.jpg','activo',false,false,103),
  ('Panificadora Ultracomb celeste abierta','electrodomesticos-img_0951','Panificadora Ultracomb en celeste. Pan casero recién hecho con distintos programas.','electrodomesticos','/images/productos/electrodomesticos/IMG_0951.jpg','activo',false,false,104),
  ('Juguera/extractor de jugos Ultracomb inox','electrodomesticos-img_0954','Extractor de jugos Ultracomb en inox. Jugos naturales aprovechando al máximo la fruta.','electrodomesticos','/images/productos/electrodomesticos/IMG_0954.jpg','activo',false,false,105),
  ('Molinillo de café/especias Ultracomb inox','electrodomesticos-img_0958','Molinillo de café y especias Ultracomb en inox. Molido al instante para más aroma y sabor.','electrodomesticos','/images/productos/electrodomesticos/IMG_0958.jpg','activo',false,false,106),
  ('Mini picadora/procesadora Ultracomb naranja','electrodomesticos-img_0959','Mini picadora Ultracomb en naranja. Pica verduras, frutos secos y más en segundos.','electrodomesticos','/images/productos/electrodomesticos/IMG_0959.jpg','activo',false,false,107),
  ('Tostadora Ultracomb roja 2 ranuras','electrodomesticos-img_0962','Tostadora Ultracomb de 2 ranuras en rojo. Tostadas en su punto con varios niveles.','electrodomesticos','/images/productos/electrodomesticos/IMG_0962.jpg','activo',false,false,108),
  ('Horno eléctrico Yelmo YL-45AN negro','electrodomesticos-img_0974','Horno eléctrico Yelmo YL-45AN en negro. Capacidad y potencia para hornear y gratinar.','electrodomesticos','/images/productos/electrodomesticos/IMG_0974.jpg','activo',false,false,109),
  ('Horno eléctrico Yelmo YL-45AN gris','electrodomesticos-img_0975','Horno eléctrico Yelmo YL-45AN en gris. Práctico para tortas, pizzas y comidas al horno.','electrodomesticos','/images/productos/electrodomesticos/IMG_0975.jpg','activo',false,false,110),
  ('Cafetera de filtro whiterblack negra','electrodomesticos-img_1023','Cafetera de filtro en negro. Prepará varias tazas de café de una sola vez.','electrodomesticos','/images/productos/electrodomesticos/IMG_1023.jpg','activo',false,false,111),
  ('Robot de cocina Liliana con licuadora','electrodomesticos-img_1026','Robot de cocina Liliana con vaso licuador. Múltiples funciones para cocinar más fácil.','electrodomesticos','/images/productos/electrodomesticos/IMG_1026.jpg','activo',true,false,112),
  ('Wafflera corazón negra','electrodomesticos-img_1036','Wafflera con forma de corazones, en negro. Wafles caseros listos en minutos.','electrodomesticos','/images/productos/electrodomesticos/IMG_1036.jpg','activo',false,false,113),
  ('Grill eléctrico redondo Liliana dorado','electrodomesticos-img_1043','Grill eléctrico redondo Liliana en dorado. Ideal para grillar carnes y verduras en la mesa.','electrodomesticos','/images/productos/electrodomesticos/IMG_1043.jpg','activo',false,false,114),
  ('Pava eléctrica Liliana inox','electrodomesticos-img_1046','Pava eléctrica Liliana en acero inoxidable. Herví agua rápido con un diseño elegante.','electrodomesticos','/images/productos/electrodomesticos/IMG_1046.jpg','activo',false,false,115),
  ('Panificadora Liliana Breadly blanca','electrodomesticos-img_1051','Panificadora Liliana Breadly en blanco. Pan casero a tu gusto con varios programas.','electrodomesticos','/images/productos/electrodomesticos/IMG_1051.jpg','activo',false,false,116),
  ('Panificadora Liliana Breadly blanca abierta','electrodomesticos-img_1053','Panificadora Liliana Breadly con cuba antiadherente. Pan fresco y casero todos los días.','electrodomesticos','/images/productos/electrodomesticos/IMG_1053.jpg','activo',false,false,117),
  ('Vitrinas refrigeradas Pioneer Home','electrodomesticos-img_1439','Vitrinas refrigeradas Pioneer Home. Exhibí y conservá productos en frío en tu comercio.','electrodomesticos','/images/productos/electrodomesticos/IMG_1439.jpg','activo',false,false,118),
  ('Heladera Pioneer Home 2 puertas inox','electrodomesticos-img_1440','Heladera Pioneer Home de 2 puertas en acero inoxidable. Mucho espacio y diseño moderno.','electrodomesticos','/images/productos/electrodomesticos/IMG_1440.jpg','activo',false,false,119),
  ('Pochoclera eléctrica KANJI HOME','electrodomesticos-pochoclera-electrica','Pochoclera eléctrica Kanji Home. Pochoclo casero sin aceite, ideal para las pelis en familia.','electrodomesticos','/images/productos/electrodomesticos/pochoclera-electrica.jpg','activo',false,false,120),
  ('Cerradura inteligente digital KB con teclado','seguridad-cerradura-01','Cerradura inteligente digital con teclado numérico y apertura por código. Diseño moderno tipo push-pull para más seguridad en tu puerta.','seguridad','/images/productos/seguridad/cerradura-01.jpg','activo',false,false,121),
  ('Cerradura inteligente KB con manija y huella digital','seguridad-cerradura-02','Cerradura inteligente con manija, lector de huella digital y teclado táctil. Varias formas de apertura para controlar el acceso a tu hogar.','seguridad','/images/productos/seguridad/cerradura-02.jpg','activo',true,false,122),
  ('Parlante torre con luces RGB','tecnologia-celulares-parlante-torre-rgb-01','Torre de sonido con iluminación RGB envolvente. Potencia y luces de colores para ambientar cualquier reunión o fiesta.','tecnologia-celulares','/images/productos/tecnologia-celulares/parlante-torre-rgb-01.jpg','activo',false,true,123),
  ('Parlante torre party con luces RGB','tecnologia-celulares-parlante-torre-party-01','Parlante torre tipo party con varios altavoces e iluminación RGB. Mucho volumen y efectos de luz para tus eventos.','tecnologia-celulares','/images/productos/tecnologia-celulares/parlante-torre-party-01.jpg','activo',false,true,124),
  ('Parlante party box doble woofer RGB','tecnologia-celulares-parlante-partybox-doble-woofer','Party box con doble woofer y luces RGB. Sonido potente y graves profundos, con asa para llevarlo a todos lados.','tecnologia-celulares','/images/productos/tecnologia-celulares/parlante-partybox-doble-woofer.jpg','activo',false,true,125),
  ('Parlante portátil Bluetooth con luz RGB','tecnologia-celulares-parlante-portatil-cilindrico-rgb','Parlante portátil cilíndrico con conexión Bluetooth y luz RGB. Compacto, resistente y con buena autonomía para llevar.','tecnologia-celulares','/images/productos/tecnologia-celulares/parlante-portatil-cilindrico-rgb.jpg','activo',false,true,126),
  ('Celular Motorola Moto G05','tecnologia-celulares-motorola-moto-g05','Smartphone Motorola Moto G05 con pantalla amplia, buena batería y cámara para el día a día. Ideal para uso diario.','tecnologia-celulares','/images/productos/tecnologia-celulares/motorola-moto-g05.jpg','activo',true,true,127),
  ('Parlante party box portátil con luces RGB','tecnologia-celulares-parlante-partybox-portatil-rgb','Party box portátil con luces RGB y manija de transporte. Sonido envolvente para llevar la música donde vayas.','tecnologia-celulares','/images/productos/tecnologia-celulares/parlante-partybox-portatil-rgb.jpg','activo',false,true,128),
  ('Celular Xiaomi Redmi','tecnologia-celulares-celular-redmi-01','Smartphone Xiaomi Redmi con pantalla grande y varias cámaras. Rendimiento fluido y diseño moderno para todos los días.','tecnologia-celulares','/images/productos/tecnologia-celulares/celular-redmi-01.jpg','activo',false,true,129),
  ('Celular Xiaomi Redmi A5','tecnologia-celulares-xiaomi-redmi-a5','Smartphone Xiaomi Redmi A5 con pantalla amplia, batería de larga duración y diseño moderno. Una gran opción accesible.','tecnologia-celulares','/images/productos/tecnologia-celulares/xiaomi-redmi-a5.jpg','activo',false,true,130),
  ('Soporte articulado para TV','tecnologia-celulares-soporte-tv-articulado','Soporte articulado para TV o monitor. Brazo móvil para ajustar el ángulo de la pantalla y aprovechar mejor el espacio.','tecnologia-celulares','/images/productos/tecnologia-celulares/soporte-tv-articulado.jpg','activo',false,true,131),
  ('Parlante portátil Bluetooth compacto','tecnologia-celulares-parlante-portatil-compacto','Parlante portátil compacto con Bluetooth. Liviano y práctico, con buen volumen para escuchar música en cualquier lado.','tecnologia-celulares','/images/productos/tecnologia-celulares/parlante-portatil-compacto.jpg','activo',false,true,132),
  ('Bolso de herramientas INGCO','herramientas-ingco-bolso-herramientas','Bolso de lona reforzada INGCO para guardar y transportar tus herramientas. Resistente, con asas firmes y cierre amplio.','herramientas','/images/productos/herramientas/ingco-bolso-herramientas.jpg','activo',false,true,133),
  ('Bordeadora inalámbrica para jardín','herramientas-bordeadora-inalambrica','Bordeadora inalámbrica para el jardín. Liviana y sin cables, ideal para emparejar bordes y pasto con total comodidad.','herramientas','/images/productos/herramientas/bordeadora-inalambrica.jpg','activo',false,true,134),
  ('Inflador digital portátil Kanji','herramientas-inflador-digital-kanji','Mini compresor inflador digital Kanji con display y recargable. Para inflar neumáticos de autos, bicis, motos y pelotas.','herramientas','/images/productos/herramientas/inflador-digital-kanji.jpg','activo',false,true,135),
  ('Juego de llaves combinadas INGCO','herramientas-ingco-juego-llaves-combinadas','Set de llaves combinadas INGCO en distintas medidas. Acero resistente, ideal para tareas de mecánica y mantenimiento.','herramientas','/images/productos/herramientas/ingco-juego-llaves-combinadas.jpg','activo',false,true,136),
  ('Sombrilla playera azul','muebles-hogar-sombrilla-playera-azul','Sombrilla o parasol azul con inclinación regulable. Buena protección del sol para la playa, el patio o la pileta.','muebles-hogar','/images/productos/muebles-hogar/sombrilla-playera-azul.jpg','activo',false,true,137),
  ('Acolchado + juego de sábanas','muebles-hogar-acolchado-juego-sabanas','Acolchado suave y juego de sábanas Cotton Touch. Confort y abrigo para vestir tu cama con buena calidad y estilo.','muebles-hogar','/images/productos/muebles-hogar/acolchado-juego-sabanas.jpg','activo',false,true,138),
  ('Mesa plegable','muebles-hogar-mesa-plegable','Mesa plegable resistente, ideal para eventos, jardín o espacios reducidos. Práctica de guardar y fácil de transportar.','muebles-hogar','/images/productos/muebles-hogar/mesa-plegable.jpg','activo',false,true,139),
  ('Nebulizador portátil de malla','salud-nebulizador-portatil-malla','Nebulizador portátil ultrasónico de malla, recargable y silencioso. Incluye máscara: ideal para usar en casa o de viaje.','salud','/images/productos/salud/nebulizador-portatil-malla.jpg','activo',false,true,140)
) AS v(nombre, slug, descripcion, cat_slug, imagen, estado, destacado, es_nuevo, orden)
JOIN categorias c ON c.slug = v.cat_slug
ON CONFLICT (slug) DO NOTHING;

-- Imagen principal en la galería de cada producto (idempotente)
INSERT INTO producto_imagenes (producto_id, url, alt, es_principal, orden)
SELECT p.id, p.imagen_principal_url, p.nombre || ' - Mundo Hogar', true, 0
FROM productos p
WHERE p.imagen_principal_url IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM producto_imagenes pi WHERE pi.producto_id = p.id);


-- ============================================================
-- DATOS: textos editables, configuración y banner inicial
-- ============================================================
INSERT INTO site_content (clave, valor, grupo, etiqueta) VALUES
  ('hero_eyebrow',     'Mayorista & minorista · Santa Fe Capital', 'Inicio', 'Etiqueta superior del hero'),
  ('hero_titulo',      'Todo para tu hogar, en un solo lugar.',    'Inicio', 'Título principal'),
  ('hero_subtitulo',   'Electrodomésticos, muebles, herramientas, tecnología y mucho más. Precios competitivos para mayoristas y minoristas, con atención personalizada por WhatsApp.', 'Inicio', 'Subtítulo del hero'),
  ('mayorista_titulo', '¿Comprás por cantidad? Tenemos precio mayorista.', 'Mayorista', 'Título sección mayorista'),
  ('mayorista_texto',  'Atendemos a comercios, revendedores y compradores por volumen con condiciones especiales y distribución. Armamos una propuesta a tu medida.', 'Mayorista', 'Texto sección mayorista'),
  ('envios_texto',     'Entregas en Santa Fe Capital y alrededores, y despachos al resto del país. Coordinamos por WhatsApp según el producto.', 'Envíos', 'Texto de envíos'),
  ('pagos_texto',      'Aceptamos Mercado Pago (tarjeta de crédito, débito y cuotas), transferencia y efectivo.', 'Pagos', 'Texto de medios de pago'),
  ('footer_descripcion','Equipamos hogares y comercios de Santa Fe y la región con electrodomésticos, muebles, herramientas y más, desde 2014.', 'Footer', 'Descripción del footer')
ON CONFLICT (clave) DO NOTHING;

INSERT INTO site_settings (id, nombre_tienda, whatsapp, email, direccion, horarios, moneda, mensaje_promo, envio_info)
VALUES (1, 'Mundo Hogar', '5493426481326', 'ventas@mundohogar.com.ar', 'Santa Fe Capital, Argentina',
        'Lun a Vie 9 a 18 hs · Sáb 9 a 13 hs', 'ARS',
        'Envíos en Santa Fe y todo el país · Atención por WhatsApp',
        'Entregas en Santa Fe Capital y alrededores. Despachos al resto del país coordinados por WhatsApp.')
ON CONFLICT (id) DO NOTHING;

INSERT INTO banners (titulo, subtitulo, texto_boton, url_boton, posicion, orden, activo)
SELECT 'Todo para tu hogar, en un solo lugar.',
       'Electrodomésticos, muebles, herramientas y mucho más. Mayorista y minorista en Santa Fe.',
       'Ver productos', '/productos', 'hero', 1, true
WHERE NOT EXISTS (SELECT 1 FROM banners WHERE posicion = 'hero');
