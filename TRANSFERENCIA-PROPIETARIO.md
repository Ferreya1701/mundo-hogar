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
| **Cloudflare** (Worker `mundo-hogar` + zona DNS `mundohogarstf.com`) | Hosting de producción y DNS | Cuenta de TIAF | Verificar que el dueño tenga acceso; conectar el Worker al repo del dueño |
| **GoDaddy** (`mundohogarstf.com`) | Registro del dominio y correo | Del dueño (negocio) | Confirmar titularidad y acceso; renovación anual |
| **Vercel** (`mundo-hogar-tan.vercel.app`) | Espejo sin dominio, opcional | Desarrollador | Borrar el proyecto o reconectarlo bajo cuenta del dueño |
| **Supabase** | Base de datos del panel | Desarrollador | Transferir la organización/proyecto al email del dueño |
| **Mercado Pago** | Cobros | Del dueño (negocio) | Usar la cuenta del negocio; nunca la del desarrollador |
| **WhatsApp / PanelBot** | Bot de atención conectado al CRM | A confirmar | Ver `sql/010` y `sql/011`; el número se configura en el panel |
| **Analytics / Meta Pixel** | Métricas/ads | No instalado aún | Crear bajo cuentas del dueño |

## 2. Transferir el repositorio de GitHub

**Opción A (recomendada):** GitHub → repo → *Settings* → *Danger Zone* → **Transfer ownership** a la
cuenta del dueño.
**Opción B:** el dueño crea su cuenta y se le agrega como colaborador/propietario; luego se quita al
desarrollador.

## 3. Hosting y DNS (Cloudflare) y dominio (GoDaddy)

Desde 2026-10-16 el sitio se sirve desde **Cloudflare Workers** (solo archivos estáticos) y el DNS vive
en Cloudflare. El dominio `mundohogarstf.com` y el correo siguen en **GoDaddy**. Detalle completo en
`PROJECT_STATUS.md` → sección *Hosting*.

1. **Cloudflare:** la cuenta es de TIAF. Si la administra el desarrollador, agregar al dueño como
   miembro (*Manage Account → Members*) con rol de administrador, o pasar la cuenta a su email.
2. **Worker `mundo-hogar`:** está conectado al repo de GitHub (*Workers & Pages → mundo-hogar →
   Settings → Builds*). Si el repo cambia de dueño (punto 2), reconectar la integración con GitHub
   desde la cuenta nueva. Configuración de build: sin comando de build; `wrangler.jsonc` ya define todo.
3. **DNS:** verificar que sigan los registros del correo de GoDaddy (MX, SPF, DMARC y los 4 CNAME de
   `bounces.*` y `sable.*._domainkey`). Cualquier cambio de nameservers rompe el correo.
4. **GoDaddy:** confirmar que el dominio esté a nombre del negocio, con renovación automática y acceso
   del dueño. Los nameservers deben quedar apuntando a Cloudflare (`patryk` / `sreeni.ns.cloudflare.com`).
5. **Vercel (opcional):** el espejo `mundo-hogar-tan.vercel.app` no tiene dominio ni uso comercial.
   Se puede borrar el proyecto de la cuenta del desarrollador sin afectar al sitio; si se borra, quitar
   también `vercel.json` del repo.

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
- **Mercado Pago** (solo si se implementa checkout; irían en un Worker con código de servidor, como
  *secrets* de Cloudflare, NUNCA en el código): `MP_ACCESS_TOKEN`, `MP_PUBLIC_KEY`, `MP_WEBHOOK_SECRET`,
  `URL_SUCCESS`, `URL_FAILURE`, `URL_PENDING`.

## 7. Mercado Pago

- Usar **siempre la cuenta de Mercado Pago del negocio** (la que recibe el dinero).
- Generar credenciales en el panel de desarrolladores de Mercado Pago (modo prueba y producción).
- El **Access Token es secreto**: va en variables de entorno del servidor, nunca en el frontend ni
  en GitHub.

## 8. Dominio y emails

- El dominio en uso es `mundohogarstf.com` (ver punto 3). El canonical, el sitemap y las etiquetas OG
  usan el dominio sin `www`; `www` redirige con 301.
- El correo del dominio está en GoDaddy. Si se cambia de proveedor de correo, actualizar los registros
  MX/SPF/DMARC/DKIM en el DNS de Cloudflare, no en GoDaddy.
- El número de WhatsApp de la web se edita desde el panel (*Configuración*), sin tocar código.

## 9. Analytics y Meta Pixel (opcional, para ads)

Hoy **no están instalados**. Si se usan, crearlos bajo las cuentas del dueño (Google Analytics 4 /
Meta Business) y agregar el script en `index.html`. Relevante porque el negocio corre publicidad.

## 10. Checklist final de independencia

- [ ] Repo GitHub a nombre del dueño.
- [ ] Dueño con acceso de administrador a la cuenta de Cloudflare; Worker conectado al repo del dueño.
- [ ] Dominio en GoDaddy a nombre del negocio, con renovación automática.
- [ ] Proyecto de Vercel borrado o a nombre del dueño.
- [ ] Supabase transferido al dueño, admin del dueño creado.
- [ ] Admin del desarrollador desactivado.
- [ ] Mercado Pago = cuenta del negocio.
- [ ] Variables sensibles solo en entornos seguros (no en el código).
- [ ] Contraseñas rotadas y accesos del desarrollador removidos.
