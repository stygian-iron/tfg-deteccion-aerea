import 'dart:math';
import 'package:flutter/material.dart';
import '../services/object_tracker.dart';

// ---------------------------------------------------------------------------
// TelemetryScreen
// ---------------------------------------------------------------------------

class TelemetryScreen extends StatelessWidget {
  /// Live feed of telemetry — updated by stream_screen every inference cycle.
  final ValueNotifier<List<TelemetrySnapshot>> telemetryNotifier;

  const TelemetryScreen({super.key, required this.telemetryNotifier});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Live Telemetry'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Tooltip(
              message:
                  'Speed and distance are rough estimates.\n'
                  'Calibration depends on camera field-of-view and altitude.',
              child: Icon(Icons.info_outline,
                  size: 20, color: Colors.grey.shade600),
            ),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<TelemetrySnapshot>>(
        valueListenable: telemetryNotifier,
        builder: (_, snapshots, __) {
          if (snapshots.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.radar, size: 64, color: Colors.grey.shade700),
                  const SizedBox(height: 16),
                  const Text('No active tracks',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  const Text(
                    'Point the camera at a drone or bird\nand wait for confirmation.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: snapshots.length,
            itemBuilder: (_, i) => _TelemetryCard(snap: snapshots[i]),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Telemetry card — one per tracked object
// ---------------------------------------------------------------------------

class _TelemetryCard extends StatelessWidget {
  final TelemetrySnapshot snap;
  const _TelemetryCard({required this.snap});

  @override
  Widget build(BuildContext context) {
    final isDrone   = snap.label == 'drone';
    final isUnknown = snap.label == 'unknown';
    final color = isUnknown
        ? Colors.yellow
        : isDrone
            ? Colors.blue
            : Colors.green;
    final icon = isUnknown
        ? Icons.question_mark
        : isDrone
            ? Icons.flight
            : Icons.flutter_dash;

    final minutes = snap.timeInScene.inMinutes;
    final seconds = snap.timeInScene.inSeconds % 60;
    final timeStr = minutes > 0
        ? '${minutes}m ${seconds.toString().padLeft(2, '0')}s'
        : '${seconds}s';

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.4), width: 1.5),
      ),
      child: Column(
        children: [
          // ── Header ────────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(14)),
            ),
            child: Row(
              children: [
                Icon(icon, color: color, size: 22),
                const SizedBox(width: 10),
                Text(
                  snap.trackId,
                  style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      letterSpacing: 0.5),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    snap.label.toUpperCase(),
                    style: TextStyle(
                        color: color, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
                const Spacer(),
                Icon(Icons.timer_outlined, size: 14, color: Colors.grey),
                const SizedBox(width: 4),
                Text(timeStr,
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
              ],
            ),
          ),

          // ── Metrics grid ──────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _metricTile(
                        label: 'SPEED',
                        value: snap.speedMps < 0.1
                            ? 'Still'
                            : '${snap.speedMps.toStringAsFixed(1)} m/s',
                        icon: Icons.speed,
                        color: color,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _metricTile(
                        label: 'DISTANCE',
                        value: snap.distanceM < 1
                            ? '< 1 m'
                            : '${snap.distanceM.toStringAsFixed(1)} m',
                        icon: Icons.straighten,
                        color: color,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _DirectionTile(
                          directionDeg: snap.directionDeg,
                          color: color,
                          speedMps: snap.speedMps),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _metricTile(
                        label: 'POSITION',
                        value:
                            'x ${snap.cx.toStringAsFixed(2)}\ny ${snap.cy.toStringAsFixed(2)}',
                        icon: Icons.gps_fixed,
                        color: color,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ── Trajectory mini-map ───────────────────────────────────────────
          if (snap.trajectory.length >= 2)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.route, size: 13, color: Colors.grey.shade600),
                    const SizedBox(width: 4),
                    Text('TRAJECTORY  (${snap.framesAlive} frames)',
                        style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 10,
                            letterSpacing: 0.5)),
                  ]),
                  const SizedBox(height: 6),
                  Container(
                    height: 70,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(8),
                      border:
                          Border.all(color: Colors.grey.shade800),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CustomPaint(
                        painter: _TrajectoryPainter(
                          positions: snap.trajectory,
                          color: color,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _metricTile({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
  }) =>
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.grey.shade800),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 12, color: Colors.grey.shade600),
              const SizedBox(width: 4),
              Text(label,
                  style: TextStyle(
                      color: Colors.grey.shade600,
                      fontSize: 9,
                      letterSpacing: 0.8)),
            ]),
            const SizedBox(height: 6),
            Text(
              value,
              style: TextStyle(
                  color: color,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  height: 1.2),
            ),
          ],
        ),
      );
}

// ---------------------------------------------------------------------------
// Direction tile — shows compass arrow pointing direction of movement
// ---------------------------------------------------------------------------

class _DirectionTile extends StatelessWidget {
  final double directionDeg;
  final double speedMps;
  final Color color;

  const _DirectionTile({
    required this.directionDeg,
    required this.speedMps,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final isMoving = speedMps >= 0.1;
    final cardinalLabel = _cardinal(directionDeg);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade800),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.explore, size: 12, color: Colors.grey.shade600),
            const SizedBox(width: 4),
            Text('DIRECTION',
                style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 9,
                    letterSpacing: 0.8)),
          ]),
          const SizedBox(height: 6),
          Row(
            children: [
              // Rotating arrow
              Transform.rotate(
                angle: directionDeg * pi / 180,
                child: Icon(
                  isMoving ? Icons.arrow_upward : Icons.circle,
                  color: isMoving ? color : Colors.grey.shade700,
                  size: 28,
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isMoving ? cardinalLabel : '—',
                    style: TextStyle(
                        color: color,
                        fontSize: 17,
                        fontWeight: FontWeight.bold),
                  ),
                  if (isMoving)
                    Text(
                      '${directionDeg.toStringAsFixed(0)}°',
                      style: TextStyle(
                          color: Colors.grey.shade500, fontSize: 10),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _cardinal(double deg) {
    const dirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    return dirs[((deg + 22.5) ~/ 45) % 8];
  }
}

// ---------------------------------------------------------------------------
// Trajectory painter
// ---------------------------------------------------------------------------

class _TrajectoryPainter extends CustomPainter {
  final List<Offset> positions;
  final Color color;

  const _TrajectoryPainter({required this.positions, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (positions.length < 2) return;

    // Draw faint grid
    final gridPaint = Paint()
      ..color = Colors.grey.shade900
      ..strokeWidth = 0.5;
    for (int i = 1; i < 4; i++) {
      final x = size.width * i / 4;
      final y = size.height * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Build the path — fade older points
    for (int i = 1; i < positions.length; i++) {
      final opacity = i / positions.length;
      final paint = Paint()
        ..color = color.withOpacity(opacity * 0.85)
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;

      final p1 = Offset(
          positions[i - 1].dx * size.width, positions[i - 1].dy * size.height);
      final p2 = Offset(
          positions[i].dx * size.width, positions[i].dy * size.height);
      canvas.drawLine(p1, p2, paint);
    }

    // Current position dot
    final last = positions.last;
    canvas.drawCircle(
      Offset(last.dx * size.width, last.dy * size.height),
      4,
      Paint()..color = color,
    );
    // Halo
    canvas.drawCircle(
      Offset(last.dx * size.width, last.dy * size.height),
      7,
      Paint()
        ..color = color.withOpacity(0.25)
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(_TrajectoryPainter old) => old.positions != positions;
}