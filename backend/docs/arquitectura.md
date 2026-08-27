# Arquitectura del sistema

## Flujo de datos
Cámara → ImageFrame → YOLO detecta → Detection → TrackedObject → Telemetría → API → App móvil

## Archivos del proyecto

### structures.py — Las clases de datos
Define la forma de todos los datos del sistema.
- **ImageFrame**: envuelve cada imagen de la cámara con sus metadatos (timestamp, resolución, id)
- **Detection**: un objeto detectado por YOLO (bbox, confianza, etiqueta)
- **TelemetrySnapshot**: datos de telemetría en un instante (velocidad, dirección, distancia)
- **TrackedObject**: historial de un objeto a lo largo de varios frames, calcula telemetría
- **Alert**: notificación generada cuando la confianza supera el umbral

### config.py — Configuración central
Centraliza todos los parámetros del sistema en un solo lugar.
Parámetros clave:
- CONFIDENCE_THRESHOLD = 0.60 (umbral mínimo de detección)
- ALERT_THRESHOLD = 0.85 (umbral para generar alerta)
- PIXELS_PER_METER = 20.0 (calibración para telemetría)

### detector.py — El cerebro del sistema
Conecta YOLO con las estructuras de datos.
- process_frame(): recibe un ImageFrame, llama a YOLO, devuelve lista de Detection
- render_overlay(): dibuja bounding boxes y telemetría sobre el frame con OpenCV

### api.py — Puente con la app móvil
Expone el detector como servicio web con FastAPI.
- GET /status: estado del sistema
- GET /alerts: historial de alertas
- WS /stream: WebSocket para recibir frames y devolver detecciones en tiempo real

### database.py — Memoria del sistema
Guarda el historial en SQLite.
Tablas: detecciones, alertas, telemetria

## Decisiones técnicas tomadas
- YOLOv8s como modelo base (equilibrio velocidad/precisión)
- Transfer learning con freeze=10 (congela las primeras 10 capas)
- Dataset: Drone-vs-Birds por ElieSaade (13.420 imágenes, CC BY 4.0)
- WebSocket para streaming en tiempo real (conexión permanente vs HTTP)
- SQLite para almacenamiento local (sin servidor, ideal para TFG)
- Opción A para app móvil: IA corre en servidor, móvil solo muestra resultados