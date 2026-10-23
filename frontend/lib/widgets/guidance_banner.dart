import 'package:flutter/material.dart';
import 'package:blind_assistant/core/theme.dart';
import 'package:blind_assistant/models/detection.dart';

class GuidanceBanner extends StatelessWidget {
  final List<GuidanceMessage> messages;

  const GuidanceBanner({super.key, required this.messages});

  Color _colorFor(Urgency u) {
    switch (u) {
      case Urgency.urgent:
        return AppTheme.urgentColor;
      case Urgency.warn:
        return AppTheme.warnColor;
      case Urgency.info:
        return AppTheme.infoColor;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'Listening… no obstacles reported yet.',
          style: TextStyle(color: Colors.white54, fontSize: 18),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: messages.map((m) {
        return Semantics(
          liveRegion: true,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _colorFor(m.urgency).withValues(alpha: 0.18),
              border: Border.all(color: _colorFor(m.urgency), width: 2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              m.text,
              style: TextStyle(
                color: Colors.white,
                fontSize: m.urgency == Urgency.urgent ? 24 : 19,
                fontWeight: m.urgency == Urgency.urgent ? FontWeight.bold : FontWeight.w500,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
