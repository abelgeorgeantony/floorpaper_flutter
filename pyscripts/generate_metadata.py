import os
import json
from PIL import Image

TILE_DIR = '../assets/tiles'
OUTPUT = '../assets/tiles.json'

# Ensure the directory exists
os.makedirs(TILE_DIR, exist_ok=True)

tiles = []

# Supported extensions
valid_extensions = ('.webp', '.png', '.jpg', '.jpeg')

for filename in sorted(os.listdir(TILE_DIR)):
    if filename.lower().endswith(valid_extensions):
        filepath = os.path.join(TILE_DIR, filename)
        
        # Read dimensions using Pillow
        with Image.open(filepath) as img:
            width, height = img.size
            
        tile_id = os.path.splitext(filename)[0]
        
        tiles.append({
            "id": tile_id,
            # Replace underscores with spaces and title-case for the name
            "name": tile_id.replace('_', ' ').title(), 
            "asset": f"assets/tiles/{filename}",
            "width": width,
            "height": height
        })

# Write to JSON
with open(OUTPUT, 'w') as f:
    json.dump(tiles, f, indent=2)

print(f"Successfully generated {OUTPUT} with {len(tiles)} tiles.")