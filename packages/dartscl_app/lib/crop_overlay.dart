import 'dart:math' as math;

import 'package:dartscl_protocol/dartscl_protocol.dart';
import 'package:flutter/material.dart';

/// Interactive crop overlay that renders a draggable and resizable selection
/// box on top of a preview image. The selection is expressed as relative
/// 0.0–1.0 ratios mapped to a [CropRegion].
class CropOverlay extends StatefulWidget {
  /// Called whenever the user changes the crop selection.
  final ValueChanged<CropRegion?> onCropChanged;

  /// Current crop region (nullable – null means full image selected).
  final CropRegion? initialCrop;

  const CropOverlay({
    super.key,
    required this.onCropChanged,
    this.initialCrop,
  });

  @override
  State<CropOverlay> createState() => _CropOverlayState();
}

class _CropOverlayState extends State<CropOverlay> {
  /// Pixel-level rect within the overlay coordinate system.
  Rect? _selection;

  /// Which handle the user is currently dragging (null = none).
  _DragHandle? _activeHandle;

  /// Offset captured at pan start for move operations.
  Offset _dragStartOffset = Offset.zero;

  /// Selection rect captured at pan start.
  Rect _dragStartRect = Rect.zero;

  static const double _handleSize = 12.0;
  static const double _minSelectionSide = 20.0;

  @override
  void initState() {
    super.initState();
    // Defer initial selection from initialCrop until layout is available.
  }

  @override
  void didUpdateWidget(CropOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // React when the crop region is cleared externally (e.g. X button in
    // the sidebar). Reset the selection so the overlay rectangle disappears.
    if (oldWidget.initialCrop != null && widget.initialCrop == null) {
      setState(() => _selection = null);
    }
  }

  void _initSelectionFromCrop(Size parentSize) {
    // Never clear _selection here — it may have been set by the user via
    // pan gestures. Only initialized from external initialCrop once.
    if (_selection != null) return;
    final crop = widget.initialCrop;
    if (crop != null) {
      _selection = Rect.fromLTWH(
        crop.xRatio * parentSize.width,
        crop.yRatio * parentSize.height,
        crop.widthRatio * parentSize.width,
        crop.heightRatio * parentSize.height,
      );
    }
  }

  CropRegion? _selectionToRegion(Size parentSize) {
    final sel = _selection;
    if (sel == null || parentSize.width == 0 || parentSize.height == 0) {
      return null;
    }
    return CropRegion(
      xRatio: (sel.left / parentSize.width).clamp(0.0, 1.0),
      yRatio: (sel.top / parentSize.height).clamp(0.0, 1.0),
      widthRatio: (sel.width / parentSize.width).clamp(0.0, 1.0),
      heightRatio: (sel.height / parentSize.height).clamp(0.0, 1.0),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final parentSize = Size(constraints.maxWidth, constraints.maxHeight);
        _initSelectionFromCrop(parentSize);

        return GestureDetector(
          onPanStart: (details) => _onPanStart(details, parentSize),
          onPanUpdate: (details) => _onPanUpdate(details, parentSize),
          onPanEnd: (_) => _onPanEnd(parentSize),
          onTapDown: (details) => _onTapDown(details, parentSize),
          child: CustomPaint(
            size: parentSize,
            painter: _CropOverlayPainter(
              selection: _selection,
              handleSize: _handleSize,
              primary: Theme.of(context).colorScheme.primary,
            ),
          ),
        );
      },
    );
  }

  void _onTapDown(TapDownDetails details, Size parentSize) {
    // If tapping outside existing selection, start a new one from scratch.
    final pos = details.localPosition;
    if (_selection != null && !_inflatedSelection().contains(pos)) {
      setState(() {
        _selection = Rect.fromCenter(
          center: pos,
          width: parentSize.width * 0.5,
          height: parentSize.height * 0.5,
        );
        _selection = _clampRect(_selection!, parentSize);
      });
      widget.onCropChanged(_selectionToRegion(parentSize));
    }
  }

  void _onPanStart(DragStartDetails details, Size parentSize) {
    final pos = details.localPosition;
    if (_selection == null) {
      // No selection yet – create one anchored at the tap point.
      setState(() {
        _selection = Rect.fromLTWH(pos.dx, pos.dy, 0, 0);
        _activeHandle = _DragHandle.bottomRight;
        _dragStartOffset = pos;
        _dragStartRect = _selection!;
      });
      return;
    }

    // Check if we hit a resize handle.
    final handle = _hitTestHandle(pos);
    if (handle != null) {
      _activeHandle = handle;
      _dragStartOffset = pos;
      _dragStartRect = _selection!;
      return;
    }

    // Check if we hit the body for moving.
    if (_selection!.contains(pos)) {
      _activeHandle = _DragHandle.move;
      _dragStartOffset = pos;
      _dragStartRect = _selection!;
      return;
    }

    // Tap outside – create new selection.
    setState(() {
      _selection = Rect.fromLTWH(pos.dx, pos.dy, 0, 0);
      _activeHandle = _DragHandle.bottomRight;
      _dragStartOffset = pos;
      _dragStartRect = _selection!;
    });
  }

  void _onPanUpdate(DragUpdateDetails details, Size parentSize) {
    if (_activeHandle == null) return;
    final pos = details.localPosition;
    final delta = pos - _dragStartOffset;

    setState(() {
      switch (_activeHandle!) {
        case _DragHandle.move:
          _selection = _clampRect(
            _dragStartRect.shift(delta),
            parentSize,
          );
          break;
        case _DragHandle.topLeft:
          _selection = _resizeFromHandle(
            _dragStartRect,
            delta,
            anchorRight: true,
            anchorBottom: true,
            parentSize: parentSize,
          );
          break;
        case _DragHandle.topRight:
          _selection = _resizeFromHandle(
            _dragStartRect,
            delta,
            anchorLeft: true,
            anchorBottom: true,
            parentSize: parentSize,
          );
          break;
        case _DragHandle.bottomLeft:
          _selection = _resizeFromHandle(
            _dragStartRect,
            delta,
            anchorRight: true,
            anchorTop: true,
            parentSize: parentSize,
          );
          break;
        case _DragHandle.bottomRight:
          _selection = _resizeFromHandle(
            _dragStartRect,
            delta,
            anchorLeft: true,
            anchorTop: true,
            parentSize: parentSize,
          );
          break;
      }
    });
  }

  void _onPanEnd(Size parentSize) {
    _activeHandle = null;
    // Discard tiny accidental selections.
    if (_selection != null &&
        (_selection!.width < _minSelectionSide ||
            _selection!.height < _minSelectionSide)) {
      setState(() => _selection = null);
      widget.onCropChanged(null);
    } else {
      widget.onCropChanged(_selectionToRegion(parentSize));
    }
  }

  Rect _inflatedSelection() {
    return _selection!.inflate(_handleSize);
  }

  _DragHandle? _hitTestHandle(Offset pos) {
    final sel = _selection!;
    final hs = _handleSize * 1.5; // generous hit area

    if ((pos - sel.topLeft).distance < hs) return _DragHandle.topLeft;
    if ((pos - sel.topRight).distance < hs) return _DragHandle.topRight;
    if ((pos - sel.bottomLeft).distance < hs) return _DragHandle.bottomLeft;
    if ((pos - sel.bottomRight).distance < hs) return _DragHandle.bottomRight;
    return null;
  }

  Rect _resizeFromHandle(
    Rect startRect,
    Offset delta, {
    bool anchorLeft = false,
    bool anchorTop = false,
    bool anchorRight = false,
    bool anchorBottom = false,
    required Size parentSize,
  }) {
    double left = startRect.left;
    double top = startRect.top;
    double right = startRect.right;
    double bottom = startRect.bottom;

    if (!anchorLeft) left += delta.dx;
    if (!anchorTop) top += delta.dy;
    if (!anchorRight) right += delta.dx;
    if (!anchorBottom) bottom += delta.dy;

    // Enforce minimum size.
    if (right - left < _minSelectionSide) {
      if (anchorLeft) {
        right = left + _minSelectionSide;
      } else {
        left = right - _minSelectionSide;
      }
    }
    if (bottom - top < _minSelectionSide) {
      if (anchorTop) {
        bottom = top + _minSelectionSide;
      } else {
        top = bottom - _minSelectionSide;
      }
    }

    return _clampRect(
      Rect.fromLTRB(left, top, right, bottom),
      parentSize,
    );
  }

  Rect _clampRect(Rect r, Size parentSize) {
    // Guard against containers smaller than the minimum selection side —
    // clamp() throws an ArgumentError when lowerLimit > upperLimit.
    final minW = math.min(_minSelectionSide, parentSize.width);
    final minH = math.min(_minSelectionSide, parentSize.height);
    final left = r.left.clamp(0.0, parentSize.width - minW);
    final top = r.top.clamp(0.0, parentSize.height - minH);
    final right = r.right.clamp(left + minW, parentSize.width);
    final bottom = r.bottom.clamp(top + minH, parentSize.height);
    return Rect.fromLTRB(left, top, right, bottom);
  }
}

