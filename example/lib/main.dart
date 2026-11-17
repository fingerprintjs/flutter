import 'dart:convert';

import 'package:env_flutter/env_flutter.dart';
import 'package:flutter/foundation.dart';
// Deprecated since Flutter 3.47. The replacement, package:material_ui, needs
// Flutter >= 3.47, above our minimum. https://pub.dev/packages/material_ui
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:fingerprint_flutter/fingerprint_flutter.dart';
import 'package:geolocator/geolocator.dart';

// Covers every JSON value type, so E2E runs the null and double handling in
// the native tag conversion.
const tags = {
  'a': 'a',
  'b': 0,
  'c': {
    'foo': true,
    'bar': [1, 2.5, null],
    'baz': null,
  },
  'd': false,
  'e': null,
  'f': 0.5,
};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    // Flutter web needs its accessibility DOM for external UI automation.
    // https://docs.maestro.dev/get-started/supported-platform/flutter
    SemanticsBinding.instance.ensureSemantics();
  }
  // Explicitly define which files to load to avoid
  // console warnings about not finding other possible .env files
  await dotenv.load(fileNames: ['.env', '.env.local']);
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _visitorId = 'Unknown';
  String _checksResult = 'Not run';
  // Null when creation failed. Then _initializationError is set.
  Fingerprint? _client;
  String? _initializationError;
  final bool _disableLocationCollection =
      dotenv.env['DISABLE_LOCATION_COLLECTION']?.toLowerCase() == 'true';

  @override
  void initState() {
    super.initState();
    _createFingerprintClient();
  }

  List<String>? _parseEndpoints(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    // Fingerprint drops empty entries.
    return [for (final url in raw.split(',')) url.trim()];
  }

  void _createFingerprintClient() {
    try {
      final apiKey = dotenv.env['API_KEY'];
      if (apiKey == null || apiKey.isEmpty) {
        throw Exception('Set the API_KEY environment variable');
      }
      _client = Fingerprint(
        apiKey: apiKey,
        region: Region.values.asNameMap()[dotenv.env['REGION']],
        endpoints: _parseEndpoints(dotenv.env['ENDPOINTS']),
        android: AndroidOptions(
          allowUseOfLocationData: !_disableLocationCollection,
          locationTimeout: const Duration(milliseconds: 6000),
        ),
        ios: IosOptions(allowUseOfLocationData: !_disableLocationCollection),
      );
    } catch (error) {
      _initializationError = 'Failed to create Fingerprint client: $error';
    }
  }

  Future<void> requestLocationPermission() async {
    if (kIsWeb || _disableLocationCollection) {
      return;
    }
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (kDebugMode) {
          print('Location permissions are denied');
        }
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      if (kDebugMode) {
        print(
          'Location permissions are permanently denied, we cannot request permissions.',
        );
      }
      return;
    }
  }

  Future<FingerprintResult> _identify() async {
    await requestLocationPermission();
    return _client!.get(tags: tags, linkedId: 'some linkedId');
  }

  Future<void> _showVisitorId() async {
    String visitorId;
    try {
      visitorId = (await _identify()).visitorId ?? 'Unknown';
    } catch (error) {
      visitorId = 'Failed to get device id: $error';
    }

    if (!mounted) return;
    setState(() {
      _visitorId = visitorId;
    });
  }

  Future<String> _visitorDataText() async {
    try {
      final result = await _identify();
      var sealedResult = result.sealedResult;
      if (sealedResult != null && sealedResult.length > 10) {
        sealedResult = sealedResult.replaceRange(
          10,
          sealedResult.length,
          '...',
        );
      }
      return const JsonEncoder.withIndent('    ').convert({
        'eventId': result.eventId,
        'visitorId': result.visitorId,
        'suspectScore': result.suspectScore,
        'sealedResult': sealedResult,
        'cacheHit': result.cacheHit,
      });
    } on FingerprintError catch (error) {
      return 'Failed to get device info.\n$error';
    }
  }

  Future<void> _runChecks() async {
    await requestLocationPermission();
    setState(() {
      _checksResult = 'Running';
    });
    try {
      final client = _client!;
      var checks = [
        () => client.get(),
        () => client.get(linkedId: 'checkId'),
        () => client.get(tags: tags),
        () => client.get(linkedId: 'checkIdWithTag', tags: tags),
        () => client.get(timeout: const Duration(milliseconds: 5000)),
      ];

      for (var check in checks) {
        await check();
        if (!mounted) return;
        setState(() {
          _checksResult += '.';
        });
      }
      // A server error must reach Dart as FingerprintError with its code.
      final invalidKeyClient = Fingerprint(
        apiKey: 'invalid-api-key',
        region: client.region,
        endpoints: client.endpoints,
        android: client.android,
        ios: client.ios,
      );
      try {
        await invalidKeyClient.get();
        throw Exception('Expected an error for an invalid API key');
      } on FingerprintError catch (error) {
        if (error.code != FingerprintError.publicApiKeyNotFound) rethrow;
      }
      if (!mounted) return;
      setState(() {
        _checksResult = 'Success!';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checksResult = 'Failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCreated = _client != null;

    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Fingerprint Flutter')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_initializationError ?? 'Fingerprint client created'),
              ElevatedButton(
                onPressed: isCreated ? _runChecks : null,
                child: const Text('Run tests!'),
              ),
              const Text('Checks result:'),
              Text(_checksResult),
              ElevatedButton(
                onPressed: isCreated ? _showVisitorId : null,
                child: const Text('Identify!'),
              ),
              const Text('The device id is:'),
              Text(_visitorId),
              _VisitorDataDialog(
                enabled: isCreated,
                loadVisitorData: _visitorDataText,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VisitorDataDialog extends StatelessWidget {
  const _VisitorDataDialog({
    required this.enabled,
    required this.loadVisitorData,
  });

  final bool enabled;
  final Future<String> Function() loadVisitorData;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: enabled
          ? () async {
              final resultContext = context;
              String identificationInfo;
              try {
                identificationInfo = await loadVisitorData();
              } catch (e) {
                identificationInfo = 'Identification error: $e';
              }
              if (resultContext.mounted) {
                showDialog<String>(
                  context: resultContext,
                  builder: (BuildContext context) => AlertDialog(
                    title: const Text('Visitor data'),
                    content: FittedBox(
                      fit: BoxFit.contain,
                      child: Text(identificationInfo),
                    ),
                    actions: <Widget>[
                      ElevatedButton(
                        onPressed: () => Navigator.pop(context, 'OK'),
                        child: const Text('OK'),
                      ),
                    ],
                  ),
                );
              }
            }
          : null,
      child: const Text('Get visitor data!'),
    );
  }
}
