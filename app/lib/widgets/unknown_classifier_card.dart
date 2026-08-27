import 'package:flutter/material.dart';
import '../services/snapshot_service.dart';
import '../services/object_tracker.dart';

class UnknownClassifierCard extends StatelessWidget {
  final String frameId;
  final TrackEvent event;
  final VoidCallback onDismissed;

  const UnknownClassifierCard({
    super.key,
    required this.frameId,
    required this.event,
    required this.onDismissed,
  });

  Future<void> _classify(String label) async {
    try {
      await SnapshotService.instance.updateDetectionLabelByTrack(
        frameId: frameId,
        trackId: event.trackId,
        userLabel: label,
      );
    } catch (e) {
      debugPrint('Classification error: $e');
    }
    onDismissed();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.88),
        border: Border.all(color: Colors.yellow.shade700, width: 2),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.help_outline, color: Colors.yellow, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Unknown object — help classify',
                  style: TextStyle(
                    color: Colors.yellow,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
              GestureDetector(
                onTap: onDismissed,
                child: const Icon(Icons.close, color: Colors.grey, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${event.trackId}  ·  pos (${event.cx.toStringAsFixed(2)}, ${event.cy.toStringAsFixed(2)})',
            style: const TextStyle(color: Colors.grey, fontSize: 11),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _btn('🐦 Bird',   Colors.green, () => _classify('bird')),
              const SizedBox(width: 6),
              _btn('🚁 Drone',  Colors.blue,  () => _classify('drone')),
              const SizedBox(width: 6),
              _btn('✕ False+', Colors.red,   () => _classify('false_positive')),
              const SizedBox(width: 6),
              _btn('Skip',      Colors.grey,  onDismissed),
            ],
          ),
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
              border: Border.all(color: color.withOpacity(0.6)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      );
}