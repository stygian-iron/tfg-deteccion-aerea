import cv2
import numpy as np
from ultralytics import YOLO
from structures import ImageFrame, Detection, TrackedObject, Alert
from collections import defaultdict
from config import config as cfg
import time

class DroneDetector:
    """Módulo principal — conecta YOLO con las estructuras del proyecto."""

    def __init__(self, model_path: str = cfg.MODEL_PATH, confidence_threshold: float = cfg.CONFIDENCE_THRESHOLD):
        self.model = YOLO(model_path)
        self.confidence_threshold = confidence_threshold
        self.trackers: dict[int, TrackedObject] = {}
        self.alerts: list[Alert] = []
        self.frame_count: int = 0
        self.next_track_id: int = 0
        print(f"Detector iniciado con modelo: {model_path}")

    def process_frame(self, frame: ImageFrame, fps: float = 30.0) -> list[Detection]:
        """Procesa un frame y devuelve las detecciones."""
        self.frame_count += 1
        results = self.model.predict(
            frame.image,
            conf=self.confidence_threshold,
            verbose=False
        )

        detections = []
        for box in results[0].boxes:
            detection = Detection(
                bbox=box.xywh[0].tolist(),
                confidence=float(box.conf),
                label=self.model.names[int(box.cls)].lower(),
                class_id=int(box.cls),
                timestamp=frame.timestamp,
                frame_id=frame.frame_id
            )
            detections.append(detection)
            self._update_tracker(detection, fps)

        return detections

    def _update_tracker(self, detection: Detection, fps: float):
        """Actualiza o crea un tracker para la detección."""
        # simplificado: asigna tracker por clase y proximidad
        assigned = False
        for track_id, tracker in self.trackers.items():
            if tracker.label == detection.label:
                last_pos = tracker.history[-1]
                dist = np.linalg.norm(
                    np.array(last_pos) - np.array(detection.center)
                )
                if dist < 100:  # píxeles de tolerancia
                    tracker.update(detection, fps)
                    assigned = True
                    break

        if not assigned:
            self.trackers[self.next_track_id] = TrackedObject(
                self.next_track_id, detection
            )
            self.next_track_id += 1

        # generar alerta si supera umbral alto
        if detection.confidence >= 0.85:
            alerta = Alert(
                alert_id=f"ALT_{self.frame_count:04d}",
                track_id=self.next_track_id - 1,
                label=detection.label,
                confidence=detection.confidence,
                timestamp=detection.timestamp,
                position=detection.center
            )
            self.alerts.append(alerta)

    def render_overlay(self, frame: ImageFrame, detections: list[Detection]) -> np.ndarray:
        """Dibuja bounding boxes y telemetría sobre el frame."""
        img = frame.image.copy()
        colors = {"drone": (0, 100, 255), "bird": (0, 200, 80)}

        for detection in detections:
            color = colors.get(detection.label, (200, 200, 200))
            x, y, w, h = detection.bbox
            x1, y1 = int(x - w/2), int(y - h/2)
            x2, y2 = int(x + w/2), int(y + h/2)

            # bounding box
            cv2.rectangle(img, (x1, y1), (x2, y2), color, 2)

            # etiqueta con confianza
            label = f"{detection.label} {detection.confidence:.0%}"
            cv2.putText(img, label, (x1, y1 - 10),
                       cv2.FONT_HERSHEY_SIMPLEX, 0.6, color, 2)

            # telemetría del tracker asociado
            for tracker in self.trackers.values():
                if tracker.label == detection.label:
                    tel = tracker.latest_telemetry
                    if tel:
                        info = f"{tel.velocity_ms}m/s {tel.direction_deg}deg {tel.estimated_distance_m}m"
                        cv2.putText(img, info, (x1, y2 + 18),
                                   cv2.FONT_HERSHEY_SIMPLEX, 0.45, color, 1)
                    break

        return img