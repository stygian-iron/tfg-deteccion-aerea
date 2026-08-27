import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

// ---------------------------------------------------------------------------
// Data classes
// ---------------------------------------------------------------------------

class SnapshotFrame {
  final String frameId;
  final String timestamp;
  final String jpegPath;
  final bool hasUnknown;
  final bool exported;
  final int totalDetections;
  final int confirmedCount;

  SnapshotFrame({
    required this.frameId,
    required this.timestamp,
    required this.jpegPath,
    required this.hasUnknown,
    required this.exported,
    required this.totalDetections,
    required this.confirmedCount,
  });

  factory SnapshotFrame.fromMap(Map<String, dynamic> m) => SnapshotFrame(
        frameId: m['frame_id'] as String,
        timestamp: m['timestamp'] as String,
        jpegPath: m['jpeg_path'] as String,
        hasUnknown: (m['has_unknown'] as int) == 1,
        exported: (m['exported'] as int) == 1,
        totalDetections: (m['total_detections'] as int?) ?? 0,
        confirmedCount: (m['confirmed_count'] as int?) ?? 0,
      );
}

class SnapshotDetection {
  final int id;
  final String frameId;
  final String trackId;
  final String classLabel;
  final double confidence;
  final double cx, cy, w, h;
  final String? userLabel;
  final bool userConfirmed;
  // Telemetry captured at moment of detection — for display only, not training
  final double speedMps;
  final double directionDeg;
  final double distanceM;

  SnapshotDetection({
    required this.id,
    required this.frameId,
    required this.trackId,
    required this.classLabel,
    required this.confidence,
    required this.cx,
    required this.cy,
    required this.w,
    required this.h,
    this.userLabel,
    required this.userConfirmed,
    this.speedMps = 0.0,
    this.directionDeg = 0.0,
    this.distanceM = 0.0,
  });

  factory SnapshotDetection.fromMap(Map<String, dynamic> m) => SnapshotDetection(
        id: m['id'] as int,
        frameId: m['frame_id'] as String,
        trackId: m['track_id'] as String,
        classLabel: m['class_label'] as String,
        confidence: (m['confidence'] as num).toDouble(),
        cx: (m['cx'] as num).toDouble(),
        cy: (m['cy'] as num).toDouble(),
        w: (m['w'] as num).toDouble(),
        h: (m['h'] as num).toDouble(),
        userLabel: m['user_label'] as String?,
        userConfirmed: (m['user_confirmed'] as int) == 1,
        // Graceful fallback for rows created before this column existed
        speedMps:     (m['speed_mps']     as num?)?.toDouble() ?? 0.0,
        directionDeg: (m['direction_deg'] as num?)?.toDouble() ?? 0.0,
        distanceM:    (m['distance_m']    as num?)?.toDouble() ?? 0.0,
      );

  String get effectiveLabel => userLabel ?? classLabel;
  bool get needsUserReview => userLabel == null && classLabel != 'candidate';
  bool get isManual => trackId.startsWith('manual_');

  String get directionCardinal {
    const dirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    return dirs[((directionDeg + 22.5) ~/ 45) % 8];
  }
}

// ---------------------------------------------------------------------------
// Input DTO — includes telemetry snapshot at time of detection
// ---------------------------------------------------------------------------

class DetectionInput {
  final String trackId;
  final String classLabel;
  final double confidence;
  final double cx, cy, w, h;
  final double speedMps;
  final double directionDeg;
  final double distanceM;

  DetectionInput({
    required this.trackId,
    required this.classLabel,
    required this.confidence,
    required this.cx,
    required this.cy,
    required this.w,
    required this.h,
    this.speedMps = 0.0,
    this.directionDeg = 0.0,
    this.distanceM = 0.0,
  });
}

// ---------------------------------------------------------------------------
// SnapshotService singleton
// ---------------------------------------------------------------------------

class SnapshotService {
  SnapshotService._();
  static final SnapshotService instance = SnapshotService._();

