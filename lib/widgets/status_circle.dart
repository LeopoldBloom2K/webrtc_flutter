import 'package:flutter/material.dart';

class StatusCircle extends StatelessWidget {
  final bool isOn;

  const StatusCircle({
    super.key,
    required this.isOn,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: isOn ? const Color(0xFF34C759) : Colors.white,
        shape: BoxShape.circle,
        boxShadow: const [
          BoxShadow(
            color: Color.fromRGBO(0, 0, 0, 0.08),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
    );
  }
}
