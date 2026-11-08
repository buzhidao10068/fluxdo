import 'package:flutter/material.dart';

/// 徽章文字特效；基色来自站点配置，渐变在客户端近似呈现。
enum BadgeTitleEffect { goldFlow, shimmer, holographicFlow }

class BadgeTitleText extends StatefulWidget {
  final String text;
  final double fontSize;
  final Color color;
  final BadgeTitleEffect effect;

  const BadgeTitleText({
    super.key,
    required this.text,
    required this.fontSize,
    required this.color,
    required this.effect,
  });

  @override
  State<BadgeTitleText> createState() => _BadgeTitleTextState();
}

class _BadgeTitleTextState extends State<BadgeTitleText>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      _controller.value = 0.5;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<Color> get _colors => switch (widget.effect) {
    BadgeTitleEffect.goldFlow => [
      widget.color,
      const Color(0xFFB8860B),
      widget.color,
      const Color(0xFFFFF8DC),
      widget.color,
    ],
    BadgeTitleEffect.shimmer => [
      widget.color,
      widget.color,
      Color.lerp(widget.color, Colors.white, 0.8)!,
      widget.color,
      widget.color,
    ],
    BadgeTitleEffect.holographicFlow => [
      widget.color,
      const Color(0xFF80CBC4),
      const Color(0xFFCE93D8),
      const Color(0xFF90CAF9),
      widget.color,
    ],
  };

  @override
  Widget build(BuildContext context) {
    final colors = _colors;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final progress = _controller.value;
          // 全息效果按站点 CSS 的关键帧往返，其余效果持续横向流动。
          final offset = widget.effect == BadgeTitleEffect.holographicFlow
              ? (progress < 0.7
                    ? 1.2 - progress * 4
                    : -1.6 + (progress - 0.7) * (2.8 / 0.3))
              : 2 - progress * 4;
          return ShaderMask(
            shaderCallback: (bounds) => LinearGradient(
              colors: colors,
              begin: Alignment(offset - 1, 0),
              end: Alignment(offset + 1, 0),
              tileMode: TileMode.mirror,
            ).createShader(bounds),
            blendMode: BlendMode.srcIn,
            child: child,
          );
        },
        child: Text(
          widget.text,
          style: TextStyle(
            color: widget.color,
            fontSize: widget.fontSize,
            fontWeight: FontWeight.w600,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
      ),
    );
  }
}
