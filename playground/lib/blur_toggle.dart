// The NSFW screen-safety toggle: a compact AppBar action on every screen
// that can render a source's images. See Workspace.blurNsfw.
import 'package:flutter/material.dart';

import 'workspace.dart';

class BlurToggleAction extends StatelessWidget {
  const BlurToggleAction({super.key, required this.workspace});

  final Workspace workspace;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: workspace,
      builder: (context, _) {
        final on = workspace.blurNsfw;
        return IconButton(
          tooltip: on
              ? 'Images are blurred — press and hold one to peek. '
                    'Tap to turn off.'
              : 'Blur cover/page images (NSFW screen-safety)',
          icon: Icon(on ? Icons.visibility_off : Icons.visibility),
          isSelected: on,
          onPressed: () => workspace.setBlurNsfw(!on),
        );
      },
    );
  }
}
