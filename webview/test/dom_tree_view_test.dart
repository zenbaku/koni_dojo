// DomTreePanel is pure Flutter/package:html, no WebView — unlike the rest
// of the picker, this piece is actually widget-testable.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:koni_dojo_webview/dom_tree_view.dart';

void main() {
  const html = '''
    <html><body>
      <div class="listing">
        <article class="card" id="card-1">
          <h2 class="title">Alpha</h2>
        </article>
        <article class="card" id="card-2">
          <h2 class="title">Beta</h2>
        </article>
        <div class="footer">
          <span class="deep-1">
            <span class="deep-2">
              <span class="deep-3">buried</span>
            </span>
          </span>
        </div>
      </div>
    </body></html>
  ''';

  dom.Document parsed() => html_parser.parse(html);

  testWidgets('renders the shallow-expanded tree, tapping a row reports '
      'its element', (tester) async {
    final doc = parsed();
    dom.Element? tapped;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DomTreePanel(root: doc.body!, onTap: (el) => tapped = el),
        ),
      ),
    );

    // Shallow default expansion (depth < 2) shows body -> div.listing ->
    // article.card, but not the title h2 inside each article (that's a
    // 3rd-level child, past the default depth).
    expect(find.textContaining('<body'), findsOneWidget);
    expect(find.textContaining('<div.listing'), findsOneWidget);
    expect(find.textContaining('<article#card-1.card'), findsOneWidget);
    expect(find.textContaining('<h2.title'), findsNothing);

    await tester.tap(find.textContaining('<article#card-1.card'));
    expect(tapped, isNotNull);
    expect(tapped!.attributes['id'], 'card-1');
  });

  testWidgets('tapping the expand chevron reveals children without '
      'reporting a pick', (tester) async {
    final doc = parsed();
    dom.Element? tapped;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DomTreePanel(root: doc.body!, onTap: (el) => tapped = el),
        ),
      ),
    );

    expect(find.textContaining('<h2.title'), findsNothing);

    // The chevron is the expand icon inside the first article's row.
    final articleRow = find.ancestor(
      of: find.textContaining('<article#card-1.card'),
      matching: find.byType(Row),
    );
    await tester.tap(
      find.descendant(
        of: articleRow,
        matching: find.byIcon(Icons.keyboard_arrow_right),
      ),
    );
    await tester.pump();

    expect(find.textContaining('<h2.title'), findsOneWidget);
    expect(tapped, isNull); // expanding must not also count as a pick
  });

  testWidgets('tapping an already-expanded node\'s chevron collapses it '
      'again', (tester) async {
    final doc = parsed();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DomTreePanel(root: doc.body!, onTap: (_) {}),
        ),
      ),
    );

    // div.listing starts expanded by default (depth 1 < 2).
    expect(find.textContaining('<article#card-1.card'), findsOneWidget);

    final listingRow = find.ancestor(
      of: find.textContaining('<div.listing'),
      matching: find.byType(Row),
    );
    await tester.tap(
      find.descendant(
        of: listingRow,
        matching: find.byIcon(Icons.keyboard_arrow_down),
      ),
    );
    await tester.pump();

    expect(find.textContaining('<article#card-1.card'), findsNothing);
  });

  testWidgets('a leaf element with no children shows no chevron at all', (
    tester,
  ) async {
    // A dedicated minimal fixture: root -> one child -> one grandchild leaf
    // with only a text node, all within the default shallow-expand depth,
    // so this doesn't need manual expand taps to reach.
    final doc = html_parser.parse(
      '<html><body><div class="mid"><span class="leaf">text</span></div></body></html>',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DomTreePanel(root: doc.body!, onTap: (_) {}),
        ),
      ),
    );

    expect(find.textContaining('<span.leaf'), findsOneWidget);
    final leafRow = find.ancestor(
      of: find.textContaining('<span.leaf'),
      matching: find.byType(Row),
    );
    expect(
      find.descendant(of: leafRow, matching: find.byType(InkResponse)),
      findsNothing,
    );
  });

  testWidgets(
    'a selected element outside the default shallow-expand depth still '
    'auto-expands its ancestors and becomes visible — regression for a '
    'live-page click landing deep in the tree tinting a row that was '
    'never actually rendered',
    (tester) async {
      final doc = parsed();
      final deep = doc.querySelector('.deep-3')!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DomTreePanel(root: doc.body!, onTap: (_) {}, selected: deep),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('<span.deep-3'), findsOneWidget);
    },
  );

  testWidgets(
    'updating selected to a previously-collapsed element expands it into '
    'view too, not just an element already selected on first build',
    (tester) async {
      final doc = parsed();
      final deep = doc.querySelector('.deep-3')!;
      dom.Element? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  TextButton(
                    onPressed: () => setState(() => selected = deep),
                    child: const Text('select'),
                  ),
                  Expanded(
                    child: DomTreePanel(
                      root: doc.body!,
                      onTap: (_) {},
                      selected: selected,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.textContaining('<span.deep-3'), findsNothing);
      await tester.tap(find.text('select'));
      await tester.pumpAndSettle();
      expect(find.textContaining('<span.deep-3'), findsOneWidget);
    },
  );
}
