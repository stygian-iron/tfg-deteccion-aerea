import sys
import os
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from database import Database
from structures import Detection, Alert, TrackedObject
import time

print("=== Test de base de datos ===\n")

# 1. Crear base de datos
db = Database("outputs/test.db")

# 2. Guardar detecciones de prueba
detecciones_prueba = [
    Detection(bbox=[320.0, 240.0, 80.0, 60.0], confidence=0.92,
              label="drone", class_id=0, timestamp=time.time(), frame_id=1),
    Detection(bbox=[150.0, 300.0, 60.0, 50.0], confidence=0.78,
              label="bird", class_id=1, timestamp=time.time(), frame_id=2),
    Detection(bbox=[500.0, 200.0, 90.0, 70.0], confidence=0.88,
              label="drone", class_id=0, timestamp=time.time(), frame_id=3),
]

for d in detecciones_prueba:
    db.guardar_deteccion(d)
print(f"Guardadas {len(detecciones_prueba)} detecciones")

# 3. Guardar alertas de prueba
alertas_prueba = [
    Alert(alert_id="ALT_001", track_id=1, label="drone",
          confidence=0.92, timestamp=time.time(), position=(320.0, 240.0)),
    Alert(alert_id="ALT_002", track_id=2, label="drone",
          confidence=0.88, timestamp=time.time(), position=(500.0, 200.0)),
]

for a in alertas_prueba:
    db.guardar_alerta(a)
print(f"Guardadas {len(alertas_prueba)} alertas")

# 4. Recuperar y mostrar datos
print("\n--- Últimas detecciones ---")
for d in db.obtener_detecciones(limit=3):
    print(f"  Frame {d['frame_id']}: {d['label']} ({d['confidence']:.0%})")

print("\n--- Últimas alertas ---")
for a in db.obtener_alertas(limit=2):
    print(f"  {a['alert_id']}: {a['label']} — severidad {a['severity']}")

# 5. Estadísticas
print("\n--- Estadísticas ---")
stats = db.estadisticas()
for key, val in stats.items():
    print(f"  {key}: {val}")

# 6. Limpiar archivo de prueba
os.remove("outputs/test.db")
print("\nArchivo de prueba eliminado")
print("\n=== Base de datos funciona correctamente ===")