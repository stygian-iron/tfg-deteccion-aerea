# -*- coding: utf-8 -*-
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse
import cv2
import numpy as np
import base64
import time
import json
import asyncio
import collections
from config import config as cfg
from structures import ImageFrame
from detector import DroneDetector

app = FastAPI(title="TFG - Deteccion Aerea API")

# ── Instancia global del detector ────────────────────────────────────
detector = DroneDetector(
    model_path=cfg.MODEL_PATH,
    confidence_threshold=cfg.CONFIDENCE_THRESHOLD
)

# ── GET /status ───────────────────────────────────────────────────────
@app.get("/status")
def status():
    """Comprueba que la API está activa y devuelve estadísticas."""
    return {
        "status": "ok",
        "model": cfg.MODEL_PATH,
        "confidence_threshold": cfg.CONFIDENCE_THRESHOLD,
        "frames_procesados": detector.frame_count,
        "alertas": len(detector.alerts)
    }

# ── GET /alerts ───────────────────────────────────────────────────────
@app.get("/alerts")
def get_alerts():
    """Devuelve todas las alertas generadas en la sesión."""
    return JSONResponse([
        {
            "alert_id": a.alert_id,
            "label": a.label,
            "confidence": round(a.confidence, 3),
            "severity": a.severity,
            "timestamp": a.timestamp,
            "position": a.position
        }
        for a in detector.alerts
    ])

# ── WebSocket /stream ─────────────────────────────────────────────────
@app.websocket("/stream")
async def stream(websocket: WebSocket):
    await websocket.accept()
    print("Cliente móvil conectado al stream")

    tiempos_frames = collections.deque(maxlen=30)
    frame_count_local = 0

    try:
        while True:
            data = await websocket.receive_text()
            payload = json.loads(data)

            # Ignorar pings de keepalive
            if payload.get('ping'):
                continue

            img_bytes = base64.b64decode(payload["image"])
            img_array = np.frombuffer(img_bytes, dtype=np.uint8)
            image = cv2.imdecode(img_array, cv2.IMREAD_COLOR)

            if image is None:
                continue

            frame = ImageFrame(
                frame_id=detector.frame_count,
                image=image,
                timestamp=time.time()
            )
            detections = detector.process_frame(frame)

            for d in detections:
                print(f"  {d.label} {d.confidence:.2f} bbox={d.bbox}")

            # Calcular FPS
            tiempos_frames.append(time.time())
            if len(tiempos_frames) >= 2:
                fps = round((len(tiempos_frames) - 1) /
                            (tiempos_frames[-1] - tiempos_frames[0]), 1)
            else:
                fps = 0.0

            frame_count_local += 1

            response = {
                "frame_id": frame.frame_id,
                "fps": fps,
                "timestamp": frame.timestamp,
                "detections": [
                    {
                        "label": d.label,
                        "confidence": round(d.confidence, 3),
                        "bbox": d.bbox,
                        "center": d.center
                    }
                    for d in detections
                ],
                "telemetry": [
                    {
                        "track_id": t.track_id,
                        "label": t.label,
                        "velocity_ms": t.latest_telemetry.velocity_ms if t.latest_telemetry else 0,
                        "direction_deg": t.latest_telemetry.direction_deg if t.latest_telemetry else 0,
                        "distance_m": t.latest_telemetry.estimated_distance_m if t.latest_telemetry else 0,
                        "time_in_scene": t.time_in_scene
                    }
                    for t in detector.trackers.values()
                ],
                "alerts": len(detector.alerts)
            }

            await websocket.send_text(json.dumps(response))

    except WebSocketDisconnect:
        print("Cliente móvil desconectado")


# ── WebSocket /stream/local ───────────────────────────────────────────
@app.websocket("/stream/local")
async def stream_local(websocket: WebSocket):
    await websocket.accept()
    print("Cliente conectado al stream local (webcam)")

    loop = asyncio.get_event_loop()
    tiempos_frames = collections.deque(maxlen=30)
    frame_id = 0
    detections = []

    # Abrir cámara en hilo separado para evitar conflicto con async
    cap = await loop.run_in_executor(None, lambda: cv2.VideoCapture(0, cv2.CAP_DSHOW))

    if not cap.isOpened():
        await websocket.send_text(json.dumps({"error": "No se puede abrir la camara"}))
        await websocket.close()
        return

    try:
        while True:
            # Leer frame en hilo separado
            ret, image = await loop.run_in_executor(None, cap.read)
            if not ret:
                break

            frame = ImageFrame(
                frame_id=frame_id,
                image=image,
                timestamp=time.time()
            )

            if frame_id % 2 == 0:
                detections = await loop.run_in_executor(
                    None, lambda: detector.process_frame(frame)
                )

            tiempos_frames.append(time.time())
            if len(tiempos_frames) >= 2:
                fps = round((len(tiempos_frames) - 1) /
                            (tiempos_frames[-1] - tiempos_frames[0]), 1)
            else:
                fps = 0.0

            result = await loop.run_in_executor(
                None, lambda: detector.render_overlay(frame, detections)
            )
            _, buffer = cv2.imencode(".jpg", result, [cv2.IMWRITE_JPEG_QUALITY, 70])
            img_b64 = base64.b64encode(buffer).decode("utf-8")

            response = {
                "frame_id": frame_id,
                "fps": fps,
                "image": img_b64,
                "detections": [
                    {
                        "label": d.label,
                        "confidence": round(d.confidence, 3),
                        "bbox": d.bbox,
                        "center": d.center
                    }
                    for d in detections
                ],
                "alerts": len(detector.alerts)
            }

            await websocket.send_text(json.dumps(response))
            frame_id += 1
            await asyncio.sleep(0.01)

    except WebSocketDisconnect:
        print("Cliente desconectado del stream local")
    finally:
        await loop.run_in_executor(None, cap.release)
        print("Camara liberada")


# ── Arranque directo ──────────────────────────────────────────────────
if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=cfg.API_HOST, port=cfg.API_PORT)