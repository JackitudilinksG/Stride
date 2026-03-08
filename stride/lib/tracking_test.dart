import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'location_mechanics/location_service.dart';

class TrackingTestPage extends ConsumerWidget {
  const TrackingTestPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch the session state — widget rebuilds whenever state changes
    final session = ref.watch(runSessionProvider);
    final notifier = ref.read(runSessionProvider.notifier);

    return Scaffold(
      backgroundColor: const Color(0xFF0D1A0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1A0F),
        title: const Text(
          'Tracking POC',
          style: TextStyle(color: Color(0xFFA8E063)),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [

            // ── Status indicator ──────────────────────────────
            _StatusBadge(isRunning: session.isRunning),
            const SizedBox(height: 32),

            // ── Live stats grid ───────────────────────────────
            Row(
              children: [
                _StatCard(
                  label: 'Distance',
                  value: '${(session.distanceMeters).toStringAsFixed(1)} m',
                ),
                const SizedBox(width: 12),
                _StatCard(
                  label: 'Breadcrumbs',
                  value: '${session.breadcrumbs.length}',
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _StatCard(
                  label: 'Elapsed',
                  value: _formatDuration(session.timeElapsed),
                ),
                const SizedBox(width: 12),
                _StatCard(
                  label: 'Pace',
                  value: session.currentPace > 0
                      ? '${session.currentPace.toStringAsFixed(1)} s/km'
                      : '--',
                ),
              ],
            ),
            const SizedBox(height: 32),

            // ── Last known position ───────────────────────────
            if (session.breadcrumbs.isNotEmpty) ...[
              _LastPositionCard(session: session),
              const SizedBox(height: 32),
            ],

            // ── Toggle button ─────────────────────────────────
            const Spacer(),
            _ToggleButton(
              isRunning: session.isRunning,
              onPressed: () async {
                if (session.isRunning) {
                  notifier.stopRun();
                } else {
                  // Check permissions before starting
                  final locationService = ref.read(locationServiceProvider);
                  final hasPermission = await locationService.handlePermissions();

                  if (hasPermission) {
                    notifier.startRun();
                  } else {
                    // Show a snackbar if permissions were denied
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Location permission denied.'),
                          backgroundColor: Colors.redAccent,
                        ),
                      );
                    }
                  }
                }
              },
            ),
            const SizedBox(height: 16),

            // ── Reset button (only visible when stopped + has data) ──
            if (!session.isRunning && session.breadcrumbs.isNotEmpty)
              TextButton(
                onPressed: () => notifier.reset(),
                child: const Text(
                  'Reset',
                  style: TextStyle(color: Color(0xFF4D7A52)),
                ),
              ),

          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

// ─────────────────────────────────────────────────────────
// SUB-WIDGETS
// ─────────────────────────────────────────────────────────

class _ToggleButton extends StatelessWidget {
  final bool isRunning;
  final VoidCallback onPressed;

  const _ToggleButton({required this.isRunning, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        height: 64,
        decoration: BoxDecoration(
          color: isRunning ? const Color(0xFF3A1010) : const Color(0xFF1A3320),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isRunning
                ? const Color(0xFFFF6464)
                : const Color(0xFFA8E063),
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded,
              color: isRunning
                  ? const Color(0xFFFF6464)
                  : const Color(0xFFA8E063),
              size: 26,
            ),
            const SizedBox(width: 10),
            Text(
              isRunning ? 'Stop Tracking' : 'Start Tracking',
              style: TextStyle(
                color: isRunning
                    ? const Color(0xFFFF6464)
                    : const Color(0xFFA8E063),
                fontSize: 16,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final bool isRunning;
  const _StatusBadge({required this.isRunning});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isRunning ? const Color(0xFFA8E063) : const Color(0xFF4D7A52),
            boxShadow: isRunning
                ? [BoxShadow(color: const Color(0xFFA8E063).withOpacity(0.5), blurRadius: 8)]
                : [],
          ),
        ),
        const SizedBox(width: 10),
        Text(
          isRunning ? 'Tracking active' : 'Not tracking',
          style: TextStyle(
            color: isRunning ? const Color(0xFFA8E063) : const Color(0xFF4D7A52),
            fontSize: 13,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  const _StatCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF111F13),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF1E3D22)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label.toUpperCase(),
              style: const TextStyle(
                color: Color(0xFF3A6140),
                fontSize: 9,
                letterSpacing: 0.15,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: const TextStyle(
                color: Color(0xFFD4E8D4),
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LastPositionCard extends StatelessWidget {
  final RunSessionState session;
  const _LastPositionCard({required this.session});

  @override
  Widget build(BuildContext context) {
    final last = session.breadcrumbs.last;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF111F13),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1E3D22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'LAST POSITION',
            style: TextStyle(
              color: Color(0xFF3A6140),
              fontSize: 9,
              letterSpacing: 0.15,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _CoordChip(label: 'LAT', value: last.latitude.toStringAsFixed(6)),
              const SizedBox(width: 8),
              _CoordChip(label: 'LNG', value: last.longitude.toStringAsFixed(6)),
              const SizedBox(width: 8),
              _CoordChip(label: 'ACC', value: '±${last.accuracy.toStringAsFixed(1)}m'),
            ],
          ),
        ],
      ),
    );
  }
}

class _CoordChip extends StatelessWidget {
  final String label;
  final String value;
  const _CoordChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 8, color: Color(0xFF3A6140), letterSpacing: 0.1)),
          const SizedBox(height: 3),
          Text(value,
              style: const TextStyle(
                  fontSize: 11, color: Color(0xFFA8E063), fontFamily: 'monospace')),
        ],
      ),
    );
  }
}