enum _DragHandle { move, topLeft, topRight, bottomLeft, bottomRight }

class _CropOverlayPainter extends CustomPainter {
  final Rect? selection;
  final double handleSize;
  final Color primary;

  _CropOverlayPainter({
    required this.selection,
    required this.handleSize,
    required this.primary,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (selection == null) return;

    final sel = selection!;

    // Dim area outside selection.
    final dimPaint = Paint()..color = const Color(0x88000000);
    // Top
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, sel.top), dimPaint);
    // Bottom
    canvas.drawRect(
        Rect.fromLTRB(0, sel.bottom, size.width, size.height), dimPaint);
    // Left
    canvas.drawRect(Rect.fromLTRB(0, sel.top, sel.left, sel.bottom), dimPaint);
    // Right
    canvas.drawRect(
        Rect.fromLTRB(sel.right, sel.top, size.width, sel.bottom), dimPaint);

    // Selection border.
    final borderPaint = Paint()
      ..color = primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawRect(sel, borderPaint);

    // Dashed rule-of-thirds grid lines.
    final gridPaint = Paint()
      ..color = primary.withValues(alpha: 0.33)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    final thirdW = sel.width / 3;
    final thirdH = sel.height / 3;
    for (int i = 1; i < 3; i++) {
      canvas.drawLine(
        Offset(sel.left + thirdW * i, sel.top),
        Offset(sel.left + thirdW * i, sel.bottom),
        gridPaint,
      );
      canvas.drawLine(
        Offset(sel.left, sel.top + thirdH * i),
        Offset(sel.right, sel.top + thirdH * i),
        gridPaint,
      );
    }

    // Corner handles.
    final handlePaint = Paint()..color = primary;
    final corners = [
      sel.topLeft,
      sel.topRight,
      sel.bottomLeft,
      sel.bottomRight
    ];
    for (final corner in corners) {
      canvas.drawCircle(corner, handleSize / 2, handlePaint);
      // White inner dot for contrast.
      canvas.drawCircle(
        corner,
        handleSize / 4,
        Paint()..color = const Color(0xFFFFFFFF),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CropOverlayPainter oldDelegate) {
    return oldDelegate.selection != selection || oldDelegate.primary != primary;
  }
}
