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

Cloudflare despliega automáticamente cada push a `main` (Workers, proyecto `mundo-hogar`).

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

Accedé al panel en: `https://mundohogarstf.com/admin/`

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
| Ver inicio                       | ✅ | ✅ | ✅ |
| Ver productos                    | ✅ | ✅ | ✅ |
| Crear/editar productos           | ✅ | ✅ | ❌ |
| Archivar productos               | ✅ | ✅ | ❌ |
| Ajuste manual de stock           | ✅ | ✅ | ❌ |
| Contar stock / cargar compras    | ✅ | ✅ | ❌ |
| Caja (vender en el local)        | ✅ | ✅ | ✅ |
| Anular ventas                    | ✅ todas | solo propias < 24 h | solo propias < 24 h |
| Ver movimientos de stock         | ✅ | ✅ | ✅ |
| Ver qué reponer (Contar stock)   | ✅ | ✅ | ❌ |
| Gestionar categorías             | ✅ | ❌ | ❌ |
| Gestionar usuarios               | ✅ | ❌ | ❌ |

---

## 7. Módulos del panel

### Inicio (`/admin/dashboard`)
- KPIs: productos, sin precio, ventas de hoy, sin stock, sin contar, pedidos web nuevos
- Accesos rápidos, salud del catálogo, recomendaciones, actividad reciente
- Alertas de stock (las 8 más urgentes; "Ver todas" abre Contar stock con el filtro "Sin stock")

### Productos (`/admin/productos.html`)
- Lista con búsqueda, filtros por categoría/estado/stock
- Paginación (20 por página)
- Exportar CSV
- Importar desde JSON existente
- Activar/desactivar/archivar (no hay borrado permanente: una venta o compra puede apuntar al producto)
- Etiquetas con código de barras (🏷️ por fila o en la selección múltiple)

### Formulario de Producto (`/admin/producto-form.html`)
- Crear nuevo o editar existente
- Imagen: URL manual o subida a Supabase Storage
- Campos completos: precios, especificaciones, etc. El stock solo se muestra: se carga por
  Contar stock o al recibir una compra (un producto nuevo nace con 0 y "sin contar")
- Auto-generador de SKU
- Auto-generador de slug (URL)

### Categorías (`/admin/categorias.html`)
- CRUD completo de categorías
- Muestra cantidad de productos por categoría
- Protegida: solo Administrador

### Ajuste manual (`/admin/inventario`)
- Solo para lo que no pasa por Caja, Compras ni Contar stock: devolución de cliente, mercadería
  que apareció, producto dañado, pérdida, devolución a proveedor, ajuste negativo
- Búsqueda de producto en tiempo real y preview del stock antes/después
- Vista de movimientos del día

### Movimientos de stock (`/admin/movimientos`)
- Historial completo de todos los movimientos (ventas, compras, conteos y ajustes)
- Filtros: tipo, fecha desde/hasta, producto
- Exportar CSV
- Los movimientos son inmutables (no se pueden borrar)

### Usuarios (`/admin/usuarios.html`)
- Solo visible para Administradores
- Editar nombre, rol y estado de usuarios
- Instrucciones para crear nuevos usuarios vía Supabase

### Caja (`/admin/vender`)
- Buscar por nombre, SKU o código de barras (lector USB o cámara del celular), ticket con
  cantidades, precio editable, descuento, medio de pago, cliente opcional
- Al cobrar: imprimir ticket (rollo de 80 mm, `F8`), mandarlo por WhatsApp o copiarlo
- Descuenta stock solo de los productos con **stock controlado**; los demás se venden sin tocar stock
- Si el sistema dice 0 y el producto está, se vende igual y queda en negativo para revisar
- Requiere `sql/013-local-compras-stock.sql`. Guía: `GUIA-STOCK-Y-VENTAS.md`

### Ventas (`/admin/ventas`)
- Listado por rango de fechas, medio de pago, vendedor; KPIs; detalle con "Imprimir ticket";
  anular (repone stock); CSV

### Contar stock (`/admin/carga-stock`)
- Conteo absoluto desde el celular: filtros "Sin contar", "En negativo", "Sin stock", "Stock bajo";
  escaneo de códigos, alta rápida de productos. Reemplaza a la vieja página de Alertas
  (`/admin/alertas` redirige acá con el filtro "Sin stock")
- Al guardar, el producto queda con stock controlado (la tienda lo vende si hay)

### Compras (`/admin/compras`)
- Pegar/subir la lista del proveedor (Excel, CSV, foto o PDF con IA) → coincidencias con el catálogo →
  lo que no existe se crea como producto → al recibir, entra el stock y queda controlado
- En el detalle de la compra: 🏷️ Etiquetas imprime códigos de barras de lo que llegó

### Pedidos web (`/admin/pedidos`)
- Pedidos que llegan desde el carrito (antes "Solicitudes WhatsApp"), con estado del pedido y del pago
- Chip "Para revisar": comprobantes que esperan confirmación o rechazo
- Confirmar pago (pasa el pedido a confirmado y descuenta stock), rechazar comprobante, registrar
  pago a mano, habilitar pago de una cotización, anular pago (administrador)
- Plantillas de WhatsApp: datos para pagar, pedir comprobante, pago confirmado
- Requiere `sql/012-cobros.sql`. Guía completa: `GUIA-COBROS.md`

### Cuentas de cobro (`/admin/cuentas-cobro.html`)
- Solo visible para Administradores
- Cuentas (alias/CVU) a las que transfieren los clientes, con cobrado hoy/mes, pendiente y límites
- Movimientos por cuenta y mes (exportable), liquidación mensual con comisión, configuración de cobros

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
| Inicio           | `/admin/dashboard`                     |
| Productos        | `/admin/productos.html`                |
| Nuevo producto   | `/admin/producto-form.html`            |
| Editar producto  | `/admin/producto-form.html?id=123`     |
| Categorías       | `/admin/categorias.html`               |
| Ajuste manual    | `/admin/inventario`                    |
| Movimientos      | `/admin/movimientos`                   |
| Usuarios         | `/admin/usuarios.html`                 |
| Caja             | `/admin/vender`                        |
| Ventas           | `/admin/ventas`                        |
| Contar stock     | `/admin/carga-stock`                   |
| Compras          | `/admin/compras`                       |
| Pedidos web      | `/admin/pedidos`                       |
| Cuentas bancarias| `/admin/cuentas-cobro`                 |
| Clientes         | `/admin/crm`                           |

---

## Soporte técnico

Para problemas con la base de datos: revisar **Logs** en Supabase Dashboard.  
Para problemas de autenticación: revisar **Authentication → Logs**.
