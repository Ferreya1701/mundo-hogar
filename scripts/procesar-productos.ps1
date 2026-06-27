# Script para procesar y organizar imágenes de productos
# Este script:
# - Lee las imágenes de las carpetas de categoría
# - Las organiza en public/images/productos/
# - Genera un JSON con el catálogo
# - Detecta y reporta problemas

param(
    [string]$SourcePath = "C:\Users\Usuario\Desktop\Pagina web mundo hogar\imagenes de productos",
    [string]$DestPath = "C:\Users\Usuario\Desktop\Pagina web mundo hogar\public\images\productos",
    [string]$OutputJson = "C:\Users\Usuario\Desktop\Pagina web mundo hogar\src\data\productos.json"
)

$ErrorActionPreference = "Continue"
$WarningPreference = "Continue"

# Categorías válidas (de las carpetas existentes)
$validCategories = @(
    'Cuidado Personal',
    'Electrodomesticos',
    'Herramientas',
    'Muebles y Hogar',
    'Salud',
    'Seguridad',
    'Tecnologia y Celulares'
)

# Mapeo a slugs normalizados
$categoryMapping = @{
    'Cuidado Personal' = 'cuidado-personal'
    'Electrodomesticos' = 'electrodomesticos'
    'Herramientas' = 'herramientas'
    'Muebles y Hogar' = 'muebles-hogar'
    'Salud' = 'salud'
    'Seguridad' = 'seguridad'
    'Tecnologia y Celulares' = 'tecnologia-celulares'
}

Write-Host "=== PROCESAMIENTO DE PRODUCTOS ===" -ForegroundColor Cyan
Write-Host "Fuente: $SourcePath"
Write-Host "Destino: $DestPath"
Write-Host "JSON: $OutputJson`n"

# 1. INVENTARIO
Write-Host "PASO 1: Inventario de imágenes" -ForegroundColor Yellow

$allImages = @()
$categoryStats = @{}

foreach ($category in $validCategories) {
    $categoryPath = Join-Path $SourcePath $category
    if (Test-Path $categoryPath) {
        $images = Get-ChildItem -Path $categoryPath -Filter "*.jpg" -File
        $categoryStats[$category] = $images.Count
        Write-Host "  $category : $($images.Count) imágenes"

        foreach ($img in $images) {
            $allImages += [PSCustomObject]@{
                Category = $category
                Filename = $img.Name
                Path = $img.FullName
                Size = $img.Length
            }
        }
    }
}

Write-Host "`nTotal de imágenes encontradas: $($allImages.Count)`n"

# 2. CREAR ESTRUCTURA DE DIRECTORIOS
Write-Host "PASO 2: Crear estructura de directorios" -ForegroundColor Yellow

if (-not (Test-Path $DestPath)) {
    New-Item -ItemType Directory -Path $DestPath -Force | Out-Null
    Write-Host "  Directorio creado: $DestPath"
}

foreach ($category in $validCategories) {
    $slug = $categoryMapping[$category]
    $catPath = Join-Path $DestPath $slug
    if (-not (Test-Path $catPath)) {
        New-Item -ItemType Directory -Path $catPath -Force | Out-Null
        Write-Host "  Creada carpeta: $slug"
    }
}

Write-Host ""

# 3. GENERAR CATÁLOGO DE PRODUCTOS
Write-Host "PASO 3: Generar catálogo de productos" -ForegroundColor Yellow

$products = @()
$productCount = 0

foreach ($img in $allImages) {
    $productCount++
    $category = $img.Category
    $categorySlug = $categoryMapping[$category]
    $filename = [System.IO.Path]::GetFileNameWithoutExtension($img.Filename)

    # Normalizar nombre del producto a partir del nombre del archivo
    $productName = $filename `
        -replace '_', ' ' `
        -replace 'IMG-', '' `
        -replace '^IMG', '' `
        -replace '^\d+', '' `
        -replace '^\s+', '' `
        -replace '\s+', ' '

    # Si el nombre es solo números o muy corto, usar el nombre original
    if ([string]::IsNullOrWhiteSpace($productName) -or $productName.Length -lt 3) {
        $productName = $filename
    }

    # Crear slug del producto
    $productSlug = $filename.ToLower()

    # Ruta de la imagen
    $imagePath = "/images/productos/$categorySlug/$productSlug.jpg"

    # Crear objeto de producto
    $product = [PSCustomObject]@{
        id = "$categorySlug-$productSlug"
        slug = $productSlug
        nombre = $productName
        categoria = $categorySlug
        imagen = $imagePath
        alt = "$productName - Mundo Hogar"
        activo = $true
        orden = $productCount
    }

    $products += $product
}

Write-Host "  Total de productos generados: $($products.Count)`n"

# 4. COPIAR IMÁGENES
Write-Host "PASO 4: Copiar imágenes a estructura pública" -ForegroundColor Yellow

$copiedCount = 0
$errorCount = 0

foreach ($img in $allImages) {
    $category = $img.Category
    $categorySlug = $categoryMapping[$category]
    $filename = [System.IO.Path]::GetFileNameWithoutExtension($img.Filename)

    $destFile = Join-Path (Join-Path $DestPath $categorySlug) "$filename.jpg"

    try {
        Copy-Item -Path $img.Path -Destination $destFile -Force -ErrorAction Stop
        $copiedCount++
    } catch {
        Write-Host "  ERROR al copiar: $($img.Filename) - $_" -ForegroundColor Red
        $errorCount++
    }
}

Write-Host "  Imágenes copiadas: $copiedCount"
Write-Host "  Errores: $errorCount`n"

# 5. CREAR JSON
Write-Host "PASO 5: Generar archivo JSON" -ForegroundColor Yellow

# Crear directorio de destino del JSON si no existe
$jsonDir = Split-Path -Parent $OutputJson
if (-not (Test-Path $jsonDir)) {
    New-Item -ItemType Directory -Path $jsonDir -Force | Out-Null
}

# Crear estructura JSON
$json = @{
    version = "1.0"
    generado = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    total = $products.Count
    categorias = @($categoryMapping.Values | Sort-Object)
    productos = $products
} | ConvertTo-Json -Depth 10

# Guardar JSON
$json | Set-Content -Path $OutputJson -Encoding UTF8
Write-Host "  JSON creado: $OutputJson"
Write-Host "  Productos en JSON: $($products.Count)`n"

# 6. REPORTE
Write-Host "=== REPORTE FINAL ===" -ForegroundColor Green
Write-Host "Imágenes procesadas: $($allImages.Count)"
Write-Host "Productos generados: $($products.Count)"
Write-Host "Imágenes copiadas: $copiedCount"
Write-Host "Errores: $errorCount"
Write-Host ""
Write-Host "Distribución por categoría:"
foreach ($cat in $categoryMapping.Keys) {
    $count = $categoryStats[$cat]
    Write-Host "  $cat : $count"
}
Write-Host ""
Write-Host "[OK] Procesamiento completado" -ForegroundColor Green
