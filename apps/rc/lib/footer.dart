import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// "Made by Hark Singh • Powered by OBSBOT SDK + Flutter" footer.
///
/// Uses real button widgets (not TextSpan recognizers) — TextSpan
/// recognizers ignore taps inside Flutter web's <flt-platform-view>
/// fallback path on small touch targets, and tap targets <44px fail
/// iOS Safari heuristics.
class AppFooter extends StatelessWidget {
  final EdgeInsets padding;
  const AppFooter({
    super.key,
    this.padding = const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
  });

  Future<void> _open(BuildContext ctx, String url) async {
    final uri = Uri.parse(url);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('Could not open $url')),
        );
      }
    } catch (e) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outline = theme.colorScheme.outline;
    final small = TextStyle(fontSize: 12, color: outline);

    Widget link(String label, String url) {
      return TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          tapTargetSize: MaterialTapTargetSize.padded,
          foregroundColor: theme.colorScheme.primary,
          textStyle: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.underline,
          ),
        ),
        onPressed: () => _open(context, url),
        child: Text(label),
      );
    }

    return Padding(
      padding: padding,
      child: Center(
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text('Made by', style: small),
            ),
            link('Hark Singh', 'https://harksingh.com'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text('•  Powered by', style: small),
            ),
            link('OBSBOT SDK', 'https://www.obsbot.com/sdk'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text('+', style: small),
            ),
            link('Flutter', 'https://flutter.dev/'),
            if (kIsWeb)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text('•  Web', style: small),
              ),
          ],
        ),
      ),
    );
  }
}
