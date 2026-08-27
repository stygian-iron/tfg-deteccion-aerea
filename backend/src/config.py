from dataclasses import dataclass

@dataclass
class Config:
    """Configuración central del proyecto."""

    # ── Modelo ────────────────────────────────────────────────
    MODEL_PATH: str = "models/best.pt"        # ruta al modelo entrenado
    CONFIDENCE_THRESHOLD: float = 0.25        # confianza mínima para detectar
    ALERT_THRESHOLD: float = 0.50             # confianza para generar alerta
    IMG_SIZE: int = 320                       # tamaño de imagen para YOLO

    # ── Clases ────────────────────────────────────────────────
    CLASS_NAMES: dict = None
    CLASS_COLORS: dict = None

    def __post_init__(self):
        self.CLASS_NAMES = {0: "bird", 1: "drone"}
        self.CLASS_COLORS = {
            "drone": (0, 100, 255),   # azul
            "bird":  (0, 200, 80)     # verde
        }

    # ── Cámara ────────────────────────────────────────────────
    CAMERA_ID: int = 0                        # 0 = cámara principal
    FPS_TARGET: int = 30                      # frames por segundo objetivo

    # ── Telemetría ────────────────────────────────────────────
    PIXELS_PER_METER: float = 20.0            # calibración px → metros
    REF_BBOX_AREA: float = 300.0              # área de referencia para distancia
    REF_DISTANCE_M: float = 10.0             # distancia de referencia en metros
    MAX_TRACKER_HISTORY: int = 60            # frames máximos en historial
    TRACKER_TOLERANCE_PX: int = 100          # píxeles de tolerancia entre frames

    # ── Almacenamiento ────────────────────────────────────────
    DB_PATH: str = "outputs/detections.db"
    ALERTS_PATH: str = "outputs/alerts.json"
    SNAPSHOTS_PATH: str = "outputs/snapshots"

    # ── API ───────────────────────────────────────────────────
    API_HOST: str = "0.0.0.0"
    API_PORT: int = 8000


# instancia global accesible desde cualquier módulo
config = Config()