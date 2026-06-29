# Procedimiento de Transferencia — Mundo Hogar

Guía para ceder el proyecto al futuro propietario de forma ordenada y dejar de depender de cuentas
personales del desarrollador.

> ⚠️ **No guardar contraseñas ni tokens en este documento ni en el repositorio.** Las credenciales se
> comparten por un canal seguro (gestor de contraseñas / en persona) y se rotan al transferir.

---

## 1. Inventario de cuentas y servicios

| Servicio | Para qué | Dueño hoy | Acción al transferir |
|---|---|---|---|
| **GitHub** (`Ferreya1701/mundo-hogar`) | Código fuente | Desarrollador | Transferir repo o crear cuenta del dueño y pasarlo |
| **Vercel** | Hosting/deploy | Desarrollador | Transferir proyecto o reconectar bajo cuenta del dueño |
| **Supabase** | Base de datos del panel | A crear | Crear bajo cuenta/email del dueño |
| **Mercado Pago** | Cobros | Del dueño (negocio) | Usar la cuenta del negocio; nunca la del desarrollador |
| **Dominio** (`mundohogar.com.ar`, opcional) | URL propia | A definir | Registrar a nombre del dueño |
| **Email** (`ventas@mundohogar.com.ar`) | Contacto | A definir | Crear o cambiar el que figura en la web |
| **Analytics / Meta Pixel** | Métricas/ads | No instalado aún | Crear bajo cuentas del dueño |

## 2. Transferir el repositorio de GitHub

**Opción A (recomendada):** GitHub → repo → *Settings* → *Danger Zone* → **Transfer ownership** a la
cuenta del dueño.
**Opción B:** el dueño crea su cuenta y se le agrega como colaborador/propietario; luego se quita al
desarrollador.

## 3. Transferir el proyecto de Vercel

1. El dueño crea cuenta en Vercel e inicia sesión **con su GitHub**.
2. *Add New → Project* → importar `mundo-hogar`.
3. **Framework Preset:** *Other*. **Root Directory:** vacío. **Build Command:** vacío.
   **Output Directory:** vacío (el `vercel.json` ya fuerza la raíz).
4. Deploy. Verificar que la home abra sin 404.
5. Cargar las **Environment Variables** que correspondan (ver punto 6).
6. Quitar el proyecto de la cuenta del desarrollador.

## 4. Crear/transferir la base de datos (Supabase)

Seguir `ADMINISTRADOR-MUNDO-HOGAR.md`:
1. El dueño crea el proyecto Supabase (región São Paulo).
2. Correr `sql/001-schema.sql` → `002-rls-policies.sql` → `003-seed-datos.sql` → `004-storage-policies.sql`.
3. Crear el bucket `producto-imagenes` (público).
4. Cargar `SUPABASE_URL` y `SUPABASE_ANON_KEY` en `supabase-config.js`, commit y push.
5. Crear el **primer usuario administrador** (ver punto 5).

## 5. Asignar al nuevo dueño como propietario principal

En Supabase → *Authentication → Users → Add user* (email + contraseña del dueño). Luego en *SQL Editor*:

```sql
update profiles
set rol = 'administrador', nombre = 'Nombre del Dueño', activo = true
where email = 'email-del-dueño@ejemplo.com';
```

Después, **desactivar o eliminar** la cuenta admin del desarrollador:

```sql
update profiles set activo = false where email = 'email-del-desarrollador@ejemplo.com';
```

Así el sistema deja de depender de cuentas personales del desarrollador.

## 6. Variables de entorno a configurar

- **Supabase** (en `supabase-config.js`): `SUPABASE_URL`, `SUPABASE_ANON_KEY`.
- **Mercado Pago** (solo si se implementa checkout; en Vercel → *Settings → Environment Variables*,
  NUNCA en el código): `MP_ACCESS_TOKEN`, `MP_PUBLIC_KEY`, `MP_WEBHOOK_SECRET`,
  `URL_SUCCESS`, `URL_FAILURE`, `URL_PENDING`.

## 7. Mercado Pago

- Usar **siempre la cuenta de Mercado Pago del negocio** (la que recibe el dinero).
- Generar credenciales en el panel de desarrolladores de Mercado Pago (modo prueba y producción).
- El **Access Token es secreto**: va en variables de entorno del servidor, nunca en el frontend ni
  en GitHub.

## 8. Dominio y emails

- Si se quiere `mundohogar.com.ar`: registrarlo a nombre del dueño y conectarlo en Vercel
  (*Settings → Domains*).
- El email `ventas@mundohogar.com.ar` que aparece en la web debe **existir** o cambiarse por uno real.

## 9. Analytics y Meta Pixel (opcional, para ads)

Hoy **no están instalados**. Si se usan, crearlos bajo las cuentas del dueño (Google Analytics 4 /
Meta Business) y agregar el script en `index.html`. Relevante porque el negocio corre publicidad.

## 10. Checklist final de independencia

- [ ] Repo GitHub a nombre del dueño.
- [ ] Proyecto Vercel a nombre del dueño, con la home abriendo OK.
- [ ] Supabase del dueño, SQL corrido, admin del dueño creado.
- [ ] Admin del desarrollador desactivado.
- [ ] Mercado Pago = cuenta del negocio.
- [ ] Variables sensibles solo en entornos seguros (no en el código).
- [ ] Contraseñas rotadas y accesos del desarrollador removidos.
