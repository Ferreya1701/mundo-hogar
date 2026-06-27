# Actualizar JSON con nombres descriptivos del catálogo

$catalogFile = "C:\Users\Usuario\Desktop\Pagina web mundo hogar\imagenes de productos\_CATALOGO - descripcion de fotos.txt"
$jsonFile = "C:\Users\Usuario\Desktop\Pagina web mundo hogar\src\data\productos.json"

Write-Host "Leyendo catálogo..." -ForegroundColor Yellow

# Mapeo manual basado en el catálogo (IMG_XXXX -> Descripción)
$nameMapping = @{
    'IMG_0031.jpg' = 'Cocina a gas PEABODY negra 4 hornallas'
    'IMG_0064.jpg' = 'Cafetera de cápsulas KANJI HOME blanca/negra'
    'IMG_0068.jpg' = 'Balanza comercial Vestax Ecostar 40 kg'
    'IMG_0070.jpg' = 'Urna/percoladora grande inox con canilla'
    'IMG_0114.jpg' = 'Freezer horizontal KANJI HOME blanco'
    'IMG_0156.jpg' = 'Air fryer doble canasta Westinghouse negro'
    'IMG_0159.jpg' = 'Air fryer doble canasta Westinghouse abierto'
    'IMG_0173.jpg' = 'Batidora de pie con bowl KANJI HOME blanca'
    'IMG_0180.jpg' = 'Air fryer KANJI HOME negro/inox'
    'IMG_0185.jpg' = 'Sandwichera/grill 3-en-1 negra con placas'
    'IMG_0190.jpg' = 'Máquina para pasta KANJI HOME roja'
    'IMG_0195.jpg' = 'Pava eléctrica KANJI inox/negra'
    'IMG_0265.jpg' = 'Espumador de leche Ultracomb EL-8501 inox'
    'IMG_0280.jpg' = 'Aspiradora Yelmo gris/rosa multiciclónica'
    'IMG_0283.jpg' = 'Cafetera espresso Ultracomb con pantalla táctil'
    'IMG_0285.jpg' = 'Anafe de inducción Ultracomb negro 1 hornalla'
    'IMG_0289.jpg' = 'Air fryer Yelmo lila/violeta redondo'
    'IMG_0292.jpg' = 'Air fryer Yelmo verde menta cuadrado'
    'IMG_0295.jpg' = 'Air fryer Yelmo lila/violeta cuadrado'
    'IMG_0303.jpg' = 'Cortadora de fiambre/embutidos Ultracomb inox'
    'IMG_0306.jpg' = 'Procesadora/ralladora Ultracomb blanca/roja'
    'IMG_0312.jpg' = 'Yogurtera Ultracomb inox con 7 frasquitos'
    'IMG_0318.jpg' = 'Anafe vitrocerámica Ultracomb AN-E604 4 hornallas'
    'IMG_0391.jpg' = 'Mixer de mano Liliana EasyHome blanco/negro'
    'IMG_0595.jpg' = 'Microondas KANJI HOME blanco/negro cerrado'
    'IMG_0596.jpg' = 'Microondas KANJI HOME blanco/negro abierto'
    'IMG_0599.jpg' = 'Plancha a vapor KANJI HOME verde/azul oscuro'
    'IMG_0604.jpg' = 'Set de ollas marmoladas negras + sartén'
    'IMG_0606.jpg' = 'Set de ollas crema con asas/tapa madera'
    'IMG_0754.jpg' = 'Secarropas centrífuga Codini 6,5 kg blanca'
    'IMG_0759.jpg' = 'Secarropas + lavarropas Codini dúo blanco'
    'IMG_0765.jpg' = 'Lavarropas carga superior Codini blanco'
    'IMG_0817.jpg' = 'Anafe vitrocerámica Ultracomb AN-E604'
    'IMG_0909.jpg' = 'Calefactor eléctrico cerámico/cuarzo negro'
    'IMG_0922.jpg' = 'Batidora de mano Yelmo celeste/turquesa'
    'IMG_0941.jpg' = 'Air fryer Yelmo violeta con ventana negra'
    'IMG_0942.jpg' = 'Licuadora de vidrio Yelmo rosa/salmón'
    'IMG_0946.jpg' = 'Pava eléctrica Ultracomb inox 1,7 L'
    'IMG_0951.jpg' = 'Panificadora Ultracomb celeste abierta'
    'IMG_0954.jpg' = 'Juguera/extractor de jugos Ultracomb inox'
    'IMG_0958.jpg' = 'Molinillo de café/especias Ultracomb inox'
    'IMG_0959.jpg' = 'Mini picadora/procesadora Ultracomb naranja'
    'IMG_0962.jpg' = 'Tostadora Ultracomb roja 2 ranuras'
    'IMG_0974.jpg' = 'Horno eléctrico Yelmo YL-45AN negro'
    'IMG_0975.jpg' = 'Horno eléctrico Yelmo YL-45AN gris'
    'IMG_1023.jpg' = 'Cafetera de filtro whiterblack negra'
    'IMG_1026.jpg' = 'Robot de cocina Liliana con licuadora'
    'IMG_1036.jpg' = 'Wafflera corazón negra'
    'IMG_1043.jpg' = 'Grill eléctrico redondo Liliana dorado'
    'IMG_1046.jpg' = 'Pava eléctrica Liliana inox'
    'IMG_1051.jpg' = 'Panificadora Liliana Breadly blanca'
    'IMG_1053.jpg' = 'Panificadora Liliana Breadly blanca abierta'
    'IMG_1439.jpg' = 'Vitrinas refrigeradas Pioneer Home'
    'IMG_1440.jpg' = 'Heladera Pioneer Home 2 puertas inox'

    # Herramientas
    'IMG_0178.jpg' = 'Sierra caladora KANJI TOOLS negra'
    'IMG_0357.jpg' = 'Amoladora angular Black+Decker naranja/negro'
    'IMG_0363.jpg' = 'Inflador a batería INGCO 20V con bolso'
    'IMG_0371.jpg' = 'Cutter/trincheta INGCO HKNS1806'
    'IMG_0372.jpg' = 'Set 2 pinzas INGCO pinza diagonal'
    'IMG_0376.jpg' = 'Hidrolavadora a batería INGCO'
    'IMG_0431.jpg' = 'Taladro/atornilladora Bauen 20V'

    # Tecnología
    'IMG_0127.jpg' = 'Auriculares TWS inalámbricos negros'
    'IMG_0429.jpg' = 'Soporte TV para pared LED/LCD/PDP'
    'IMG_0618.jpg' = 'Tablet con funda transparente verde lima'
    'IMG_0619.jpg' = 'Funda/case para tablet verde lima origami'
    'IMG_1431.jpg' = 'Smart TV Enova Google TV 50"'

    # Muebles
    'IMG_0036.jpg' = 'Colchón 1 plaza azul/celeste con sommier'
    'IMG_0038.jpg' = 'Colchón 1 plaza azul/celeste con sommier'
    'IMG_0053.jpg' = 'Sofá 2 cuerpos gris oscuro'
    'IMG_0061.jpg' = 'Termo Stanley verde menta con taza'
    'IMG_0063.jpg' = 'Termo acero inox con asa negra'
    'IMG_0076.jpg' = 'Bicicleta AZR mountain bike negra/azul'
    'IMG_0089.jpg' = 'Canilla extensible cromada tipo industrial'
    'IMG_0395.jpg' = 'Silla de jardín plástico negra'
    'IMG_0507.jpg' = 'Silla gamer CL negro/blanco'
    'IMG_0523.jpg' = 'Silla gamer CL negro con luces RGB'
    'IMG_0554.jpg' = 'Canilla monomando alta cromada'
    'IMG_0682.jpg' = 'Silla negra estilo Masters plástico'
    'IMG_0756.jpg' = 'Colchón + sommier gris/rojo/negro'
    'IMG_0778.jpg' = 'Colchón + sommier marrón'

    # Cuidado Personal
    'IMG_0065.jpg' = 'Rulero/rizador rosa fucsia doble barril'
    'IMG_0314.jpg' = 'Secador de pelo Yelmo lila Thermal Ion'
    'IMG_0316.jpg' = 'Secador de pelo Yelmo negro/antracita'
    'IMG_0550.jpg' = 'Cepillo secador volumizador Westinghouse'
    'IMG_0624.jpg' = 'Trimmer/recortadora de pelo dorado'
    'IMG_0629.jpg' = 'Secador Westinghouse negro/dorado + plancha'
    'IMG_0640.jpg' = 'Planchita de pelo KANJI HOME plateada'
    'IMG_0923.jpg' = 'Plancha onduladora/waver Yelmo gris/azul'
    'IMG_0932.jpg' = 'Kit Ultracomb Devotion secador + plancha'
    'IMG_0967.jpg' = 'Plancha de pelo Yelmo fucsia'

    # Salud
    'IMG_0572.jpg' = 'Tensiómetro digital Ecopower'
    'IMG_0581.jpg' = 'Nebulizador de pistón Ecopower'
    'IMG_0609.jpg' = 'Balanza personal digital vidrio KANJI'
}

Write-Host "Cargando JSON..." -ForegroundColor Yellow
$json = Get-Content $jsonFile -Raw -Encoding UTF8 | ConvertFrom-Json

Write-Host "Actualizando nombres de productos..." -ForegroundColor Yellow
$updated = 0

foreach ($producto in $json.productos) {
    $filename = Split-Path -Leaf $producto.imagen

    if ($nameMapping.ContainsKey($filename)) {
        $newName = $nameMapping[$filename]
        if ($producto.nombre -ne $newName) {
            $producto.nombre = $newName
            $producto.alt = "$newName - Mundo Hogar"
            $updated++
        }
    }
}

Write-Host "Productos actualizados: $updated"
Write-Host ""

Write-Host "Guardando JSON actualizado..." -ForegroundColor Yellow
$json | ConvertTo-Json -Depth 10 | Set-Content $jsonFile -Encoding UTF8

Write-Host "OK - Completado"
Write-Host ""
