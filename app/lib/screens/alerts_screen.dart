import 'dart:io';
import 'package:flutter/material.dart';
import '../services/snapshot_service.dart';

// ---------------------------------------------------------------------------
// Internal model
// ---------------------------------------------------------------------------

class _SnapshotEntry {
  final SnapshotFrame frame;
  List<SnapshotDetection> detections;

  _SnapshotEntry(this.frame, this.detections);

  List<SnapshotDetection> get unreviewed =>
      detections.where((d) => d.needsUserReview).toList();

  bool get needsReview => unreviewed.isNotEmpty;

  bool get isFullyReviewed =>
      detections.isNotEmpty &&
      detections
          .where((d) => d.classLabel != 'candidate')
          .every((d) => d.userLabel != null);
}

// ---------------------------------------------------------------------------
// Detection overlay painter — coloured bbox + label on the saved JPEG
// ---------------------------------------------------------------------------

class _DetectionOverlayPainter extends CustomPainter {
  final List<SnapshotDetection> detections;
  final bool showLabels;

  const _DetectionOverlayPainter({
    required this.detections,
    this.showLabels = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final det in detections) {
      final color = switch (det.effectiveLabel) {
        'bird'           => Colors.green,
        'drone'          => Colors.blue,
        'unknown'        => Colors.yellow,
        'false_positive' => Colors.red,
        _                => Colors.grey,
      };

      final x1 = (det.cx - det.w / 2) * size.width;
      final y1 = (det.cy - det.h / 2) * size.height;
      final x2 = (det.cx + det.w / 2) * size.width;
      final y2 = (det.cy + det.h / 2) * size.height;

      // Box stroke
      canvas.drawRect(
        Rect.fromLTRB(x1, y1, x2, y2),
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = showLabels ? 2.0 : 1.5,
      );
      // Subtle fill
      canvas.drawRect(
        Rect.fromLTRB(x1, y1, x2, y2),
        Paint()
          ..color = color.withOpacity(0.08)
          ..style = PaintingStyle.fill,
      );

      if (showLabels) {
        final isManual = det.trackId.startsWith('manual_');
        final labelText = isManual
            ? '${det.trackId}  ${det.effectiveLabel.toUpperCase()}  [manual]'
            : '${det.trackId}  ${det.effectiveLabel.toUpperCase()}'
              '${det.confidence > 0 ? "  ${(det.confidence * 100).toStringAsFixed(0)}%" : ""}';

        final tp = TextPainter(
          text: TextSpan(
            text: labelText,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              backgroundColor: Colors.black.withOpacity(0.72),
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: size.width);

        final labelY = y1 > tp.height + 2 ? y1 - tp.height - 2 : y2 + 2;
        final labelX =
            x1.clamp(0.0, (size.width - tp.width).clamp(0.0, size.width));
        tp.paint(canvas, Offset(labelX, labelY));
      }
    }
  }

  @override
  bool shouldRepaint(_DetectionOverlayPainter old) =>
      old.detections != detections || old.showLabels != showLabels;
}

// ---------------------------------------------------------------------------
// Drawing overlay painter — shows rectangle being drawn by the user
// ---------------------------------------------------------------------------

class _DrawingPainter extends CustomPainter {
  final Offset? start;
  final Offset? end;

  const _DrawingPainter(this.start, this.end);

