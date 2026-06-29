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
CREATE POLICY "profiles_select_own"
  ON profiles FOR SELECT USING (id = auth.uid());

CREATE POLICY "profiles_select_admin"
  ON profiles FOR SELECT USING (fn_get_user_role() = 'administrador');

CREATE POLICY "profiles_update_own"
  ON profiles FOR UPDATE USING (id = auth.uid());

CREATE POLICY "profiles_update_admin"
  ON profiles FOR UPDATE USING (fn_get_user_role() = 'administrador');

CREATE POLICY "profiles_insert_admin"
  ON profiles FOR INSERT WITH CHECK (fn_get_user_role() = 'administrador');

-- ──────────────────────────────────────────────
-- CATEGORÍAS — lectura pública
-- ──────────────────────────────────────────────
CREATE POLICY "categorias_select_public"
  ON categorias FOR SELECT USING (true);

CREATE POLICY "categorias_insert_admin"
  ON categorias FOR INSERT WITH CHECK (fn_get_user_role() = 'administrador');

CREATE POLICY "categorias_update_admin"
  ON categorias FOR UPDATE USING (fn_get_user_role() = 'administrador');

CREATE POLICY "categorias_delete_admin"
  ON categorias FOR DELETE USING (fn_get_user_role() = 'administrador');

-- ──────────────────────────────────────────────
-- SUBCATEGORÍAS — lectura pública
-- ──────────────────────────────────────────────
CREATE POLICY "subcategorias_select_public"
  ON subcategorias FOR SELECT USING (true);

CREATE POLICY "subcategorias_insert_admin"
  ON subcategorias FOR INSERT WITH CHECK (fn_get_user_role() = 'administrador');

CREATE POLICY "subcategorias_update_admin"
  ON subcategorias FOR UPDATE USING (fn_get_user_role() = 'administrador');

CREATE POLICY "subcategorias_delete_admin"
  ON subcategorias FOR DELETE USING (fn_get_user_role() = 'administrador');

-- ──────────────────────────────────────────────
-- PRODUCTOS
--   - Público: sólo activos
--   - Autenticado: todos (admin/encargado pueden modificar)
-- ──────────────────────────────────────────────
CREATE POLICY "productos_select_public"
  ON productos FOR SELECT
  USING (estado = 'activo' OR auth.uid() IS NOT NULL);

CREATE POLICY "productos_insert_staff"
  ON productos FOR INSERT
  WITH CHECK (fn_get_user_role() IN ('administrador','encargado_stock'));

CREATE POLICY "productos_update_staff"
  ON productos FOR UPDATE
  USING (fn_get_user_role() IN ('administrador','encargado_stock'));

CREATE POLICY "productos_delete_admin"
  ON productos FOR DELETE
  USING (fn_get_user_role() = 'administrador');

-- ──────────────────────────────────────────────
-- IMÁGENES DE PRODUCTOS — lectura pública
-- ──────────────────────────────────────────────
CREATE POLICY "imagenes_select_public"
  ON producto_imagenes FOR SELECT USING (true);

CREATE POLICY "imagenes_insert_staff"
  ON producto_imagenes FOR INSERT
  WITH CHECK (fn_get_user_role() IN ('administrador','encargado_stock'));

CREATE POLICY "imagenes_update_staff"
  ON producto_imagenes FOR UPDATE
  USING (fn_get_user_role() IN ('administrador','encargado_stock'));

CREATE POLICY "imagenes_delete_admin"
  ON producto_imagenes FOR DELETE
  USING (fn_get_user_role() = 'administrador');

-- ──────────────────────────────────────────────
-- MOVIMIENTOS — sólo autenticados
-- (no se permiten UPDATE/DELETE: el historial es inmutable)
-- ──────────────────────────────────────────────
CREATE POLICY "movimientos_select_auth"
  ON movimientos_inventario FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY "movimientos_insert_staff"
  ON movimientos_inventario FOR INSERT
  WITH CHECK (fn_get_user_role() IN ('administrador','encargado_stock'));

-- ──────────────────────────────────────────────
-- HISTORIAL — sólo autenticados
-- ──────────────────────────────────────────────
CREATE POLICY "historial_select_auth"
  ON historial_actividad FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY "historial_insert_auth"
  ON historial_actividad FOR INSERT
  WITH CHECK (auth.uid() IS NOT NULL);
