-- ============================================================
-- Mundo Hogar — Políticas de Storage para imágenes
-- Ejecutar DESPUÉS de crear el bucket 'producto-imagenes' en
-- Supabase Dashboard → Storage → New bucket (Public = ON)
-- ============================================================

-- Lectura pública (cualquiera puede ver las imágenes)
CREATE POLICY "imagenes_publicas_lectura"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'producto-imagenes');

-- Solo usuarios autenticados con rol staff pueden subir
CREATE POLICY "imagenes_subida_staff"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'producto-imagenes'
    AND auth.uid() IS NOT NULL
    AND fn_get_user_role() IN ('administrador','encargado_stock')
  );

-- Solo admins pueden borrar imágenes
CREATE POLICY "imagenes_borrar_admin"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'producto-imagenes'
    AND fn_get_user_role() = 'administrador'
  );