  @override
  void paint(Canvas canvas, Size size) {
    if (start == null || end == null) return;
    final rect = Rect.fromPoints(start!, end!);

    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.white.withOpacity(0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.white.withOpacity(0.12)
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(_DrawingPainter old) =>
      old.start != start || old.end != end;
}

// ---------------------------------------------------------------------------
// AlertsScreen
// ---------------------------------------------------------------------------

class AlertsScreen extends StatefulWidget {
  final String serverIp;
  const AlertsScreen({super.key, required this.serverIp});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  List<_SnapshotEntry> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final frames = await SnapshotService.instance.getSnapshots();
      final entries = <_SnapshotEntry>[];
      for (final frame in frames) {
        final dets = await SnapshotService.instance
            .getDetectionsForFrame(frame.frameId);
        entries.add(_SnapshotEntry(frame, dets));
      }
      if (mounted) setState(() { _entries = entries; _loading = false; });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _classify(
    _SnapshotEntry entry,
    SnapshotDetection det,
    String label,
  ) async {
    try {
      await SnapshotService.instance.updateDetectionLabelByTrack(
        frameId: entry.frame.frameId,
        trackId: det.trackId,
        userLabel: label,
      );
      final updated = await SnapshotService.instance
          .getDetectionsForFrame(entry.frame.frameId);
      if (mounted) setState(() => entry.detections = updated);
    } catch (e) {
      debugPrint('Classification error: $e');
    }
  }

  /// Called from _FullImageView after a manual detection is added
  void _onManualAdded(_SnapshotEntry entry, List<SnapshotDetection> updated) {
    if (mounted) setState(() => entry.detections = updated);
  }

  Future<void> _delete(_SnapshotEntry entry) async {
    await SnapshotService.instance.deleteSnapshot(entry.frame.frameId);
    if (mounted) setState(() => _entries.remove(entry));
  }

  Future<void> _export() async {
    try {
      await SnapshotService.instance.exportToZip();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e'), backgroundColor: Colors.red),
        );
      }
      return;
    }

    if (!mounted) return;
    final doClear = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: const Text('Export complete', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Clear the alert log now?\n\n'
          'Keep — alerts remain for further review.\n'
          'Clear — JPEGs are deleted from the device.',
          style: TextStyle(color: Colors.grey),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep', style: TextStyle(color: Colors.blueAccent)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (doClear == true && mounted) {
      await SnapshotService.instance.clearAll();
      setState(() => _entries.clear());
    }
  }

