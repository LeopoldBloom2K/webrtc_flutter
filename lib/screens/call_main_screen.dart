import 'package:flutter/material.dart';

import '../call_screen.dart';
import '../models/contact.dart';
import '../widgets/profile_circle.dart';
import '../widgets/status_circle.dart';

class CallMainScreen extends StatefulWidget {
  const CallMainScreen({super.key});

  @override
  State<CallMainScreen> createState() => _CallMainScreenState();
}

class _CallMainScreenState extends State<CallMainScreen> {
  final TextEditingController _nameController = TextEditingController();
  String _serverUrl = 'ws://10.0.2.2:8080';

  final List<Contact> _contacts = [
    Contact(name: '김다온'),
    Contact(name: '이준행'),
    Contact(name: '이혜섭'),
  ];

  void _addContact() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _contacts.add(Contact(name: name));
      _nameController.clear();
    });
  }

  void _deleteContact(int index) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('연락처 삭제'),
        content: Text('${_contacts[index].name}을(를) 삭제할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () {
              setState(() => _contacts.removeAt(index));
              Navigator.pop(ctx);
            },
            child: const Text('삭제'),
          ),
        ],
      ),
    );
  }

  void _showServerSettings() {
    final controller = TextEditingController(text: _serverUrl);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('서버 설정'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: '시그널링 서버 URL',
            hintText: 'ws://10.0.2.2:8080',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () {
              setState(() => _serverUrl = controller.text.trim());
              Navigator.pop(ctx);
            },
            child: const Text('저장'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          '딥보이스 보안 통화',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(0xFF111111),
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Color(0xFF111111)),
            onPressed: _showServerSettings,
            tooltip: '서버 설정',
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 24),
              Expanded(
                child: ListView.separated(
                  itemCount: _contacts.length,
                  separatorBuilder: (context, i) => const SizedBox(height: 24),
                  itemBuilder: (context, index) {
                    final contact = _contacts[index];
                    return _ContactTile(
                      name: contact.name,
                      isOn: contact.isOn,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => CallScreen(
                              name: contact.name,
                              initialServerUrl: _serverUrl,
                            ),
                          ),
                        );
                      },
                      onLongPress: () => _deleteContact(index),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 16, bottom: 24),
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 44,
                        padding:
                            const EdgeInsets.symmetric(horizontal: 18),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: const [
                            BoxShadow(
                              color: Color.fromRGBO(0, 0, 0, 0.06),
                              blurRadius: 10,
                              offset: Offset(0, 3),
                            ),
                          ],
                        ),
                        child: TextField(
                          controller: _nameController,
                          onSubmitted: (_) => _addContact(),
                          decoration: const InputDecoration(
                            hintText: '이름 입력',
                            hintStyle: TextStyle(
                              color: Color(0xFF8E8E93),
                              fontSize: 15,
                            ),
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: _addContact,
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Color.fromRGBO(0, 0, 0, 0.06),
                              blurRadius: 10,
                              offset: Offset(0, 3),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.add,
                          size: 26,
                          color: Color(0xFF111111),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContactTile extends StatelessWidget {
  final String name;
  final bool isOn;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ContactTile({
    required this.name,
    required this.isOn,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Row(
        children: [
          const ProfileCircle(),
          const SizedBox(width: 18),
          Text(
            name,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w400,
              color: Color(0xFF111111),
            ),
          ),
          const Spacer(),
          StatusCircle(isOn: isOn),
        ],
      ),
    );
  }
}
