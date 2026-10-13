/// Leitura do QR de entrada na atividade.
///
/// O leitor é o `mobile_scanner`, com o modelo de código de barras do ML Kit
/// embarcado no aplicativo: funciona sem rede e sem permissão de internet. A
/// câmera é liberada ao sair desta tela, antes de a calibração abrir a dela.
library;

import 'package:eyelearn_core/eyelearn_core.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'theme.dart';

/// Abre o leitor e devolve a atividade lida, ou `null` se o adulto voltar.
Future<ActivityTicket?> scanActivity(BuildContext context, Roster roster) =>
    Navigator.of(context).push<ActivityTicket>(
      MaterialPageRoute(builder: (context) => ScanScreen(roster: roster)),
    );

class ScanScreen extends StatefulWidget {
  final Roster roster;

  const ScanScreen({super.key, required this.roster});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  String? _message;
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final text = barcode.rawValue;
      if (text == null) continue;
      try {
        final ticket =
            ActivityTicket.verify(text, widget.roster, DateTime.now().toUtc());
        _done = true;
        Navigator.of(context).pop(ticket);
        return;
      } on TicketException catch (error) {
        setState(() => _message = error.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: const Text('QR da atividade'),
        ),
        body: Stack(
          children: [
            MobileScanner(controller: _controller, onDetect: _onDetect),
            Center(
              child: Container(
                width: 250,
                height: 250,
                decoration: BoxDecoration(
                  border: Border.all(color: Palette.amber, width: 4),
                  borderRadius: BorderRadius.circular(Shapes.cardRadius),
                ),
              ),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 32,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(Shapes.chipRadius + 4),
                ),
                child: Text(
                  _message ?? 'Aponte para o QR na tela do professor.',
                  textAlign: TextAlign.center,
                  style: AppType.body.copyWith(
                    color: _message == null ? Colors.white : Palette.amber,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}
