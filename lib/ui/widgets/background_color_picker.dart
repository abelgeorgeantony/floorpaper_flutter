import 'package:flutter/material.dart';

class BackgroundColorPicker extends StatelessWidget {
  final Color value;
  final ValueChanged<Color> onChanged;

  const BackgroundColorPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  /// Neutral presets that cover most pattern tiles. We deliberately don't
  /// include saturated colors — those are available via the custom picker.
  static const List<Color> _presets = <Color>[
    Color(0xFFFFFFFF),
    Color(0xFFF2F2F2),
    Color(0xFFCDCDCD),
    Color(0xFF4A4A4A),
    Color(0xFF222222),
    Color(0xFF000000),
  ];

  @override
  Widget build(BuildContext context) {
    final presetsMatch =
        _presets.any((c) => c.value == value.value);

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final color in _presets)
          _Swatch(
            color: color,
            selected: color.value == value.value,
            onTap: () => onChanged(color),
          ),
        _Swatch(
          // When the current value isn't one of the presets, show it in the
          // custom slot so the UI stays honest about the active color.
          color: presetsMatch ? const Color(0xFF7A7A7A) : value,
          selected: !presetsMatch,
          onTap: () async {
            final picked = await showDialog<Color>(
              context: context,
              builder: (_) => _HsvPickerDialog(initial: value),
            );
            if (picked != null) onChanged(picked);
          },
          isCustom: true,
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final bool isCustom;

  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
    this.isCustom = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final borderColor = selected ? scheme.primary : scheme.outlineVariant;
    final iconColor =
        color.computeLuminance() > 0.5 ? Colors.black : Colors.white;

    return InkResponse(
      onTap: onTap,
      radius: 22,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: borderColor,
            width: selected ? 2.5 : 1,
          ),
        ),
        child: isCustom
            ? Icon(Icons.palette_outlined, size: 15, color: iconColor)
            : (selected ? Icon(Icons.check, size: 16, color: iconColor) : null),
      ),
    );
  }
}

class _HsvPickerDialog extends StatefulWidget {
  final Color initial;

  const _HsvPickerDialog({required this.initial});

  @override
  State<_HsvPickerDialog> createState() => _HsvPickerDialogState();
}

class _HsvPickerDialogState extends State<_HsvPickerDialog> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    final textStyle = Theme.of(context).textTheme.labelSmall;

    return AlertDialog(
      title: const Text('Background color'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 56,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('Hue', style: textStyle),
          ),
          Slider(
            value: _hsv.hue,
            max: 360,
            onChanged: (v) => setState(() => _hsv = _hsv.withHue(v)),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('Saturation', style: textStyle),
          ),
          Slider(
            value: _hsv.saturation,
            onChanged: (v) => setState(() => _hsv = _hsv.withSaturation(v)),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('Brightness', style: textStyle),
          ),
          Slider(
            value: _hsv.value,
            onChanged: (v) => setState(() => _hsv = _hsv.withValue(v)),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, color),
          child: const Text('Use color'),
        ),
      ],
    );
  }
}