import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Overlay de alerta visual para objetivos aéreos confirmados.
///
/// COLOCACIÓN: se añade dentro del Stack de la vista de cámara (encima de la
/// preview y de las cajas), envuelto en `Positioned.fill`, para pintarse por
/// encima SIN bloquear los toques (usa `IgnorePointer`).
///
/// Es puramente presentacional: el padre decide cuándo hay alerta. En esta app
/// el criterio ya lo da el ObjectTracker (estado `confirmed`), así que basta con
/// pasarle `activa: _detections > 0`. Manténlo SIEMPRE montado y solo cambia
/// `activa`, para que la vibración se dispare únicamente al confirmar (flanco de
/// subida) y no en cada frame.
class AlertaOverlay extends StatefulWidget {
  /// `true` cuando hay al menos un objetivo confirmado en pantalla.
  final bool activa;

  /// Etiqueta del objetivo principal (p. ej. "DRONE"). Opcional.
  final String? etiqueta;

  /// Nº de objetivos confirmados, para el contador. Opcional.
  final int objetivos;

  const AlertaOverlay({
    super.key,
    required this.activa,
    this.etiqueta,
    this.objetivos = 0,
  });

  @override
  State<AlertaOverlay> createState() => _AlertaOverlayState();
}

class _AlertaOverlayState extends State<AlertaOverlay>
    with SingleTickerProviderStateMixin {
  // ---- Ajustes visuales (toca aquí si quieres otro look) ----
  static const Color _colorAlerta = Color(0xFFFF1744); // rojo intenso
  static const Duration _periodoParpadeo = Duration(milliseconds: 550);
  static const double _grosorBorde = 6.0;
  static const double _tamPunto = 16.0;

  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: _periodoParpadeo)
      ..repeat(reverse: true);
    if (widget.activa) _feedbackHaptico();
  }

  @override
  void didUpdateWidget(AlertaOverlay old) {
    super.didUpdateWidget(old);
    // Vibración solo en el flanco de subida (nueva alerta), no en cada frame.
    if (widget.activa && !old.activa) _feedbackHaptico();
  }

  void _feedbackHaptico() => HapticFeedback.heavyImpact();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.activa) return const SizedBox.shrink();

    final parpadeo = Tween<double>(begin: 1.0, end: 0.2).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );

    return IgnorePointer(
      child: Stack(
        children: [
          // Borde perimetral pulsante
          Positioned.fill(
            child: FadeTransition(
              opacity: parpadeo,
              child: Container(
                decoration: BoxDecoration(
                  border:
                      Border.all(color: _colorAlerta, width: _grosorBorde),
                ),
              ),
            ),
          ),
          // Chip superior: punto (parpadea) + texto (fijo, para que se lea)
          Positioned(
            top: 12,
            right: 12,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FadeTransition(
                    opacity: parpadeo,
                    child: Container(
                      width: _tamPunto,
                      height: _tamPunto,
                      decoration: const BoxDecoration(
                        color: _colorAlerta,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _texto(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _texto() {
    final base = (widget.etiqueta != null && widget.etiqueta!.isNotEmpty)
        ? 'OBJETIVO: ${widget.etiqueta}'
        : 'OBJETIVO DETECTADO';
    if (widget.objetivos > 1) return '$base  (${widget.objetivos})';
    return base;
  }
}