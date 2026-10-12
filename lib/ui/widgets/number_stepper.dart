import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class NumberStepper extends StatefulWidget {
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  const NumberStepper({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 1,
    this.max = 40,
  });

  @override
  State<NumberStepper> createState() => _NumberStepperState();
}

class _NumberStepperState extends State<NumberStepper> {
  late final TextEditingController _controller;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.value}');
    _focus = FocusNode()..addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(NumberStepper oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep the box in sync when the value changes from outside (+/- buttons).
    if (widget.value != oldWidget.value &&
        int.tryParse(_controller.text) != widget.value) {
      _setText(widget.value);
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _setText(int value) {
    final text = '$value';
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) _commit();
  }

  void _onTextChanged(String raw) {
    final parsed = int.tryParse(raw);
    if (parsed == null) return; // empty box: wait until the user is done

    if (parsed > widget.max) {
      // Adding more digits can never fix this, so correct it right away.
      _setText(widget.max);
      widget.onChanged(widget.max);
      return;
    }
    if (parsed >= widget.min) widget.onChanged(parsed);
  }

  /// Called when the user leaves the box: fix empty / 0 / "007" etc.
  void _commit() {
    final parsed = int.tryParse(_controller.text);
    final fixed = (parsed ?? widget.value).clamp(widget.min, widget.max);
    _setText(fixed);
    if (fixed != widget.value) widget.onChanged(fixed);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.remove),
          onPressed: widget.value > widget.min
              ? () => widget.onChanged(widget.value - 1)
              : null,
        ),
        SizedBox(
          width: 48,
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            style: Theme.of(context).textTheme.titleMedium,
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
            ),
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(widget.max.toString().length),
            ],
            onChanged: _onTextChanged,
            onSubmitted: (_) => _commit(),
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add),
          onPressed: widget.value < widget.max
              ? () => widget.onChanged(widget.value + 1)
              : null,
        ),
      ],
    );
  }
}