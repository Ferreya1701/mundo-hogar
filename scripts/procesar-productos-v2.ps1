# Script mejorado para procesar productos con nombres del catálogo

$SourcePath = "C:\Users\Usuario\Desktop\Pagina web mundo hogar\imagenes de productos"
$DestPath = "C:\Users\Usuario\Desktop\Pagina web mundo hogar\public\images\productos"
$CatalogFile = Join-Path $SourcePath "_CATALOGO - descripcion de fotos.txt"
$OutputJson = "C:\Users\Usuario\Desktop\Pagina web mundo hogar\src\data\productos.json"

Write-Host "=== PROCESAMIENTO DE PRODUCTOS (V2) ===" -ForegroundColor Cyan

# Leer catálogo y extraer nombres
Write-Host "PASO 1: Extrayendo nombres del catálogo..." -ForegroundColor Yellow
$catalogContent = Get-Content $CatalogFile -Raw -Encoding UTF8
$nameMapping = @{}

# Buscar líneas que contienen "IMG_*.jpg — descripcion"
$lines = $catalogContent -split "`n"
foreach ($line in $lines) {
    if ($line -match '•\s+(IMG_\d+\.jpg)\s+—\s+(.+?)(?:\s*\$[\d.,]+)?$') {
        $filename = $matches[1]
        $description = $matches[2].Trim()
        # Limpiar precio de la descripción si existe
        $description = $description -replace '\s*\$[\d.,]+\s*$', ''
        $nameMapping[$filename] = $description
    }
}

Write-Host "  Nombres extraídos del catálogo: $($nameMapping.Count)"
Write-Host ""

# Mapeo de categorías
$categoryMapping = @{
    'Cuidado Personal' = 'cuidado-personal'
    'Electrodomesticos' = 'electrodomesticos'
    'Herramientas' = 'herramientas'
    'Muebles y Hogar' = 'muebles-hogar'
    'Salud' = 'salud'
    'Seguridad' = 'seguridad'
    'Tecnologia y Celulares' = 'tecnologia-celulares'
}

# PASO 2: Inventariar imágenes
Write-Host "PASO 2: Inventariando imágenes..." -ForegroundColor Yellow
$allImages = @()
$categoriesFound = @{}

foreach ($catName in $categoryMapping.Keys) {
    $catPath = Join-Path $SourcePath $catName
    if (Test-Path $catPath) {
        $images = Get-ChildItem -Path $catPath -Filter "*.jpg" -File
        $catSlug = $categoryMapping[$catName]
        $categoriesFound[$catSlug] = $images.Count

        foreach ($img in $images) {
            $allImages += [PSCustomObject]@{
                Category = $catSlug
                DisplayName = $catName
                Filename = $img.Name
                Path = $img.FullName
            }
        }
    }
}

$totalImages = $allImages.Count
Write-Host "  Total encontrado: $totalImages imágenes"
Write-Host ""

# PASO 3: Crear estructura
Write-Host "PASO 3: Creando estructura de directorios..." -ForegroundColor Yellow
if (-not (Test-Path $DestPath)) {
    New-Item -ItemType Directory -Path $DestPath -Force | Out-Null
}
foreach ($slug in $categoryMapping.Values) {
    $catPath = Join-Path $DestPath $slug
    if (-not (Test-Path $catPath)) {
        New-Item -ItemType Directory -Path $catPath -Force | Out-Null
    }
}
Write-Host "  Directorios listos"
Write-Host ""

# PASO 4: Generar catálogo de productos
Write-Host "PASO 4: Generando catálogo de productos..." -ForegroundColor Yellow
$products = @()
$productId = 1

foreach ($img in $allImages) {
    $filename = $img.Filename
    $filenameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($filename)
    $category = $img.Category

    # Buscar nombre en el mapeo
    $productName = if ($nameMapping.ContainsKey($filename)) {
        $nameMapping[$filename]
    } else {
        # Fallback: usar nombre del archivo normalizado
        $filenameNoExt -replace '_', ' ' -replace '^\d+', ''
    }

    $slug = $filenameNoExt.ToLower()

    $product = @{
        id = "$category-$slug"
        slug = $slug
        nombre = $productName
        categoria = $category
        imagen = "/images/productos/$category/$filename"
        alt = "$productName - Mundo Hogar"
        activo = $true
        orden = $productId
    }

    $products += $product
    $productId++
}

Write-Host "  Productos generados: $($products.Count)"
Write-Host ""

# PASO 5: Copiar imágenes
Write-Host "PASO 5: Copiando imágenes..." -ForegroundColor Yellow
$copiedCount = 0
$errorCount = 0

foreach ($img in $allImages) {
    $destFile = Join-Path (Join-Path $DestPath $img.Category) $img.Filename
    try {
        Copy-Item -Path $img.Path -Destination $destFile -Force -ErrorAction Stop
        $copiedCount++
    } catch {
        Write-Host "  ERROR: $($img.Filename)" -ForegroundColor Red
        $errorCount++
    }
}

Write-Host "  Copiadas: $copiedCount"
Write-Host "  Errores: $errorCount"
Write-Host ""

# PASO 6: Crear JSON
Write-Host "PASO 6: Generando JSON..." -ForegroundColor Yellow

$jsonDir = Split-Path -Parent $OutputJson
if (-not (Test-Path $jsonDir)) {
    New-Item -ItemType Directory -Path $jsonDir -Force | Out-Null
}

$jsonOutput = @{
    version = "2.0"
    generado = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    total = $products.Count
    categorias = @($categoryMapping.Values | Sort-Object)
    estadisticas = $categoriesFound
    productos = $products
}

$json = $jsonOutput | ConvertTo-Json -Depth 10
$json | Set-Content -Path $OutputJson -Encoding UTF8

Write-Host "  JSON guardado: $OutputJson"
Write-Host ""

# REPORTE FINAL
Write-Host "=== REPORTE FINAL ===" -ForegroundColor Green
Write-Host "Total de productos: $($products.Count)"
Write-Host ""
Write-Host "Distribución por categoría:"
foreach ($catName in ($categoryMapping.Keys | Sort-Object)) {
    $slug = $categoryMapping[$catName]
    $count = $categoriesFound[$slug]
    Write-Host "  $catName : $count"
}
Write-Host ""
Write-Host "[OK] Procesamiento completado"
