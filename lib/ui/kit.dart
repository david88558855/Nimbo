import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../core/format.dart';
import '../core/models.dart';

class NimboButton extends StatelessWidget {
  const NimboButton(
    this.label, {
    super.key,
    this.onPressed,
    this.icon,
    this.kind = NimboButtonKind.secondary,
    this.height = 30,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final NimboButtonKind kind;
  final double height;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    late final Color bg;
    late final Color fg;
    Border? border;
    switch (kind) {
      case NimboButtonKind.primary:
        bg = NimboColors.sky600;
        fg = Colors.white;
      case NimboButtonKind.secondary:
        bg = Colors.white;
        fg = NimboColors.ink;
        border = Border.all(color: NimboColors.line);
      case NimboButtonKind.ghost:
        bg = Colors.transparent;
        fg = NimboColors.ink2;
      case NimboButtonKind.danger:
        bg = const Color(0xFFFFF1F3);
        fg = NimboColors.dangerInk;
        border = Border.all(color: const Color(0xFFF8C9D2));
    }
    final content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 5),
        ],
        Text(label,
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: fg)),
      ],
    );
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: Container(
            height: height,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration:
                kind == NimboButtonKind.primary
                    ? BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        gradient: NimboColors.gradient,
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x400EA5E9),
                            blurRadius: 12,
                            offset: Offset(0, 4),
                          )
                        ],
                      )
                    : BoxDecoration(borderRadius: BorderRadius.circular(8), border: border),
            child: content,
          ),
        ),
      ),
    );
  }
}

enum NimboButtonKind { primary, secondary, ghost, danger }

class ProtocolBadge extends StatelessWidget {
  const ProtocolBadge(this.protocol, {super.key, this.compact = false});

  final MountProtocol protocol;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final text = protocol == MountProtocol.local ? 'LOCAL' : protocol.label;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: protocol.bg,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 8.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.3,
          fontFamily: 'monospace',
          color: protocol.color,
        ),
      ),
    );
  }
}

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, this.color = NimboColors.ok, this.size = 5});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: const Color(0x40A6D8C8), blurRadius: 3, spreadRadius: 2)],
        ),
      );
}

class EntryTile extends StatelessWidget {
  const EntryTile({super.key, required this.entry, this.size = 28});
  final RemoteEntry entry;
  final double size;

  @override
  Widget build(BuildContext context) {
    final v = visualFor(entry);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: v.background, borderRadius: BorderRadius.circular(size * 0.32)),
      child: Icon(v.icon, size: size * 0.52, color: v.color),
    );
  }
}

class EmptyBlock extends StatelessWidget {
  const EmptyBlock({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: danger ? const Color(0x14F43F5E) : const Color(0x1438BDF8),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 22, color: danger ? NimboColors.danger : NimboColors.sky600),
            ),
            const SizedBox(height: 12),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: NimboColors.ink)),
            if (subtitle != null) ...[
              const SizedBox(height: 5),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Text(subtitle!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11.5, height: 1.55, color: NimboColors.ink3)),
              ),
            ],
            if (actionLabel != null) ...[
              const SizedBox(height: 14),
              NimboButton(actionLabel!,
                  onPressed: onAction, kind: NimboButtonKind.primary, icon: Icons.add_rounded),
            ],
          ],
        ),
      ),
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.child, this.padding = const EdgeInsets.all(16)});
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: padding,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(NimboRadius.panel),
          border: Border.all(color: NimboColors.line),
        ),
        child: child,
      );
}

class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Text(text,
            style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: NimboColors.ink3)),
      );
}

InputDecoration nimboInput({String? hint, Widget? suffix}) => InputDecoration(
      isDense: true,
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 12, color: NimboColors.ink4),
      suffixIcon: suffix,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      filled: true,
      fillColor: const Color(0xFFFCFDFF),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(NimboRadius.field),
        borderSide: const BorderSide(color: Color(0xFFDFE9F3)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(NimboRadius.field),
        borderSide: const BorderSide(color: Color(0xFFDFE9F3)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(NimboRadius.field),
        borderSide: const BorderSide(color: NimboColors.sky600, width: 1.4),
      ),
    );
