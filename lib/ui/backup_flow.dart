import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../services/backup.dart';
import '../services/vault.dart' show VaultException;
import '../state/app_state.dart';
import 'widgets.dart';

/// Asks for a password; with [confirm] the user types it twice.
Future<String?> _askPassword(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
  bool confirm = false,
}) => showDialog<String>(
  context: context,
  builder: (_) => _PasswordDialog(
    title: title,
    body: body,
    action: action,
    confirm: confirm,
  ),
);

/// Runs [work] behind a modal spinner and always closes it.
Future<T> _withProgress<T>(
  BuildContext context,
  String label,
  Future<T> Function() work,
) async {
  final nav = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(width: 20),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    ),
  );
  try {
    return await work();
  } finally {
    nav.pop();
  }
}

/// Encrypts all data with a password and lets the user save the file
/// anywhere (Drive, Downloads, another app).
Future<void> backupFlow(BuildContext context) async {
  final app = context.read<AppState>();
  final password = await _askPassword(
    context,
    title: 'Back up to a file',
    body:
        'Choose a password for the backup. You need it to restore, and it '
        'cannot be recovered if you forget it.',
    action: 'Continue',
    confirm: true,
  );
  if (password == null || !context.mounted) return;
  try {
    final bytes = await _withProgress(
      context,
      'Encrypting backup...',
      () => app.exportBackup(password),
    );
    final name =
        'cardwise-backup-${DateFormat('yyyy-MM-dd').format(DateTime.now())}'
        '.cwbackup';
    final saved = await FilePicker.saveFile(fileName: name, bytes: bytes);
    if (saved != null && context.mounted) {
      showMessage(context, 'Backup saved.');
    }
  } on VaultException catch (e) {
    if (context.mounted) showMessage(context, e.message, error: true);
  } catch (_) {
    if (context.mounted) {
      showMessage(context, 'Could not save the backup.', error: true);
    }
  }
}

/// Replaces all data with the contents of a backup file.
Future<void> restoreFlow(BuildContext context) async {
  final app = context.read<AppState>();
  final ok = await confirm(
    context,
    title: 'Restore from a backup?',
    body:
        'Everything currently in Cardwise on this device is replaced by the '
        'backup.',
    action: 'Choose file',
  );
  if (!ok || !context.mounted) return;
  try {
    final files = await FilePicker.pickFiles(dialogTitle: 'Choose a backup');
    if (files.isEmpty || !context.mounted) return;
    final size = await files.first.length();
    if (size != null && size > Backup.maxFileBytes) {
      throw VaultException('This file is too large to be a Cardwise backup.');
    }
    final bytes = await files.first.readAsBytes();
    if (!context.mounted) return;
    final password = await _askPassword(
      context,
      title: 'Backup password',
      body: 'Enter the password you chose when making the backup.',
      action: 'Restore',
    );
    if (password == null || !context.mounted) return;
    await _withProgress(
      context,
      'Restoring...',
      () => app.restoreBackup(bytes, password),
    );
    if (context.mounted) {
      final d = app.data;
      showMessage(
        context,
        'Restored ${d.cards.length} card${d.cards.length == 1 ? '' : 's'} and '
        '${d.transactions.length} transaction'
        '${d.transactions.length == 1 ? '' : 's'}.',
      );
    }
  } on VaultException catch (e) {
    if (context.mounted) showMessage(context, e.message, error: true);
  } catch (_) {
    if (context.mounted) {
      showMessage(context, 'Could not read the backup file.', error: true);
    }
  }
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({
    required this.title,
    required this.body,
    required this.action,
    required this.confirm,
  });
  final String title;
  final String body;
  final String action;
  final bool confirm;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _pw = TextEditingController();
  final _again = TextEditingController();
  bool _hidden = true;
  String? _error;

  @override
  void dispose() {
    _pw.dispose();
    _again.dispose();
    super.dispose();
  }

  void _submit() {
    final error = widget.confirm
        ? Backup.validatePassword(_pw.text) ??
              (_pw.text != _again.text ? 'Passwords do not match.' : null)
        : (_pw.text.isEmpty ? 'Enter the password.' : null);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, _pw.text);
  }

  @override
  Widget build(BuildContext context) {
    final toggle = IconButton(
      tooltip: _hidden ? 'Show password' : 'Hide password',
      icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off),
      onPressed: () => setState(() => _hidden = !_hidden),
    );
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.body),
            const SizedBox(height: 16),
            TextField(
              controller: _pw,
              autofocus: true,
              obscureText: _hidden,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Password',
                border: const OutlineInputBorder(),
                suffixIcon: toggle,
              ),
              onSubmitted: (_) => widget.confirm ? null : _submit(),
            ),
            if (widget.confirm) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _again,
                obscureText: _hidden,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Repeat password',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _submit(),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.action)),
      ],
    );
  }
}
