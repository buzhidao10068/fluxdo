import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/config/sites/nodeloc.dart';
import 'package:fluxdo/constants.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/widgets/common/badge_title_text.dart';

Post _post({String? group, String? title, String username = 'member'}) =>
    Post.fromJson({
      'id': 1,
      'username': username,
      'post_number': 1,
      'primary_group_name': group,
      'user_title': title,
      'cooked': '<p>测试</p>',
    });

void main() {
  test('当前站点使用 NodeLoc 配置且不注册旧站专属插件', () {
    expect(AppConstants.siteCustomization, same(nodelocCustomization));
    expect(nodelocCustomization.plugins, isEmpty);
    expect(
      nodelocCustomization.linkSecurityConfig!.enableExitConfirmation,
      true,
    );
  });

  test('Rich 群组使用公开主题中的金色光晕，旧站规则不生效', () {
    expect(
      nodelocCustomization.matchAvatarGlow(_post(group: 'Rich')),
      const Color(0xFFF5BF03),
    );
    for (final post in [
      _post(),
      _post(group: 'rich'),
      _post(group: 'g-merchant'),
      _post(username: 'neo'),
    ]) {
      expect(nodelocCustomization.matchAvatarGlow(post), isNull);
    }
  });

  for (final (title, color, effect) in [
    ('王者会员', const Color(0xFFF7E58D), BadgeTitleEffect.goldFlow),
    ('钻石会员', const Color(0xFF888672), BadgeTitleEffect.shimmer),
    ('MANAGER', const Color(0xFFE4C862), BadgeTitleEffect.holographicFlow),
  ]) {
    testWidgets('$title 使用已确认的基色和特效，保留文字和字号', (tester) async {
      final builder = nodelocCustomization.matchTitleStyle(_post(title: title));
      expect(builder, isNotNull);
      final widget = builder!(title, 13) as BadgeTitleText;
      expect(widget.color, color);
      expect(widget.effect, effect);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: widget)));
      final text = tester.widget<Text>(find.text(title));
      expect(text.style!.fontSize, 13);
      expect(text.style!.color, color);
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(find.byType(ShaderMask), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  test('未确认的头衔和旧站专属头衔使用默认样式', () {
    for (final title in [
      null,
      '',
      '无所不知',
      '3 YEARS',
      '2 YEARS',
      '种子用户',
      'Premium',
    ]) {
      expect(
        nodelocCustomization.matchTitleStyle(_post(title: title)),
        isNull,
        reason: title,
      );
    }
  });

  testWidgets('减少动态效果时停止头衔动画，恢复设置后继续动画', (tester) async {
    Widget app(bool disabled) => MediaQuery(
      data: MediaQueryData(disableAnimations: disabled),
      child: const Directionality(
        textDirection: TextDirection.ltr,
        child: BadgeTitleText(
          text: '钻石会员',
          fontSize: 12,
          color: Color(0xFF888672),
          effect: BadgeTitleEffect.shimmer,
        ),
      ),
    );
    await tester.pumpWidget(app(true));
    expect(tester.binding.hasScheduledFrame, false);
    await tester.pumpWidget(app(false));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, true);
    await tester.pumpWidget(app(true));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, false);
    expect(find.text('钻石会员'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
