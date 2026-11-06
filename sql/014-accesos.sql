-- ============================================================
-- 014 — ACCESOS AL PANEL: alta desde el panel y roles blindados
--       (2026-11-06)
-- Ejecutar en Supabase → SQL Editor, DESPUÉS del 013.
-- Idempotente: se puede correr más de una vez sin romper nada.
--
-- Por qué existe (dos agujeros del 001/002):
--   a) fn_create_profile tomaba el ROL de los datos que manda quien se
--      registra (raw_user_meta_data). Con el registro público abierto,
--      cualquiera podía crearse una cuenta "administrador" con la clave
--      pública de la web.
--   b) La política profiles_update_own deja que cada usuario edite su
--      propia fila ENTERA: un vendedor podía ponerse rol administrador.
--
-- Qué cambia:
--   1) Toda cuenta nueva nace INACTIVA y como vendedor. La activa y le da
--      el rol el panel (Edge Function "usuarios", con la clave de servicio)
--      o un administrador desde Usuarios → Editar.
--   2) Rol, estado (activo) y email del perfil solo los cambia un
--      administrador, y nunca los suyos propios (para que no se quede
--      afuera por error). El servidor (SQL Editor, Edge Functions) puede todo.
--   3) profiles.debe_cambiar_clave: la cuenta tiene una contraseña temporal
--      y el panel le pide elegir una propia al entrar.
--
-- Además, en Supabase → Authentication → Sign In / Providers dejar APAGADO
-- "Allow new users to sign up": las cuentas se crean solo desde el panel.
-- ============================================================


-- ──────────────────────────────────────────────
-- 1) Marca de contraseña temporal
-- ──────────────────────────────────────────────
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS debe_cambiar_clave BOOLEAN NOT NULL DEFAULT false;


-- ──────────────────────────────────────────────
-- 2) Perfil de una cuenta nueva: inactivo y sin privilegios
--    El nombre sí puede venir de quien crea la cuenta (es solo texto).
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_create_profile()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $func$
BEGIN
  INSERT INTO public.profiles (id, email, nombre, rol, activo)
  VALUES (
    NEW.id,
    NEW.email,
    left(coalesce(nullif(btrim(NEW.raw_user_meta_data->>'nombre'), ''),
                  split_part(coalesce(NEW.email, ''), '@', 1),
                  'Usuario'), 80),
    'vendedor',
    false
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$func$;

-- Igual que en 001 (en auth.users se reemplaza, no se borra: no somos dueños).
CREATE OR REPLACE TRIGGER tr_auth_user_created
  AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION fn_create_profile();


-- ──────────────────────────────────────────────
-- 3) Guardia de cambios en profiles
--    Las políticas de 002 siguen igual (cada uno edita su fila, el admin
--    todas); esta guardia decide QUÉ columnas puede tocar cada uno.
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_profiles_proteger()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $func$
BEGIN
  -- Sin sesión de usuario = servidor (SQL Editor, clave de servicio).
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.email IS DISTINCT FROM OLD.email THEN
    RAISE EXCEPTION 'perfil_campo_protegido'
      USING HINT = 'El email de un acceso no se cambia desde el panel.';
  END IF;

  IF NEW.rol IS DISTINCT FROM OLD.rol OR NEW.activo IS DISTINCT FROM OLD.activo THEN
    IF coalesce(fn_get_user_role(), '') <> 'administrador' THEN
      RAISE EXCEPTION 'solo_admin_cambia_roles'
        USING HINT = 'Solo un administrador puede cambiar roles o activar cuentas.', ERRCODE = '42501';
    END IF;
    IF OLD.id = auth.uid() THEN
      RAISE EXCEPTION 'no_podes_cambiar_tu_rol'
        USING HINT = 'No podés cambiar tu propio rol ni desactivarte: pedíselo a otro administrador.';
    END IF;
  END IF;

  RETURN NEW;
END;
$func$;

DROP TRIGGER IF EXISTS tr_profiles_proteger ON profiles;
CREATE TRIGGER tr_profiles_proteger
  BEFORE UPDATE ON profiles FOR EACH ROW EXECUTE FUNCTION fn_profiles_proteger();

REVOKE ALL ON FUNCTION fn_create_profile()    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION fn_profiles_proteger() FROM PUBLIC, anon, authenticated;


-- ──────────────────────────────────────────────
-- 4) Para revisar al correrlo: todos los accesos que existen hoy.
--    Si aparece alguno que no conocés, desactivalo desde Usuarios → Editar
--    (o borralo en Authentication → Users).
-- ──────────────────────────────────────────────
SELECT email, nombre, rol, activo, created_at::date AS creado, ultimo_acceso::date AS ultimo_acceso
FROM profiles
ORDER BY created_at;
