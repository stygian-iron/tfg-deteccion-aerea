# TFG — Detección de Objetos Aéreos con Visión Artificial

Sistema de detección en tiempo real de drones y aves mediante YOLOv8,
con telemetría integrada y visualización en app móvil.

## Descripción
Este proyecto implementa un pipeline completo de visión artificial capaz de:
- Detectar y clasificar drones y aves en tiempo real
- Calcular telemetría de cada objeto (velocidad, dirección, distancia)
- Mostrar overlays visuales sobre el feed de vídeo en directo
- Emitir alertas cuando se detecta un objeto con alta confianza
- Exponer los resultados vía API REST y WebSocket para la app móvil

## Stack tecnológico
- **Modelo:** YOLOv8s (Ultralytics) con fine-tuning
- **Dataset:** Drone-vs-Birds (13.420 imágenes, 2 clases)
- **Backend:** FastAPI + WebSocket
- **Almacenamiento:** SQLite
- **Entrenamiento:** Google Colab (GPU T4)
- **App móvil:** Flutter / React Native (en desarrollo)

## Estructura del proyecto
```
tfg-deteccion-aerea/
├── src/
│   ├── config.py           # configuración central
│   ├── structures.py       # clases de datos
│   ├── detector.py         # YOLO + tracker + overlays
│   ├── api.py              # FastAPI + WebSocket
│   ├── database.py         # SQLite
│   └── main.py             # punto de entrada
├── dataset/                # imágenes y etiquetas YOLO
├── models/                 # modelo entrenado (.pt)
├── outputs/                # detecciones y alertas guardadas
├── notebooks/              # notebooks de Colab
├── data.yaml               # configuración del dataset
└── requirements.txt        # dependencias
```

## Instalación
```bash
python -m venv venv
venv\Scripts\activate        # Windows
pip install -r requirements.txt
```

## Uso
```bash
# Arrancar el sistema con cámara en directo
cd src
python main.py

# Arrancar la API
uvicorn api:app --reload --host 0.0.0.0 --port 8000
```

## Clases detectadas
| ID | Clase | Color overlay |
|----|-------|---------------|
| 0  | Drone | Azul          |
| 1  | Bird  | Verde         |

## Telemetría calculada
- Velocidad estimada (px/frame → m/s)
- Dirección de movimiento (grados)
- Aceleración entre frames
- Distancia estimada a la cámara
- Tiempo en escena

## Dataset
Drone-vs-Birds por ElieSaade — Roboflow Universe
Licencia: CC BY 4.0

## Autor
Trabajo de Fin de Grado — Miguel María Gomeza de Larrea
Universidad Pontificia de Comillas ICAI — 2026