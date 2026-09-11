/*
 *     Copyright (C) 2026 Valeri Gokadze
 *
 *     SoundWave is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     SoundWave is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 *
 *     For more information about SoundWave, including how to contribute,
 *     please visit: https://github.com/tejasshinde4545k/SoundWave
 */

import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:soundwave/services/router_service.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage>
    with TickerProviderStateMixin {
  late final AnimationController _mainController;
  late final AnimationController _pulseController;
  late final Animation<double> _fadeAnimation;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _pulseAnimation;
  Timer? _navigationTimer;
  bool _hasNavigated = false;

  @override
  void initState() {
    super.initState();

    _mainController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _mainController,
        curve: const Interval(0, 0.7, curve: Curves.easeOut),
      ),
    );

    _scaleAnimation = Tween<double>(begin: 0.82, end: 1).animate(
      CurvedAnimation(
        parent: _mainController,
        curve: const Interval(0, 0.8, curve: Curves.easeOutBack),
      ),
    );

    _pulseAnimation = Tween<double>(begin: 0.96, end: 1.04).animate(
      CurvedAnimation(
        parent: _pulseController,
        curve: Curves.easeInOut,
      ),
    );

    _mainController.forward();

    // Navigate to dashboard after smooth delay
    _navigationTimer =
        Timer(const Duration(milliseconds: 1800), _goToDashboard);
  }

  @override
  void dispose() {
    _navigationTimer?.cancel();
    _mainController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  void _goToDashboard() {
    if (_hasNavigated || !mounted) return;
    _hasNavigated = true;
    context.go(NavigationManager.homePath);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;

    final bgColor = isDark ? const Color(0xFF0D0E15) : const Color(0xFFF9FAFD);

    return PopScope(
      canPop: false,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _goToDashboard,
        child: Scaffold(
          backgroundColor: bgColor,
          body: Stack(
            children: [
              // Subtle background ambient gradient glow
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0, -0.1),
                      radius: 0.9,
                      colors: [
                        primary.withValues(alpha: isDark ? 0.18 : 0.12),
                        primary.withValues(alpha: isDark ? 0.05 : 0.03),
                        bgColor,
                      ],
                      stops: const [0, 0.55, 1],
                    ),
                  ),
                ),
              ),

              // Main content
              Center(
                child: FadeTransition(
                  opacity: _fadeAnimation,
                  child: ScaleTransition(
                    scale: _scaleAnimation,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // SoundWave Icon with pulsing ambient aura
                        AnimatedBuilder(
                          animation: _pulseAnimation,
                          builder: (context, child) {
                            return Transform.scale(
                              scale: _pulseAnimation.value,
                              child: child,
                            );
                          },
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: primary.withValues(
                                    alpha: isDark ? 0.35 : 0.22,
                                  ),
                                  blurRadius: 40,
                                  spreadRadius: 6,
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(28),
                              child: Image.asset(
                                'assets/icons/soundwave.png',
                                width: 130,
                                height: 130,
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 28),

                        // App Name
                        Text(
                          'SoundWave',
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 8),

                        // Subtitle
                        Text(
                          'Feel the rhythm',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 2,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.65,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // Bottom animated sound wave bars
              Positioned(
                left: 0,
                right: 0,
                bottom: 48,
                child: Center(
                  child: FadeTransition(
                    opacity: _fadeAnimation,
                    child: _AnimatedWaveBars(color: primary),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A subtle 5-bar animated musical soundwave indicator.
class _AnimatedWaveBars extends StatefulWidget {
  const _AnimatedWaveBars({required this.color});

  final Color color;

  @override
  State<_AnimatedWaveBars> createState() => _AnimatedWaveBarsState();
}

class _AnimatedWaveBarsState extends State<_AnimatedWaveBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _waveController;

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat();
  }

  @override
  void dispose() {
    _waveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const heights = [14.0, 22.0, 30.0, 22.0, 14.0];
    const delays = [0.0, 0.2, 0.4, 0.6, 0.8];

    return AnimatedBuilder(
      animation: _waveController,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(5, (index) {
            final t = (_waveController.value + delays[index]) % 1.0;
            final scale = 0.35 + 0.65 * (0.5 - (t - 0.5).abs()) * 2;
            final currentHeight = heights[index] * scale;

            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 2.5),
              width: 3.5,
              height: currentHeight,
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(4),
              ),
            );
          }),
        );
      },
    );
  }
}
