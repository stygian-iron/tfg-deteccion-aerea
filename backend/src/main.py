# -*- coding: utf-8 -*-
import cv2
import time
import collections
from config import config as cfg
from structures import ImageFrame
from detector import DroneDetector

def main():
    print("Iniciando sistema de detección aérea...")

    # ── Inicializar detector ─────────────────────────────────────────
    detector = DroneDetector(
        model_path=cfg.MODEL_PATH,
        confidence_threshold=cfg.CONFIDENCE_THRESHOLD
    )

    # ── Abrir cámara ─────────────────────────────────────────────────
    cap = cv2.VideoCapture(cfg.CAMERA_ID, cv2.CAP_DSHOW)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)

    if not cap.isOpened():
        print("Error: no se puede abrir la cámara")
        return

    print(f"Cámara abierta. Resolución: "
          f"{int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))}x"
          f"{int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))}")
    print("Pulsa Q para salir\n")

    frame_id = 0
    detections = []

    # Cola con los tiempos de los últimos 30 frames para calcular FPS real
    tiempos_frames = collections.deque(maxlen=30)

    while True:
        t_inicio = time.time()

        ret, image = cap.read()
        if not ret:
            print("Error leyendo frame")
            break

        # ── Crear ImageFrame ─────────────────────────────────────────
        frame = ImageFrame(
            frame_id=frame_id,
            image=image,
            timestamp=t_inicio
        )

        # ── Detectar objetos (1 de cada 2 frames) ────────────────────
        if frame_id % 2 == 0:
            detections = detector.process_frame(frame, fps=len(tiempos_frames))

        # ── Renderizar overlays ──────────────────────────────────────
        result = detector.render_overlay(frame, detections)

        # ── Calcular FPS real (media de últimos 30 frames) ───────────
        tiempos_frames.append(time.time())
        if len(tiempos_frames) >= 2:
            fps_real = round((len(tiempos_frames) - 1) /
                             (tiempos_frames[-1] - tiempos_frames[0]), 1)
        else:
            fps_real = 0.0

        # ── Info en pantalla ─────────────────────────────────────────
        cv2.putText(result, f"FPS: {fps_real}", (10, 30),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 2)
        cv2.putText(result, f"Detecciones: {len(detections)}", (10, 60),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 2)

        # ── Mostrar última alerta activa ─────────────────────────────
        if detector.alerts:
            ultima = detector.alerts[-1]
            cv2.putText(result, f"ALERTA: {ultima.label} ({ultima.severity})",
                        (10, 90), cv2.FONT_HERSHEY_SIMPLEX,
                        0.7, (0, 0, 255), 2)

        # ── Mostrar ventana ──────────────────────────────────────────
        cv2.imshow("TFG - Deteccion Aerea", result)
        frame_id += 1

        if cv2.waitKey(1) & 0xFF == ord('q'):
            print("Saliendo...")
            break

    cap.release()
    cv2.destroyAllWindows()
    print(f"Sesión finalizada. Frames procesados: {frame_id}")
    print(f"Alertas generadas: {len(detector.alerts)}")


if __name__ == "__main__":
    main()