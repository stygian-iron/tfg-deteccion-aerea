import numpy as np
from structures import ImageFrame, Detection, TrackedObject, Alert
import time

print("=== Test de estructuras ===\n")

# 1. Crear un frame de prueba
imagen_falsa = np.zeros((640, 640, 3), dtype=np.uint8)
frame = ImageFrame(
    frame_id=1,
    image=imagen_falsa,
    timestamp=time.time()
)
print(f"Frame creado: {frame.width}x{frame.height}px, id={frame.frame_id}")

# 2. Crear una detección de drone
deteccion = Detection(
    bbox=[320.0, 240.0, 80.0, 60.0],
    confidence=0.92,
    label="drone",
    class_id=0,
    timestamp=frame.timestamp,
    frame_id=frame.frame_id
)
print(f"Detección: {deteccion.label} ({deteccion.confidence:.0%}) en {deteccion.center}")
print(f"¿Supera umbral?: {deteccion.is_confident()}")

# 3. Crear un objeto trackeado y simular movimiento
tracker = TrackedObject(track_id=1, first_detection=deteccion)

# simulamos 5 frames de movimiento
for i in range(1, 6):
    nueva_deteccion = Detection(
        bbox=[320.0 + i*15, 240.0 + i*8, 80.0, 60.0],
        confidence=0.90,
        label="drone",
        class_id=0,
        timestamp=frame.timestamp + i * 0.033  # ~30fps
    )
    tracker.update(nueva_deteccion, fps=30.0)

tel = tracker.latest_telemetry
print(f"\nTelemetría tras 5 frames:")
print(f"  Velocidad: {tel.velocity_px:.1f} px/frame → {tel.velocity_ms} m/s")
print(f"  Dirección: {tel.direction_deg}°")
print(f"  Distancia estimada: {tel.estimated_distance_m} m")
print(f"  Tiempo en escena: {tracker.time_in_scene} s")

# 4. Generar una alerta
alerta = Alert(
    alert_id="ALT_001",
    track_id=tracker.track_id,
    label=tracker.label,
    confidence=deteccion.confidence,
    timestamp=time.time(),
    position=deteccion.center
)
print(f"\nAlerta generada: {alerta.alert_id}")
print(f"  Severidad: {alerta.severity}")
print(f"  Objeto: {alerta.label} con {alerta.confidence:.0%} de confianza")

print("\n=== Todas las estructuras funcionan correctamente ===")