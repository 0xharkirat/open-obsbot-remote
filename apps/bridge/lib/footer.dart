import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class AppFooter extends StatelessWidget {
  const AppFooter({super.key});

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      // ignore: avoid_print
      print('failed to open $url');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.outline;
    final style = TextStyle(fontSize: 11, color: color);
    final linkStyle = style.copyWith(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Center(
        child: Text.rich(
          TextSpan(children: <InlineSpan>[
            const TextSpan(text: 'Made by '),
            TextSpan(
              text: 'Hark Singh',
              style: linkStyle,
              recognizer: TapGestureRecognizer()
                ..onTap = () => _open('https://harksingh.com'),
            ),
            const TextSpan(text: '  •  Powered by '),
            TextSpan(
              text: 'OBSBOT SDK',
              style: linkStyle,
              recognizer: TapGestureRecognizer()
                ..onTap = () => _open('https://www.obsbot.com/'),
            ),
            const TextSpan(text: ' + '),
            TextSpan(
              text: 'Flutter',
              style: linkStyle,
              recognizer: TapGestureRecognizer()
                ..onTap = () => _open('https://flutter.dev/'),
            ),
          ]),
          textAlign: TextAlign.center,
          style: style,
        ),
      ),
    );
  }
}
