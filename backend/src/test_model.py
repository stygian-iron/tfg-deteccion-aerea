import sys
import os
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from ultralytics import YOLO
import cv2

# cargamos el modelo entrenado
print("Cargando modelo...")
model = YOLO("../models/best.pt")
print(f"Modelo cargado — clases: {model.names}")


# descargamos una imagen de prueba con objetos voladores
# import urllib.request
# urllib.request.urlretrieve(
#     "https://www.smithsonianmag.com/air-space-magazine/attack-drone-snatching-eagles-180962543/",
#     "../outputs/test_drone.jpg"
# )
# print("Imagen de prueba descargada")

# ejecutamos la detección
results = model.predict(
    "../outputs/prueba4.jpg",
    conf=0.5,
    verbose=False
)

# mostramos resultados
print(f"\nObjetos detectados: {len(results[0].boxes)}")
for box in results[0].boxes:
    label = model.names[int(box.cls)]
    conf = float(box.conf)
    print(f"  → {label}: {conf:.0%} de confianza")

# guardamos imagen con overlays
results[0].save("../outputs/test_resultado4.jpg")
print("\nResultado guardado en outputs/test_resultado4.jpg")