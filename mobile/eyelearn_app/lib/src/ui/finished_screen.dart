/// Tela final do aplicativo do aluno.
///
/// Para a criança: terminou. Nada mais. A saída pedagógica vai para o
/// professor, e um rótulo vindo de um modelo cujo valor preditivo positivo na
/// prevalência escolar é de cerca de 22% não é coisa que se mostre a uma
/// criança de nove anos.
library;

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';

/// Tela final.
///
/// Para a criança: terminou. Nada mais.
///
/// Para o adulto, abaixo de uma linha divisória: a qualidade da captura e o
/// botão de compartilhar. A qualidade aparece porque uma captura ruim precisa
/// ser refeita na hora, não descoberta pelo professor depois.
class FinishedScreen extends StatelessWidget {
  final Session session;

  /// Ação de enviar ao professor.
  ///
  /// Chega por parâmetro, e não por importação, porque gravar e compartilhar
  /// arquivo depende de `dart:io` e das folhas de compartilhamento do sistema,
  /// que não existem no navegador. Nula esconde o botão -- é o que a
  /// pré-visualização de `main_demo.dart` faz.
  final Future<void> Function()? onShare;

  const FinishedScreen({super.key, required this.session, this.onShare});

  @override
  Widget build(BuildContext context) {
    final usable = session.hasUsableQuality();

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(),
              const Text('🎉', style: TextStyle(fontSize: 72)),
              const SizedBox(height: 16),
              const Text(
                'Terminei!',
                style: TextStyle(fontSize: 34, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Obrigado por ler com a gente.',
                style: TextStyle(fontSize: 18),
              ),
              const Spacer(),
              const Divider(),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Para o adulto',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _QualityRow(
                label: 'Amostras aproveitáveis',
                value: '${(session.validSampleRatio * 100).round()}%',
              ),
              _QualityRow(
                label: 'Taxa de amostragem',
                value: '${session.samplingRateHz.toStringAsFixed(1)} Hz',
              ),
              _QualityRow(
                label: 'Duração',
                value: '${session.durationSeconds.toStringAsFixed(1)} s',
              ),
              if (!usable) ...[
                const SizedBox(height: 12),
                const Text(
                  'A captura ficou abaixo do mínimo utilizável. Vale repetir a '
                  'atividade antes de enviar.',
                  style: TextStyle(color: Color(0xFF8D2B0B), fontSize: 14),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context)
                          .popUntil((route) => route.isFirst),
                      child: const Text('Nova atividade'),
                    ),
                  ),
                  if (onShare != null) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: onShare,
                        child: const Text('Enviar ao professor'),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QualityRow extends StatelessWidget {
  final String label;
  final String value;

  const _QualityRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 14)),
            Text(
              value,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
}
