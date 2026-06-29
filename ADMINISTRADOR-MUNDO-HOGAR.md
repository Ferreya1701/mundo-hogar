# Panel de Administración — Mundo Hogar

Guía completa de configuración y uso del panel admin.

---

## Índice

1. [Configuración inicial (Supabase)](#1-configuración-inicial)
2. [Crear la base de datos](#2-crear-la-base-de-datos)
3. [Configurar el proyecto](#3-configurar-el-proyecto)
4. [Crear primer administrador](#4-crear-primer-administrador)
5. [Importar productos existentes](#5-importar-productos-existentes)
6. [Roles y permisos](#6-roles-y-permisos)
7. [Módulos del panel](#7-módulos-del-panel)
8. [Seguridad](#8-seguridad)

---

## 1. Configuración inicial

### Paso 1 — Crear cuenta en Supabase (gratuito)

1. Ir a [supabase.com](https://supabase.com) y crear una cuenta
2. Crear un nuevo proyecto:
   - Nombre: `mundo-hogar`
   - Contraseña DB: elegir una segura (guardala, la necesitás)
   - Región: `South America (São Paulo)` — más cercana a Argentina
3. Esperar ~2 minutos que el proyecto se inicialice

### Paso 2 — Obtener credenciales

1. En el panel de Supabase, ir a: **Settings** (⚙️) → **API**
2. Copiar:
   - **Project URL** → `https://XXXXXXXX.supabase.co`
   - **anon / public key** → `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...`

---

## 2. Crear la base de datos

En Supabase, ir a **SQL Editor** y ejecutar los archivos en orden:

### 2.1 — Ejecutar `sql/001-schema.sql`
Crea todas las tablas, índices, funciones y triggers.

### 2.2 — Ejecutar `sql/002-rls-policies.sql`
Configura las políticas de seguridad (Row Level Security).

### 2.3 — Ejecutar `sql/003-seed-datos.sql`
Inserta las 7 categorías iniciales.

### 2.4 — Crear bucket de Storage

En Supabase: **Storage** → **New bucket**
- **Nombre**: `producto-imagenes`
- **Public**: ✅ Activado (para que las imágenes sean accesibles)
- Hacer clic en **Save**

---

## 3. Configurar el proyecto

Editá el archivo `supabase-config.js` en la raíz del proyecto:

```javascript
const SUPABASE_URL      = 'https://TU-PROYECTO.supabase.co';
const SUPABASE_ANON_KEY = 'tu-anon-key-aqui';
```

> **Nota de seguridad**: La `anon key` está diseñada para ser pública. Los datos están
> protegidos por las políticas RLS (Row Level Security) en la base de datos.
> **Nunca uses la `service_role key` en este archivo.**

Luego hacé commit y push:
```bash
git add supabase-config.js
git commit -m "Configurar Supabase"
git push
```

Vercel desplegará automáticamente.

---

## 4. Crear primer administrador

### Paso 1 — Crear usuario en Supabase

1. Ir a **Authentication → Users → Add user**
2. Completar email y contraseña
3. Hacer clic en **Create user**

### Paso 2 — Asignar rol de Administrador

En **SQL Editor**, ejecutar:

```sql
UPDATE profiles 
SET rol = 'administrador', nombre = 'Tu Nombre Completo'
WHERE email = 'tu@email.com';
```

### Paso 3 — Iniciar sesión

Accedé al panel en: `https://tu-sitio.vercel.app/admin/`

---

## 5. Importar productos existentes

Una vez logueado como administrador:

1. Ir a **Productos → Importar JSON**
2. Hacer clic en **Importar ahora**
3. El sistema leerá `/src/data/productos.json` e importará los 122 productos

> Los productos importados desde JSON tendrán `stock_actual = 0`.  
> Usá el módulo **Inventario** para cargar el stock real de cada producto.

---

## 6. Roles y permisos

| Permiso                         | Administrador | Encargado de Stock | Vendedor |
|----------------------------------|:-------------:|:------------------:|:--------:|
| Ver dashboard                    | ✅ | ✅ | ✅ |
| Ver productos                    | ✅ | ✅ | ✅ |
| Crear/editar productos           | ✅ | ✅ | ❌ |
| Eliminar productos               | ✅ | ❌ | ❌ |
| Registrar movimientos de stock   | ✅ | ✅ | ❌ |
| Ver historial de movimientos     | ✅ | ✅ | ✅ |
| Ver alertas de stock             | ✅ | ✅ | ✅ |
| Gestionar categorías             | ✅ | ❌ | ❌ |
| Gestionar usuarios               | ✅ | ❌ | ❌ |

---

## 7. Módulos del panel

### Dashboard (`/admin/dashboard.html`)
- KPIs: total productos, sin stock, stock bajo, movimientos del día
- Gráfico de productos por categoría
- Alertas y últimos movimientos

### Productos (`/admin/productos.html`)
- Lista con búsqueda, filtros por categoría/estado/stock
- Paginación (20 por página)
- Exportar CSV
- Importar desde JSON existente
- Activar/desactivar/archivar
- Eliminar (con confirmación)

### Formulario de Producto (`/admin/producto-form.html`)
- Crear nuevo o editar existente
- Imagen: URL manual o subida a Supabase Storage
- Campos completos: precios, stock, especificaciones, etc.
- Auto-generador de SKU
- Auto-generador de slug (URL)

### Categorías (`/admin/categorias.html`)
- CRUD completo de categorías
- Muestra cantidad de productos por categoría
- Protegida: solo Administrador

### Inventario (`/admin/inventario.html`)
- Registro rápido de movimientos
- Búsqueda de producto en tiempo real
- Preview del stock antes/después
- 11 tipos de movimiento disponibles
- Vista de movimientos del día

### Historial (`/admin/movimientos.html`)
- Historial completo de todos los movimientos
- Filtros: tipo, fecha desde/hasta, producto
- Exportar CSV
- Los movimientos son inmutables (no se pueden borrar)

### Alertas de Stock (`/admin/alertas.html`)
- Tabs: Sin stock / Stock bajo / Todos
- KPIs rápidos de estado
- Exportar lista de alertas

### Usuarios (`/admin/usuarios.html`)
- Solo visible para Administradores
- Editar nombre, rol y estado de usuarios
- Instrucciones para crear nuevos usuarios vía Supabase

---

## 8. Seguridad

### Qué está protegido

- **Contraseñas**: nunca almacenadas en texto plano (gestionadas por Supabase Auth con bcrypt)
- **Sesiones**: JWT con expiración automática
- **Datos**: protegidos por RLS — si alguien obtiene la anon key, solo puede ver productos activos públicos
- **Admin**: los endpoints de administración requieren sesión autenticada con rol apropiado
- **Imágenes privadas**: el bucket es público (acceso de lectura a URLs conocidas) pero la escritura requiere autenticación

### Qué NO hacer

- ❌ Nunca pongas la `service_role key` en ningún archivo del frontend
- ❌ Nunca deshabilites el RLS en las tablas
- ❌ No compartas el acceso al Supabase Dashboard con usuarios de confianza limitada

### Recomendaciones

- Cambiar contraseñas por defecto después del primer login
- Usar contraseñas fuertes para todos los usuarios del admin
- Revisar el historial de actividad periódicamente
- El historial de movimientos de stock es inmutable (no se puede borrar)

---

## URLs del panel

| Página           | URL                                    |
|------------------|----------------------------------------|
| Login            | `/admin/`                              |
| Dashboard        | `/admin/dashboard.html`                |
| Productos        | `/admin/productos.html`                |
| Nuevo producto   | `/admin/producto-form.html`            |
| Editar producto  | `/admin/producto-form.html?id=123`     |
| Categorías       | `/admin/categorias.html`               |
| Registrar stock  | `/admin/inventario.html`               |
| Historial        | `/admin/movimientos.html`              |
| Alertas          | `/admin/alertas.html`                  |
| Usuarios         | `/admin/usuarios.html`                 |

---

## Soporte técnico

Para problemas con la base de datos: revisar **Logs** en Supabase Dashboard.  
Para problemas de autenticación: revisar **Authentication → Logs**.
