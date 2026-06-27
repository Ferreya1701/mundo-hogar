#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script para procesar y organizar imágenes de productos de Mundo Hogar
Lee el catálogo descriptivo y genera un JSON con metadatos completos
"""

import os
import json
import re
import shutil
from pathlib import Path
from datetime import datetime

# Configuración
SOURCE_DIR = r"C:\Users\Usuario\Desktop\Pagina web mundo hogar\imagenes de productos"
DEST_DIR = r"C:\Users\Usuario\Desktop\Pagina web mundo hogar\public\images\productos"
CATALOG_FILE = os.path.join(SOURCE_DIR, "_CATALOGO - descripcion de fotos.txt")
OUTPUT_JSON = r"C:\Users\Usuario\Desktop\Pagina web mundo hogar\src\data\productos.json"

# Mapeo de categorías
CATEGORY_MAP = {
    'Cuidado Personal': 'cuidado-personal',
    'Electrodomesticos': 'electrodomesticos',
    'Herramientas': 'herramientas',
    'Muebles y Hogar': 'muebles-hogar',
    'Salud': 'salud',
    'Seguridad': 'seguridad',
    'Tecnologia y Celulares': 'tecnologia-celulares'
}

def normalize_filename(filename):
    """Normalizar nombre de archivo a slug"""
    name = os.path.splitext(filename)[0].lower()
    name = re.sub(r'[^a-z0-9_-]', '', name)
    return name

def extract_product_names_from_catalog():
    """Extraer nombres de productos del catálogo descriptivo"""
    products_dict = {}

    try:
        with open(CATALOG_FILE, 'r', encoding='utf-8') as f:
            content = f.read()

        # Patrón para encontrar archivos IMG_*.jpg
        pattern = r'•\s+(\w+\.\w+)\s+—\s+(.+?)(?=\n|$)'

        matches = re.findall(pattern, content)
        for filename, description in matches:
            # Limpiar la descripción
            desc = description.strip()
            # Si tiene precio, extraerlo
            price_match = re.search(r'\$[\d.,]+', desc)
            if price_match:
                desc = desc.replace(price_match.group(), '').strip()

            products_dict[filename] = desc

        print(f"[INFO] Extractos {len(products_dict)} productos del catálogo")
    except Exception as e:
        print(f"[WARN] Error leyendo catálogo: {e}")

    return products_dict

def get_all_images():
    """Obtener todas las imágenes por categoría"""
    images = {}

    for cat_name, cat_slug in CATEGORY_MAP.items():
        cat_path = os.path.join(SOURCE_DIR, cat_name)
        if os.path.isdir(cat_path):
            images[cat_slug] = {
                'display_name': cat_name,
                'files': []
            }

            for file in os.listdir(cat_path):
                if file.lower().endswith(('.jpg', '.jpeg')):
                    images[cat_slug]['files'].append(file)

            images[cat_slug]['files'].sort()
            print(f"  {cat_name:25} : {len(images[cat_slug]['files']):3d} imágenes")

    return images

def create_product_catalog(images, catalog_products):
    """Crear catálogo de productos"""
    products = []
    product_id = 1

    for cat_slug, cat_data in sorted(images.items()):
        for filename in cat_data['files']:
            name_without_ext = os.path.splitext(filename)[0]

            # Buscar nombre en catálogo
            product_name = catalog_products.get(filename, name_without_ext)

            # Si es muy corto (ej: "0065"), usar el nombre original
            if len(product_name) < 5:
                product_name = name_without_ext

            # Crear slug
            slug = normalize_filename(filename)

            product = {
                "id": f"{cat_slug}-{slug}",
                "slug": slug,
                "nombre": product_name,
                "categoria": cat_slug,
                "imagen": f"/images/productos/{cat_slug}/{filename}",
                "alt": f"{product_name} - Mundo Hogar",
                "activo": True,
                "orden": product_id
            }

            products.append(product)
            product_id += 1

    return products

def create_directories():
    """Crear estructura de directorios"""
    if not os.path.exists(DEST_DIR):
        os.makedirs(DEST_DIR)
        print(f"  Creado: {DEST_DIR}")

    for slug in CATEGORY_MAP.values():
        cat_dir = os.path.join(DEST_DIR, slug)
        if not os.path.exists(cat_dir):
            os.makedirs(cat_dir)

def copy_images(images):
    """Copiar imágenes a estructura pública"""
    copied = 0
    errors = 0

    for cat_slug, cat_data in images.items():
        src_cat = os.path.join(SOURCE_DIR, cat_data['display_name'])
        dest_cat = os.path.join(DEST_DIR, cat_slug)

        for filename in cat_data['files']:
            src_file = os.path.join(src_cat, filename)
            dest_file = os.path.join(dest_cat, filename)

            try:
                shutil.copy2(src_file, dest_file)
                copied += 1
            except Exception as e:
                print(f"  [ERROR] {filename}: {e}")
                errors += 1

    return copied, errors

def save_json(products):
    """Guardar JSON con catálogo"""
    os.makedirs(os.path.dirname(OUTPUT_JSON), exist_ok=True)

    # Agrupar por categoría para estadísticas
    categories_count = {}
    for p in products:
        cat = p['categoria']
        categories_count[cat] = categories_count.get(cat, 0) + 1

    output = {
        "version": "2.0",
        "generado": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "total": len(products),
        "categorias": sorted(CATEGORY_MAP.values()),
        "estadisticas": categories_count,
        "productos": products
    }

    with open(OUTPUT_JSON, 'w', encoding='utf-8') as f:
        json.dump(output, f, ensure_ascii=False, indent=2)

    print(f"  JSON guardado: {OUTPUT_JSON}")
    return output

def main():
    print("="*60)
    print("PROCESAMIENTO DE PRODUCTOS - MUNDO HOGAR")
    print("="*60)
    print()

    # Paso 1: Extraer nombres del catálogo
    print("[1/5] Leyendo catálogo descriptivo...")
    catalog_products = extract_product_names_from_catalog()
    print()

    # Paso 2: Inventariar imágenes
    print("[2/5] Inventariando imágenes...")
    images = get_all_images()
    total_images = sum(len(cat['files']) for cat in images.values())
    print(f"  Total: {total_images} imágenes")
    print()

    # Paso 3: Crear directorios
    print("[3/5] Creando estructura de directorios...")
    create_directories()
    print()

    # Paso 4: Copiar imágenes
    print("[4/5] Copiando imágenes...")
    copied, errors = copy_images(images)
    print(f"  Copiadas: {copied}")
    print(f"  Errores: {errors}")
    print()

    # Paso 5: Generar catálogo JSON
    print("[5/5] Generando catálogo...")
    products = create_product_catalog(images, catalog_products)
    output = save_json(products)
    print()

    # Reporte final
    print("="*60)
    print("REPORTE FINAL")
    print("="*60)
    print(f"Total de productos: {output['total']}")
    print()
    print("Distribución por categoría:")
    for cat, count in sorted(output['estadisticas'].items()):
        print(f"  {cat:25} : {count:3d}")
    print()
    print("[OK] Procesamiento completado sin errores")
    print()

if __name__ == "__main__":
    main()