  @override
  Widget build(BuildContext context) {
    final pendingCount = _entries.where((e) => e.needsReview).length;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Alert Log'),
            if (!_loading && pendingCount > 0)
              Text(
                '$pendingCount awaiting review',
                style: const TextStyle(
                    fontSize: 11, color: Colors.yellow,
                    fontWeight: FontWeight.normal),
              ),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), tooltip: 'Refresh', onPressed: _load),
          IconButton(
            icon: const Icon(Icons.file_download_outlined),
            tooltip: 'Export dataset (.zip)',
            onPressed: _entries.isEmpty ? null : _export,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.photo_library_outlined,
                          size: 56, color: Colors.grey.shade700),
                      const SizedBox(height: 12),
                      const Text('No alerts yet',
                          style: TextStyle(
                              color: Colors.white, fontSize: 16,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      const Text(
                        'Detections will appear here\nonce objects are tracked.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _entries.length,
                    itemBuilder: (_, i) => _SnapshotCard(
                      entry: _entries[i],
                      onClassify: _classify,
                      onDelete: _delete,
                      onTapImage: (entry) => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => _FullImageView(
                            entry: entry,
                            onClassify: _classify,
                            onManualAdded: _onManualAdded,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
    );
  }
}

// ---------------------------------------------------------------------------
// Snapshot card (list item)
// ---------------------------------------------------------------------------

class _SnapshotCard extends StatelessWidget {
  final _SnapshotEntry entry;
  final Future<void> Function(_SnapshotEntry, SnapshotDetection, String) onClassify;
  final Future<void> Function(_SnapshotEntry) onDelete;
  final void Function(_SnapshotEntry) onTapImage;

  const _SnapshotCard({
    required this.entry,
    required this.onClassify,
    required this.onDelete,
    required this.onTapImage,
  });

  @override
  Widget build(BuildContext context) {
    final needsReview     = entry.needsReview;
    final isFullyReviewed = entry.isFullyReviewed;
    final visibleDets = entry.detections
        .where((d) => d.classLabel != 'candidate')
        .toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: needsReview
              ? Colors.yellow.shade700
              : isFullyReviewed
                  ? Colors.green.shade800
                  : Colors.grey.shade800,
          width: needsReview ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (needsReview)
            _banner(Colors.yellow.shade900.withOpacity(0.4),
                Icons.help_outline, Colors.yellow, 'NEEDS REVIEW', Colors.yellow)
          else if (isFullyReviewed)
            _banner(Colors.green.shade900.withOpacity(0.4),
                Icons.check_circle_outline, Colors.green, 'REVIEWED', Colors.green),

          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Tappable thumbnail with bbox overlay
                GestureDetector(
                  onTap: () => onTapImage(entry),
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 96, height: 96,
                          child: File(entry.frame.jpegPath).existsSync()
                              ? Image.file(File(entry.frame.jpegPath),
                                  fit: BoxFit.cover, width: 96, height: 96)
                              : Container(
                                  color: Colors.black26,
                                  child: const Icon(Icons.broken_image,
                                      color: Colors.grey, size: 36)),
                        ),
                      ),
                      if (visibleDets.isNotEmpty)
                        SizedBox(
                          width: 96, height: 96,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: CustomPaint(
                              painter: _DetectionOverlayPainter(
                                  detections: visibleDets, showLabels: false),
                            ),
                          ),
                        ),
                      Positioned(
                        right: 4, bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.6),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Icon(Icons.zoom_in,
                              color: Colors.white, size: 14),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),

                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_fmt(entry.frame.timestamp),
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13)),
                      const SizedBox(height: 8),
                      Wrap(spacing: 4, runSpacing: 4,
                          children: visibleDets.map(_chip).toList()),
                      const SizedBox(height: 8),
                      Row(children: [
                        Icon(
                          isFullyReviewed
                              ? Icons.check_circle
                              : needsReview ? Icons.schedule : Icons.circle_outlined,
                          size: 13,
                          color: isFullyReviewed
                              ? Colors.green
                              : needsReview ? Colors.yellow : Colors.grey,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${entry.frame.confirmedCount}/${entry.frame.totalDetections} confirmed',
                          style: TextStyle(
                            color: isFullyReviewed ? Colors.green : Colors.grey,
                            fontSize: 11,
                          ),
                        ),
                      ]),
                    ],
                  ),
                ),

                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.grey, size: 20),
                  onPressed: () => _confirmDelete(context),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),

          ...entry.unreviewed.map((det) => _classifyRow(det)),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _banner(Color bg, IconData icon, Color iconColor, String text, Color textColor) =>
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        ),
        child: Row(children: [
          Icon(icon, color: iconColor, size: 14),
          const SizedBox(width: 6),
          Text(text,
              style: TextStyle(
                  color: textColor, fontSize: 11,
                  fontWeight: FontWeight.bold, letterSpacing: 1.0)),
        ]),
      );

  Widget _chip(SnapshotDetection d) {
    final label = d.effectiveLabel;
    final color = switch (label) {
      'bird'           => Colors.green,
      'drone'          => Colors.blue,
      'false_positive' => Colors.red,
      'unknown'        => Colors.yellow,
      _                => Colors.grey,
    };
    final text = switch (label) {
      'bird'           => 'Bird ${(d.confidence * 100).toStringAsFixed(0)}%',
      'drone'          => 'Drone ${(d.confidence * 100).toStringAsFixed(0)}%',
      'false_positive' => 'False+',
      'unknown'        => '? Unknown',
      _                => label,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        border: Border.all(color: color.withOpacity(0.55)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text,
          style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
    );
  }

  Widget _classifyRow(SnapshotDetection det) {
    final isUnknown = det.classLabel == 'unknown';
    final header = isUnknown
        ? '${det.trackId}  —  tap image to see it, then classify:'
        : '${det.trackId}  —  model: ${det.classLabel} ${(det.confidence * 100).toStringAsFixed(0)}%  — confirm or correct:';

    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isUnknown ? Colors.yellow.withOpacity(0.05) : Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isUnknown ? Colors.yellow.withOpacity(0.3) : Colors.grey.withOpacity(0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(header,
              style: TextStyle(
                  color: isUnknown ? Colors.yellow : Colors.grey, fontSize: 11)),
          const SizedBox(height: 8),
          Row(children: [
            _classifyBtn('🐦 Bird',   Colors.green, () => onClassify(entry, det, 'bird')),
            const SizedBox(width: 6),
            _classifyBtn('🚁 Drone',  Colors.blue,  () => onClassify(entry, det, 'drone')),
            const SizedBox(width: 6),
            _classifyBtn('✕ False+', Colors.red,   () => onClassify(entry, det, 'false_positive')),
          ]),
        ],
      ),
    );
  }

  Widget _classifyBtn(String label, Color color, VoidCallback onTap) => Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              border: Border.all(color: color.withOpacity(0.55)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: Text(label,
                  style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      );

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: const Text('Delete alert?', style: TextStyle(color: Colors.white)),
        content: const Text('This will remove the JPEG and all detection data.',
            style: TextStyle(color: Colors.grey)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () { Navigator.pop(context); onDelete(entry); },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  String _fmt(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.day.toString().padLeft(2, '0')}/'
          '${dt.month.toString().padLeft(2, '0')}/'
          '${dt.year}  '
          '${dt.hour.toString().padLeft(2, '0')}:'
          '${dt.minute.toString().padLeft(2, '0')}:'
          '${dt.second.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }
}

// ---------------------------------------------------------------------------
// Full-screen image view — zoomable JPEG + labelled overlays + draw mode
// ---------------------------------------------------------------------------

class _FullImageView extends StatefulWidget {
  final _SnapshotEntry entry;
  final Future<void> Function(_SnapshotEntry, SnapshotDetection, String) onClassify;
  final void Function(_SnapshotEntry, List<SnapshotDetection>) onManualAdded;

  const _FullImageView({
    required this.entry,
    required this.onClassify,
    required this.onManualAdded,
  });

  @override
  State<_FullImageView> createState() => _FullImageViewState();
}

class _FullImageViewState extends State<_FullImageView> {
  late List<SnapshotDetection> _dets;

  // Drawing mode state
  bool _drawingMode = false;
  Offset? _drawStart;
  Offset? _drawEnd;
  final GlobalKey _stackKey = GlobalKey();
  Size _imageSize = Size.zero;
  final TransformationController _transformController = TransformationController();

  @override
  void initState() {
    super.initState();
    _dets = List.from(widget.entry.detections);
    // Measure the image stack after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureStack());
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  void _measureStack() {
    final box = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && mounted) {
      setState(() => _imageSize = box.size);
    }
  }

  List<SnapshotDetection> get _visible =>
      _dets.where((d) => d.classLabel != 'candidate').toList();

  List<SnapshotDetection> get _unreviewed =>
      _dets.where((d) => d.needsUserReview).toList();

  // -------------------------------------------------------------------------
  // Existing detection classification
  // -------------------------------------------------------------------------

  Future<void> _classify(SnapshotDetection det, String label) async {
    await widget.onClassify(widget.entry, det, label);
    setState(() => _dets = List.from(widget.entry.detections));
  }

  // -------------------------------------------------------------------------
  // Drawing mode
  // -------------------------------------------------------------------------

  void _enterDrawingMode() {
    _transformController.value = Matrix4.identity(); // reset zoom before drawing
    setState(() {
      _drawingMode = true;
      _drawStart = null;
      _drawEnd = null;
    });
    // Re-measure after layout stabilises at 1x
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureStack());
  }

  void _cancelDrawing() {
    setState(() {
      _drawingMode = false;
      _drawStart = null;
      _drawEnd = null;
    });
  }

  Future<void> _onDrawEnd() async {
    if (_drawStart == null || _drawEnd == null) return;

    // Ignore tiny accidental taps
    if ((_drawEnd! - _drawStart!).distance < 12) {
      setState(() { _drawStart = null; _drawEnd = null; });
      return;
    }

    // Use measured size; fall back to screen width if measurement not ready
    final displayW = _imageSize.width > 0
        ? _imageSize.width
        : MediaQuery.of(context).size.width;
    final displayH = _imageSize.height > 0 ? _imageSize.height : displayW * 1.5;

    // Clamp to image bounds
    final x1 = _drawStart!.dx.clamp(0.0, displayW);
    final y1 = _drawStart!.dy.clamp(0.0, displayH);
    final x2 = _drawEnd!.dx.clamp(0.0, displayW);
    final y2 = _drawEnd!.dy.clamp(0.0, displayH);

    final cx = ((x1 + x2) / 2) / displayW;
    final cy = ((y1 + y2) / 2) / displayH;
    final w  = (x2 - x1).abs() / displayW;
    final h  = (y2 - y1).abs() / displayH;

    // Ask user what the object is
    if (!mounted) return;
    final selected = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: const Text('What is this object?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'Choose the class for the object you just marked.',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.pop(context, 'bird'),
            icon: const Text('🐦', style: TextStyle(fontSize: 20)),
            label: const Text('Bird', style: TextStyle(color: Colors.green, fontSize: 15)),
          ),
          TextButton.icon(
            onPressed: () => Navigator.pop(context, 'drone'),
            icon: const Text('🚁', style: TextStyle(fontSize: 20)),
            label: const Text('Drone', style: TextStyle(color: Colors.blue, fontSize: 15)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );

    if (selected == null) {
      setState(() { _drawStart = null; _drawEnd = null; });
      return;
    }

    // Save to DB
    await SnapshotService.instance.addManualDetection(
      frameId: widget.entry.frame.frameId,
      classLabel: selected,
      cx: cx.clamp(0.01, 0.99),
      cy: cy.clamp(0.01, 0.99),
      w: w.clamp(0.01, 0.99),
      h: h.clamp(0.01, 0.99),
    );

    final updated = await SnapshotService.instance
        .getDetectionsForFrame(widget.entry.frame.frameId);

    // Notify parent so the list card updates too
    widget.onManualAdded(widget.entry, updated);

    if (mounted) {
      setState(() {
        _dets = List.from(widget.entry.detections);
        _drawingMode = false;
        _drawStart = null;
        _drawEnd = null;
      });
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(_fmt(widget.entry.frame.timestamp),
            style: const TextStyle(fontSize: 13)),
        actions: _drawingMode
            ? [
                TextButton.icon(
                  onPressed: _cancelDrawing,
                  icon: const Icon(Icons.close, color: Colors.red),
                  label: const Text('Cancel', style: TextStyle(color: Colors.red)),
                ),
              ]
            : [],
      ),
      floatingActionButton: _drawingMode
          ? null // Cancel is in the AppBar during drawing mode
          : FloatingActionButton.extended(
              onPressed: _enterDrawingMode,
              backgroundColor: Colors.grey.shade800,
              icon: const Icon(Icons.add_location_alt_outlined),
              label: const Text('Mark missed object'),
            ),
      body: Column(
        children: [
          // ── Drawing mode instruction banner ──────────────────────────────
          if (_drawingMode)
            Container(
              width: double.infinity,
              color: Colors.orange.shade900.withOpacity(0.85),
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              child: const Row(
                children: [
                  Icon(Icons.gesture, color: Colors.white, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Drag on the image to draw a box around the missed object',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),

          // ── Image with overlays ──────────────────────────────────────────
          Expanded(
            child: InteractiveViewer(
              transformationController: _transformController,
              panEnabled: !_drawingMode,
              scaleEnabled: !_drawingMode,
              minScale: 0.8,
              maxScale: 6.0,
              child: Center(
                child: Stack(
                  key: _stackKey,
                  children: [
                    // JPEG
                    Image.file(
                      File(widget.entry.frame.jpegPath),
                      width: screenW,
                      fit: BoxFit.fitWidth,
                      errorBuilder: (_, __, ___) => SizedBox(
                        width: screenW, height: 300,
                        child: const Center(child: Icon(
                            Icons.broken_image, color: Colors.grey, size: 64)),
                      ),
                    ),

                    // Existing detections overlay (always shown)
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _DetectionOverlayPainter(
                          detections: _visible,
                          showLabels: true,
                        ),
                      ),
                    ),

                    // Drawing gesture + rubber-band rect (only in draw mode)
                    if (_drawingMode)
                      Positioned.fill(
                        child: GestureDetector(
                          onPanStart: (d) => setState(() {
                            _drawStart = d.localPosition;
                            _drawEnd   = d.localPosition;
                          }),
                          onPanUpdate: (d) => setState(() {
                            _drawEnd = d.localPosition;
                          }),
                          onPanEnd: (_) => _onDrawEnd(),
                          child: CustomPaint(
                            painter: _DrawingPainter(_drawStart, _drawEnd),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),

          // ── Classification panel ─────────────────────────────────────────
          if (!_drawingMode && _unreviewed.isNotEmpty)
            Container(
              color: Colors.grey.shade900,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Review detections:',
                      style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  ..._unreviewed.map((det) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _classifyRow(det),
                      )),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _classifyRow(SnapshotDetection det) {
    final isUnknown = det.classLabel == 'unknown';
    final color = switch (det.classLabel) {
      'unknown' => Colors.yellow,
      'bird'    => Colors.green,
      'drone'   => Colors.blue,
      _         => Colors.grey,
    };
    final header = isUnknown
        ? '${det.trackId}  — unknown'
        : '${det.trackId}  — ${det.classLabel} ${(det.confidence * 100).toStringAsFixed(0)}%';

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(header, style: TextStyle(color: color, fontSize: 11)),
          const SizedBox(height: 8),
          Row(children: [
            _btn('🐦 Bird',   Colors.green, () => _classify(det, 'bird')),
            const SizedBox(width: 6),
            _btn('🚁 Drone',  Colors.blue,  () => _classify(det, 'drone')),
            const SizedBox(width: 6),
            _btn('✕ False+', Colors.red,   () => _classify(det, 'false_positive')),
          ]),
        ],
      ),
    );
  }

  Widget _btn(String label, Color color, VoidCallback onTap) => Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              border: Border.all(color: color.withOpacity(0.55)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: Text(label,
                  style: TextStyle(
                      color: color, fontSize: 11,
                      fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      );

  String _fmt(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.day.toString().padLeft(2, '0')}/'
          '${dt.month.toString().padLeft(2, '0')}/'
          '${dt.year}  '
          '${dt.hour.toString().padLeft(2, '0')}:'
          '${dt.minute.toString().padLeft(2, '0')}:'
          '${dt.second.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }
}