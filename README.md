# TFG — Detección y clasificación de objetos aéreos en tiempo real

Detección y clasificación en tiempo real de objetos aéreos (drones, aves, aviones y
helicópteros) sobre un smartphone, con telemetría por objeto y alertas. Sistema
multi-modelo con dos vías de inferencia: **on-device** (Flutter + capa nativa Kotlin +
TensorFlow Lite) y **API por WiFi** (backend Python/FastAPI).

Trabajo Fin de Grado — Grado en Ingeniería de Tecnologías Industriales, ICAI
(Universidad Pontificia Comillas). Autor: Miguel María Gomeza de Larrea.

## Estructura del repositorio

```
tfg-deteccion-aerea/
├── app/          # Aplicación Flutter/Dart + capa nativa Kotlin (inferencia on-device)
├── backend/      # Servidor Python FastAPI + WebSocket (modo API por WiFi)
├── notebooks/    # Cuaderno de análisis e interpretabilidad
├── models/       # Modelos TFLite de despliegue (opcional; ver nota sobre tamaño)
└── README.md
```

## Requisitos

- **App:** Flutter (canal stable), Android Studio, un dispositivo Android físico
  (probado en Samsung Galaxy S22). El delegado GPU no está disponible en el S22:
  la inferencia corre en CPU con 4 hilos.
- **Backend:** Python 3.10, con `fastapi`, `uvicorn`, `websockets`, `opencv-python`.
- **Entrenamiento/análisis:** `ultralytics`, y un entorno con GPU (Google Colab).

## Ejecución

### App on-device
```powershell
cd app
flutter pub get
flutter run --release -d R3CW60F8LNA   # sustituye por el ID de tu dispositivo
```
Los modelos `.tflite` deben estar en `app/assets/` y declarados en `pubspec.yaml`.

### Backend (modo API por WiFi)
```powershell
cd backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8000
```
El terminal se conecta por WebSocket a `ws://<IP_del_servidor>:8000/stream`.

## Credenciales

Este repositorio **no** contiene claves de API. Para reentrenar o descargar los
conjuntos de datos con Roboflow, define tu propia clave como variable de entorno
(p.\ ej. `ROBOFLOW_API_KEY`) y **no** la escribas en el código.

## Modelos y datasets

Los conjuntos de datos (Drone-vs-Birds y AOD-4) no se incluyen por tamaño y licencia;
se descargan desde sus fuentes originales. Los modelos entrenados (`.pt`) tampoco se
versionan; si se desean incluir los `.tflite` de despliegue, colócalos en `models/`.

## Licencia

Añade aquí la licencia que prefieras (p. ej. MIT) o indica «uso académico».
