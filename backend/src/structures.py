import numpy as np
from dataclasses import dataclass, field
from typing import Optional
from collections import deque
from datetime import datetime
import math


# ─── ImageFrame ───────────────────────────────────────────────
@dataclass
class ImageFrame:
    """Representa un frame capturado por la cámara."""
    frame_id: int                          # número de frame
    image: np.ndarray                      # array de píxeles (H x W x 3)
    timestamp: float                       # tiempo en segundos
    source_id: str = "camera_0"            # identificador de la cámara
    width: int = 0
    height: int = 0

    def __post_init__(self):
        # rellena width y height automáticamente desde la imagen
        if self.image is not None:
            self.height, self.width = self.image.shape[:2]


# ─── Detection ────────────────────────────────────────────────
@dataclass
class Detection:
    """Un objeto detectado por YOLO en un frame."""
    bbox: list[float]          # [x_center, y_center, width, height] en píxeles
    confidence: float          # 0.0 a 1.0
    label: str                 # "drone", "bird" o "unknown"
    class_id: int              # 0 = drone, 1 = bird
    timestamp: float = 0.0
    frame_id: int = 0

    @property
    def center(self) -> tuple[float, float]:
        """Devuelve el centro del bounding box como (x, y)."""
        return (self.bbox[0], self.bbox[1])

    @property
    def area(self) -> float:
        """Área del bounding box en píxeles cuadrados."""
        return self.bbox[2] * self.bbox[3]

    def is_confident(self, threshold: float = 0.6) -> bool:
        """True si la confianza supera el umbral."""
        return self.confidence >= threshold


# ─── TelemetrySnapshot ────────────────────────────────────────
@dataclass
class TelemetrySnapshot:
    """Telemetría calculada de un objeto en un instante concreto."""
    timestamp: float
    position: tuple[float, float]          # (x, y) en píxeles
    velocity_px: float = 0.0              # velocidad en píxeles/frame
    velocity_ms: float = 0.0             # velocidad estimada en m/s
    direction_deg: float = 0.0           # dirección en grados (0° = derecha)
    acceleration: float = 0.0           # aceleración entre frames
    estimated_distance_m: float = 0.0   # distancia estimada a la cámara
    bbox_area: float = 0.0              # área del bbox (para estimar distancia


# ─── TrackedObject ────────────────────────────────────────────
class TrackedObject:
    """Objeto detectado y seguido a lo largo de varios frames."""

    def __init__(self, track_id: int, first_detection: Detection):
        self.track_id = track_id
        self.label = first_detection.label
        self.history: deque = deque(maxlen=60)   # máximo 60 posiciones
        self.telemetry_history: deque = deque(maxlen=60)
        self.frames_seen: int = 1
        self.first_seen: float = first_detection.timestamp
        self.last_seen: float = first_detection.timestamp
        self.history.append(first_detection.center)

    def update(self, detection: Detection, fps: float = 30.0):
        """Actualiza el tracker con una nueva detección y calcula telemetría."""
        self.history.append(detection.center)
        self.frames_seen += 1
        self.last_seen = detection.timestamp

        snapshot = self._calculate_telemetry(detection, fps)
        self.telemetry_history.append(snapshot)

    def _calculate_telemetry(self, detection: Detection, fps: float) -> TelemetrySnapshot:
        """Calcula velocidad, dirección y distancia estimada."""
        snapshot = TelemetrySnapshot(
            timestamp=detection.timestamp,
            position=detection.center,
            bbox_area=detection.area
        )

        if len(self.history) >= 2:
            prev = self.history[-2]
            curr = self.history[-1]

            # velocidad en píxeles/frame
            dx = curr[0] - prev[0]
            dy = curr[1] - prev[1]
            snapshot.velocity_px = math.sqrt(dx**2 + dy**2)

            # conversión a m/s (calibración estimada: 1px ≈ 0.05m a 10m de distancia)
            snapshot.velocity_ms = round(snapshot.velocity_px * 0.05, 2)

            # dirección en grados
            snapshot.direction_deg = round(math.degrees(math.atan2(-dy, dx)) % 360, 1)

            # aceleración respecto al frame anterior
            if len(self.telemetry_history) >= 1:
                prev_vel = self.telemetry_history[-1].velocity_px
                snapshot.acceleration = round(snapshot.velocity_px - prev_vel, 2)

            # distancia estimada por tamaño del bbox (referencia: drone ~0.3m a 10m = 300px²)
            REF_AREA = 300.0
            REF_DIST = 10.0
            if detection.area > 0:
                snapshot.estimated_distance_m = round(
                    REF_DIST * math.sqrt(REF_AREA / detection.area), 1
                )

        return snapshot

    @property
    def latest_telemetry(self) -> Optional[TelemetrySnapshot]:
        """Devuelve la telemetría más reciente."""
        return self.telemetry_history[-1] if self.telemetry_history else None

    @property
    def time_in_scene(self) -> float:
        """Segundos que lleva el objeto en escena."""
        return round(self.last_seen - self.first_seen, 2)


# ─── Alert ────────────────────────────────────────────────────
@dataclass
class Alert:
    """Alerta generada cuando se detecta un objeto con alta confianza."""
    alert_id: str
    track_id: int
    label: str
    confidence: float
    timestamp: float
    position: tuple[float, float]
    severity: str = "medium"              # "low", "medium", "high"
    snapshot_path: Optional[str] = None  # ruta a la imagen guardada

    def __post_init__(self):
        # asigna severidad automáticamente según confianza
        if self.confidence >= 0.9:
            self.severity = "high"
        elif self.confidence >= 0.75:
            self.severity = "medium"
        else:
            self.severity = "low"