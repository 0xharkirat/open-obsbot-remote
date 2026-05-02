import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class AppFooter extends StatelessWidget {
  const AppFooter({super.key});

  Future<void> _open(BuildContext ctx, String url) async {
    final uri = Uri.parse(url);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && ctx.mounted) {
        final messenger = ScaffoldMessenger.of(ctx);
        messenger.showSnackBar(SnackBar(content: Text('Could not open $url')));
      }
    } catch (e) {
      if (ctx.mounted) {
        final messenger = ScaffoldMessenger.of(ctx);
        messenger.showSnackBar(SnackBar(content: Text('$e')));
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
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Center(
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Open OBSBOT Bridge',
                style: small.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
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
          ],
        ),
      ),
    );
  }
}
