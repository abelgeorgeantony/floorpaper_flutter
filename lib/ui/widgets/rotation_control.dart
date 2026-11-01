import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A slider for picking a tile rotation angle in degrees.
///
/// Range defaults to [-180, 180] with 0 at the slider's midpoint. Positive
/// degrees rotate the tile pattern clockwise on screen (i.e. to the right),
/// negative degrees rotate counter-clockwise (to the left).
///
/// The exact current value is only shown as the slider's drag label (and via
/// the semantic value); there is no text input.
class RotationControl extends StatelessWidget {
  /// Current angle in whole degrees. Callers own this value.
  final int value;

  /// Number of discrete steps across [min]..[max].
  final int divisions;

  /// Called whenever the user changes the value via the slider.
  /// Always in [min, max].
  final ValueChanged<int> onChanged;

  /// Invoked when the user taps the reset icon. When null, the reset icon
  /// is hidden. If non-null, the icon only appears while [value] != 0.
  final VoidCallback? onReset;

  final int min;
  final int max;

  const RotationControl({
    super.key,
    required this.value,
    required this.onChanged,
    this.onReset,
    this.min = -180,
    this.max = 180,
    this.divisions = 360,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasRotation = value != 0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              Icons.rotate_right,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text('Rotation', style: theme.textTheme.labelMedium),
            const Spacer(),
            // Reserved slot: invisible (and inert) when there's nothing to
            // reset, but the layout never changes size — so the controls
            // panel can't jump as the user crosses 0°.
            Visibility(
              visible: hasRotation,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Reset rotation',
                icon: const Icon(Icons.refresh, size: 16),
                onPressed: hasRotation ? onReset : null,
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            tickMarkShape: SliderTickMarkShape.noTickMark,
          ),
          child: Slider(
            value: value.clamp(min, max).toDouble(),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: divisions,
            label: '$value°',
            semanticFormatterCallback: (v) => '${v.round()} degrees',
            onChanged: (v) {
              final next = v.round();
              if (next != value) onChanged(next);
            },
            onChangeEnd: (_) => HapticFeedback.selectionClick(),
          ),
        ),
      ],
    );
  }
}