  Database? _db;

  Future<Database> get _database async {
    _db ??= await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dir.path, 'snapshots.db');
    return openDatabase(
      dbPath,
      version: 2,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE snapshots (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        frame_id      TEXT    UNIQUE NOT NULL,
        timestamp     TEXT    NOT NULL,
        jpeg_path     TEXT    NOT NULL,
        has_unknown   INTEGER NOT NULL DEFAULT 0,
        exported      INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE detections (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        frame_id       TEXT    NOT NULL,
        track_id       TEXT    NOT NULL,
        class_label    TEXT    NOT NULL,
        confidence     REAL    NOT NULL,
        cx             REAL    NOT NULL,
        cy             REAL    NOT NULL,
        w              REAL    NOT NULL,
        h              REAL    NOT NULL,
        user_label     TEXT,
        user_confirmed INTEGER NOT NULL DEFAULT 0,
        speed_mps      REAL    NOT NULL DEFAULT 0,
        direction_deg  REAL    NOT NULL DEFAULT 0,
        distance_m     REAL    NOT NULL DEFAULT 0,
        FOREIGN KEY (frame_id) REFERENCES snapshots(frame_id)
      )
    ''');
    await db.execute('CREATE INDEX idx_det_frame ON detections(frame_id)');
    await db.execute('CREATE INDEX idx_det_track  ON detections(track_id)');
  }

  // Migration: v1 → v2 adds the three telemetry columns
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
          'ALTER TABLE detections ADD COLUMN speed_mps     REAL NOT NULL DEFAULT 0');
      await db.execute(
          'ALTER TABLE detections ADD COLUMN direction_deg REAL NOT NULL DEFAULT 0');
      await db.execute(
          'ALTER TABLE detections ADD COLUMN distance_m    REAL NOT NULL DEFAULT 0');
    }
  }

  // -------------------------------------------------------------------------
  // Save auto-detected snapshot
  // -------------------------------------------------------------------------

  Future<String> saveSnapshot({
    required Uint8List jpegBytes,
    required List<DetectionInput> detections,
  }) async {
    final now = DateTime.now();
    final frameId = 'frame_'
        '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}_'
        '${now.millisecond.toString().padLeft(3, '0')}';

    final dir = await getApplicationDocumentsDirectory();
    final snapshotsDir = Directory(p.join(dir.path, 'snapshots'));
    if (!snapshotsDir.existsSync()) snapshotsDir.createSync(recursive: true);

    final jpegPath = p.join(snapshotsDir.path, '$frameId.jpg');
    await File(jpegPath).writeAsBytes(jpegBytes);

    final hasUnknown = detections.any((d) => d.classLabel == 'unknown') ? 1 : 0;

    final db = await _database;
    await db.transaction((txn) async {
      await txn.insert('snapshots', {
        'frame_id':    frameId,
        'timestamp':   now.toIso8601String(),
        'jpeg_path':   jpegPath,
        'has_unknown': hasUnknown,
        'exported':    0,
      });
      for (final det in detections) {
        await txn.insert('detections', {
          'frame_id':       frameId,
          'track_id':       det.trackId,
          'class_label':    det.classLabel,
          'confidence':     det.confidence,
          'cx':             det.cx,
          'cy':             det.cy,
          'w':              det.w,
          'h':              det.h,
          'user_label':     null,
          'user_confirmed': 0,
          'speed_mps':      det.speedMps,
          'direction_deg':  det.directionDeg,
          'distance_m':     det.distanceM,
        });
      }
    });

    return frameId;
  }

  // -------------------------------------------------------------------------
  // Add a manually drawn detection (no telemetry — user-placed)
  // -------------------------------------------------------------------------

  Future<void> addManualDetection({
    required String frameId,
    required String classLabel,
    required double cx,
    required double cy,
    required double w,
    required double h,
  }) async {
    final db = await _database;
    final existing = await db.query(
      'detections',
      where: "frame_id = ? AND track_id LIKE 'manual_%'",
      whereArgs: [frameId],
    );
    final trackId =
        'manual_${(existing.length + 1).toString().padLeft(3, '0')}';

    await db.insert('detections', {
      'frame_id':       frameId,
      'track_id':       trackId,
      'class_label':    classLabel,
      'confidence':     1.0,
      'cx':             cx,
      'cy':             cy,
      'w':              w,
      'h':              h,
      'user_label':     classLabel,
      'user_confirmed': 1,
      'speed_mps':      0.0,
      'direction_deg':  0.0,
      'distance_m':     0.0,
    });
  }

  // -------------------------------------------------------------------------
  // User review
  // -------------------------------------------------------------------------

  Future<void> updateDetectionLabel({
    required int detectionId,
    required String userLabel,
  }) async {
    assert(['bird', 'drone', 'false_positive'].contains(userLabel));
    final db = await _database;
    await db.update(
      'detections',
      {
        'user_label':     userLabel,
        'user_confirmed': userLabel == 'false_positive' ? 0 : 1,
      },
      where: 'id = ?',
      whereArgs: [detectionId],
    );
  }

  Future<void> updateDetectionLabelByTrack({
    required String frameId,
    required String trackId,
    required String userLabel,
  }) async {
    assert(['bird', 'drone', 'false_positive'].contains(userLabel));
    final db = await _database;
    await db.update(
      'detections',
      {
        'user_label':     userLabel,
        'user_confirmed': userLabel == 'false_positive' ? 0 : 1,
      },
      where: 'frame_id = ? AND track_id = ?',
      whereArgs: [frameId, trackId],
    );
  }

  // -------------------------------------------------------------------------
  // Queries
  // -------------------------------------------------------------------------

  Future<List<SnapshotFrame>> getSnapshots() async {
    final db = await _database;
    final rows = await db.rawQuery('''
      SELECT
        s.*,
        COUNT(d.id)                                                AS total_detections,
        SUM(CASE WHEN d.user_confirmed = 1 THEN 1 ELSE 0 END)     AS confirmed_count
      FROM snapshots s
      LEFT JOIN detections d ON d.frame_id = s.frame_id
      GROUP BY s.id
      ORDER BY s.timestamp DESC
    ''');
    return rows.map(SnapshotFrame.fromMap).toList();
  }

  Future<List<SnapshotDetection>> getDetectionsForFrame(String frameId) async {
    final db = await _database;
    final rows = await db.query(
      'detections',
      where: 'frame_id = ?',
      whereArgs: [frameId],
    );
    return rows.map(SnapshotDetection.fromMap).toList();
  }

  Future<int> getUnreviewedSnapshotCount() async {
    final db = await _database;
    final result = await db.rawQuery('''
      SELECT COUNT(DISTINCT frame_id) as cnt
      FROM detections
      WHERE user_label IS NULL AND class_label NOT IN ('candidate')
    ''');
    return result.first['cnt'] as int? ?? 0;
  }

  Future<int> getTotalSnapshots() async {
    final db = await _database;
    final result =
        await db.rawQuery('SELECT COUNT(*) as cnt FROM snapshots');
    return result.first['cnt'] as int? ?? 0;
  }

  // -------------------------------------------------------------------------
  // Export to .zip (YOLO format)
  // Telemetry stored in annotations.json ONLY — not in .txt training files
  // -------------------------------------------------------------------------

  Future<void> exportToZip() async {
    final db = await _database;
    final snapshots =
        await db.rawQuery('SELECT * FROM snapshots ORDER BY timestamp ASC');

    final archive = Archive();
    final List<Map<String, dynamic>> annotationsList = [];

    for (final snap in snapshots) {
      final frameId  = snap['frame_id'] as String;
      final jpegPath = snap['jpeg_path'] as String;

      final jpegFile = File(jpegPath);
      if (!jpegFile.existsSync()) continue;
      final jpegBytes = await jpegFile.readAsBytes();
      archive.addFile(
        ArchiveFile('images/$frameId.jpg', jpegBytes.length, jpegBytes),
      );

      final detRows = await db.query(
        'detections',
        where: 'frame_id = ?',
        whereArgs: [frameId],
      );
      final detections = detRows.map(SnapshotDetection.fromMap).toList();

      // YOLO .txt — class + bbox only, no telemetry
      final txtBuffer = StringBuffer();
      for (final det in detections) {
        final label = det.effectiveLabel;
        if (label == 'false_positive' || label == 'candidate') continue;
        final classId = label == 'bird' ? 0 : label == 'drone' ? 1 : null;
        final cx = det.cx.toStringAsFixed(6);
        final cy = det.cy.toStringAsFixed(6);
        final w  = det.w.toStringAsFixed(6);
        final h  = det.h.toStringAsFixed(6);
        if (classId != null) {
          txtBuffer.writeln('$classId $cx $cy $w $h');
        } else {
          txtBuffer.writeln(
              '# UNREVIEWED track=${det.trackId} cx=$cx cy=$cy w=$w h=$h');
        }
      }
      final txtBytes = utf8.encode(txtBuffer.toString());
      archive.addFile(
        ArchiveFile('labels/$frameId.txt', txtBytes.length, txtBytes),
      );

      // annotations.json — full metadata including telemetry
      annotationsList.add({
        'frame_id':    frameId,
        'timestamp':   snap['timestamp'],
        'has_unknown': snap['has_unknown'] == 1,
        'jpeg':        'images/$frameId.jpg',
        'detections':  detections.map((d) => {
          'id':            d.id,
          'track_id':      d.trackId,
          'class_label':   d.classLabel,
          'confidence':    d.confidence,
          'is_manual':     d.isManual,
          'bbox': {'cx': d.cx, 'cy': d.cy, 'w': d.w, 'h': d.h},
          'user_label':    d.userLabel,
          'user_confirmed': d.userConfirmed,
          // Telemetry metadata — informational only, not used for training
          'telemetry': {
            'speed_mps':     d.speedMps,
            'direction_deg': d.directionDeg,
            'distance_m':    d.distanceM,
          },
        }).toList(),
      });
    }

    final jsonBytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(annotationsList),
    );
    archive.addFile(
      ArchiveFile('annotations.json', jsonBytes.length, jsonBytes),
    );

    final now = DateTime.now();
    final zipName =
        'tfg_export_'
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}'
        '.zip';

    final dir     = await getApplicationDocumentsDirectory();
    final zipPath = p.join(dir.path, zipName);
    final zipData = ZipEncoder().encode(archive);
    if (zipData == null) throw Exception('Zip encoding failed');
    await File(zipPath).writeAsBytes(zipData);

    await db.update('snapshots', {'exported': 1});
    await Share.shareXFiles([XFile(zipPath)], subject: zipName);
  }

  // -------------------------------------------------------------------------
  // Cleanup
  // -------------------------------------------------------------------------

  Future<void> deleteSnapshot(String frameId) async {
    final db = await _database;
    final rows = await db.query(
      'snapshots',
      columns: ['jpeg_path'],
      where: 'frame_id = ?',
      whereArgs: [frameId],
    );
    if (rows.isNotEmpty) {
      final f = File(rows.first['jpeg_path'] as String);
      if (f.existsSync()) f.deleteSync();
    }
    await db.delete('detections', where: 'frame_id = ?', whereArgs: [frameId]);
    await db.delete('snapshots',  where: 'frame_id = ?', whereArgs: [frameId]);
  }

  Future<void> clearAll() async {
    final db = await _database;
    final rows = await db.query('snapshots', columns: ['jpeg_path']);
    for (final row in rows) {
      final f = File(row['jpeg_path'] as String);
      if (f.existsSync()) f.deleteSync();
    }
    await db.delete('detections');
    await db.delete('snapshots');
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}