import sqlite3
import json
import os
from datetime import datetime
from config import config as cfg
from structures import Detection, Alert


class Database:
    """Gestiona el almacenamiento de detecciones y alertas."""

    def __init__(self, db_path: str = cfg.DB_PATH):
        # crear carpeta outputs si no existe
        os.makedirs(os.path.dirname(db_path), exist_ok=True)
        self.db_path = db_path
        self._crear_tablas()
        print(f"Base de datos lista en: {db_path}")

    def _crear_tablas(self):
        """Crea las tablas si no existen."""
        with sqlite3.connect(self.db_path) as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS detecciones (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    frame_id    INTEGER,
                    label       TEXT,
                    confidence  REAL,
                    bbox_x      REAL,
                    bbox_y      REAL,
                    bbox_w      REAL,
                    bbox_h      REAL,
                    timestamp   REAL,
                    created_at  TEXT
                )
            """)
            conn.execute("""
                CREATE TABLE IF NOT EXISTS alertas (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    alert_id    TEXT,
                    track_id    INTEGER,
                    label       TEXT,
                    confidence  REAL,
                    severity    TEXT,
                    pos_x       REAL,
                    pos_y       REAL,
                    timestamp   REAL,
                    created_at  TEXT
                )
            """)
            conn.execute("""
                CREATE TABLE IF NOT EXISTS telemetria (
                    id              INTEGER PRIMARY KEY AUTOINCREMENT,
                    track_id        INTEGER,
                    label           TEXT,
                    velocity_ms     REAL,
                    direction_deg   REAL,
                    distance_m      REAL,
                    timestamp       REAL,
                    created_at      TEXT
                )
            """)
            conn.commit()

    def guardar_deteccion(self, detection: Detection):
        """Guarda una detección en la base de datos."""
        with sqlite3.connect(self.db_path) as conn:
            conn.execute("""
                INSERT INTO detecciones
                (frame_id, label, confidence, bbox_x, bbox_y, bbox_w, bbox_h, timestamp, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                detection.frame_id,
                detection.label,
                detection.confidence,
                detection.bbox[0],
                detection.bbox[1],
                detection.bbox[2],
                detection.bbox[3],
                detection.timestamp,
                datetime.now().isoformat()
            ))
            conn.commit()

    def guardar_alerta(self, alert: Alert):
        """Guarda una alerta en la base de datos."""
        with sqlite3.connect(self.db_path) as conn:
            conn.execute("""
                INSERT INTO alertas
                (alert_id, track_id, label, confidence, severity, pos_x, pos_y, timestamp, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                alert.alert_id,
                alert.track_id,
                alert.label,
                alert.confidence,
                alert.severity,
                alert.position[0],
                alert.position[1],
                alert.timestamp,
                datetime.now().isoformat()
            ))
            conn.commit()

    def obtener_detecciones(self, limit: int = 100) -> list[dict]:
        """Devuelve las últimas detecciones."""
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            rows = conn.execute("""
                SELECT * FROM detecciones
                ORDER BY timestamp DESC
                LIMIT ?
            """, (limit,)).fetchall()
            return [dict(row) for row in rows]

    def obtener_alertas(self, limit: int = 50) -> list[dict]:
        """Devuelve las últimas alertas."""
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            rows = conn.execute("""
                SELECT * FROM alertas
                ORDER BY timestamp DESC
                LIMIT ?
            """, (limit,)).fetchall()
            return [dict(row) for row in rows]

    def estadisticas(self) -> dict:
        """Resumen del historial de detecciones."""
        with sqlite3.connect(self.db_path) as conn:
            total = conn.execute(
                "SELECT COUNT(*) FROM detecciones").fetchone()[0]
            drones = conn.execute(
                "SELECT COUNT(*) FROM detecciones WHERE label='drone'").fetchone()[0]
            aves = conn.execute(
                "SELECT COUNT(*) FROM detecciones WHERE label='bird'").fetchone()[0]
            alertas = conn.execute(
                "SELECT COUNT(*) FROM alertas").fetchone()[0]
            return {
                "total_detecciones": total,
                "drones": drones,
                "aves": aves,
                "alertas": alertas
            }
