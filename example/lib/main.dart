// ignore_for_file: avoid_print

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:frame_ble/frame_ble.dart';

void main() {
  FlutterBluePlus.setLogLevel(LogLevel.verbose, color: true);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        // This is the theme of your application.
        //
        // TRY THIS: Try running your application with "flutter run". You'll see
        // the application has a purple toolbar. Then, without quitting the app,
        // try changing the seedColor in the colorScheme below to Colors.green
        // and then invoke "hot reload" (save your changes or press the "hot
        // reload" button in a Flutter-supported IDE, or press "r" if you used
        // the command line to start the app).
        //
        // Notice that the counter didn't reset back to zero; the application
        // state is not lost during the reload. To reset the state, use hot
        // restart instead.
        //
        // This works for code too, not just values: Most code changes can be
        // tested with just a hot reload.
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;
  BluetoothDevice? _device;
  FrameBle? _frame;
  bool _isRunning = false; // Flag to prevent multiple button presses

  _MyHomePageState();

  void _incrementCounter() async {
    setState(() {
      _counter++;
      _isRunning = true;
    });

    // connect to Frame and display the counter, then disconnect
    await _showCounterOnFrame();

    setState(() {
      // This call to setState tells the Flutter framework that something has
      // changed in this State, which causes it to rerun the build method below
      // so that the display can reflect the updated values. If we changed
      // _counter without calling setState(), then the build method would not be
      // called again, and so nothing would appear to happen.
      _isRunning = false; // Reset the flag after operation
    });
  }

  Future<void> _showCounterOnFrame() async {
    // connect to Frame the first time or if it has become disconnected
    if (_device == null || await _device?.connectionState.first != BluetoothConnectionState.connected) {

      // scan and connect to Frame
      _device = await scanAndConnectToFirstDevice(FrameBle.serviceUuid);

      if (_device == null) {
        print('Frame not found or connection failed');
        _frame = null;
        return;
      }

      print('Connected to Frame: ${_device!.platformName} [${_device!.remoteId}]');

      // discover services and characteristics, get a FrameBle handle to the device
      _frame = await FrameBle.fromDevice(_device!);

      // send a break signal to stop any running Lua main loop
      await _frame?.sendBreakSignal();
    }

    // send the counter to Frame for display
    await _frame?.sendString(
      'frame.display.text("Hello, World! ($_counter)", 1, 1) frame.display.show()',
      awaitResponse: false,
    );
  }

  /// Scans for the first BLE device advertising the [serviceUuid], connects to it,
  /// and returns the connected device.
  ///
  /// Note: Production code should subscribe to the `adapterState` and `connectionState`
  /// streams to handle Bluetooth state changes and connection events. This function is
  /// simplified to present a linear sequence of operations but bluetooth state management
  /// is more complex in real applications.
  /// See the Flutter Blue Plus example](https://github.com/chipweinberger/flutter_blue_plus/tree/master/packages/flutter_blue_plus/example)
  /// and [the corresponding `frame_ble` example](https://github.com/CitizenOneX/flutter_blue_plus_frame_ble/tree/frame_ble/packages/flutter_blue_plus/example)
  /// for an example of more robust BLE state management.
  ///
  /// Returns `null` if Bluetooth is not available, the scan times out,
  /// no device is found, or the connection fails.
  ///
  /// - [serviceUuid]: The specific service UUID to scan for.
  /// - [scanTimeout]: How long to scan before giving up.
  Future<BluetoothDevice?> scanAndConnectToFirstDevice(
      Guid serviceUuid,
      {Duration scanTimeout = const Duration(seconds: 15)}
    ) async {

    // --- 1. Check Bluetooth Support and State ---
    if (await FlutterBluePlus.isSupported == false) {
      print("scanAndConnectToFirstDevice: Bluetooth not supported by this device");
      return null;
    }

    // Wait until Bluetooth is enabled
    // Note: `adapterState.firstWhere` waits for the FIRST emission matching the condition.
    // If BT is already on, it completes immediately. If it's off, it waits.
    try {
      await FlutterBluePlus.adapterState
          .where((state) => state == BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 10)); // Timeout for waiting BT on
      print("scanAndConnectToFirstDevice: Bluetooth adapter is on.");
    } catch (e) {
      print("scanAndConnectToFirstDevice: Bluetooth adapter did not turn on: $e");
      return null;
    }

    // --- 2 & 3. Scan for the first device with the specified service UUID ---
    BluetoothDevice? targetDevice;
    StreamSubscription<List<ScanResult>>? scanSubscription; // Keep track of subscription

    // Use a Completer to bridge the async gap between finding a device and returning
    Completer<BluetoothDevice?> completer = Completer();

    // Setup listener *before* starting scan
    scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        // Check if we found any devices matching the service UUID filter
        if (results.isNotEmpty) {
            ScanResult firstResult = results.first; // Take the first one found
            print("scanAndConnectToFirstDevice: Found device: ${firstResult.device.platformName} [${firstResult.device.remoteId}]");
            targetDevice = firstResult.device;

            // Complete the completer *before* stopping scan and cancelling subscription
            // to ensure the function can proceed to connect
            if (!completer.isCompleted) {
              completer.complete(targetDevice);
            }
            // Cleanup scan resources immediately after finding the first device
            FlutterBluePlus.stopScan();
            scanSubscription?.cancel();
        }
    });

    try {
      print("scanAndConnectToFirstDevice: Starting scan for service $serviceUuid...");
      // Start scanning with the service UUID filter and timeout
      // IMPORTANT: The scan will automatically stop after `scanTimeout` if `stopScan` isn't called sooner.
      await FlutterBluePlus.startScan(
          withServices: [serviceUuid],
          timeout: scanTimeout,
      );

      // Wait for the listener (scanSubscription) to find a device OR for the scan to timeout.
      // We add a small buffer to the timeout here to ensure the scan's internal timeout
      // has a chance to trigger if no device is found, which would cause scanResults
      // to potentially stop emitting, thus allowing the timeout here to fire.
      targetDevice = await completer.future.timeout(scanTimeout + const Duration(seconds: 1));

      if (targetDevice == null) {
        // This case might occur if the scan timed out exactly as the completer was handled,
        // or if somehow the listener completed with null (though unlikely with the current logic).
        print("scanAndConnectToFirstDevice: Scan completed, but no device object was obtained.");
        await FlutterBluePlus.stopScan(); // Ensure stopped
        await scanSubscription.cancel(); // Ensure cancelled
        return null;
      }

      // --- 5. Connect to the device ---
      print("scanAndConnectToFirstDevice: Attempting to connect to ${targetDevice!.platformName} [${targetDevice!.remoteId}]...");
      await targetDevice!.connect(timeout: const Duration(seconds: 15), autoConnect: false); // Add connection timeout
      print("scanAndConnectToFirstDevice: Successfully connected to ${targetDevice!.platformName}");

      // --- 6. Return the connected device ---
      return targetDevice;

    } catch (e) {
      // Handle potential errors:
      // - TimeoutException from completer.future.timeout (scan timed out without finding device)
      // - PlatformException during scanning or connecting
      // - Any other exception during the process
      print("scanAndConnectToFirstDevice: Error occurred: $e");
      if (e is TimeoutException) {
          print("scanAndConnectToFirstDevice: Scan timed out without finding a device advertising service $serviceUuid.");
      }
      // Ensure cleanup happens on error
      await FlutterBluePlus.stopScan();
      await scanSubscription.cancel();
      // If connection failed after finding device, try disconnecting cleanly
      if (targetDevice != null) {
          try {
            await targetDevice!.disconnect();
            print("scanAndConnectToFirstDevice: Disconnected device after connection failure.");
          } catch (disconnectErr) {
            print("scanAndConnectToFirstDevice: Error disconnecting device after connection failure: $disconnectErr");
          }
      }
      return null; // Return null on failure
    }
    // No finally block needed as cleanup is handled within try/catch and listener
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return Scaffold(
      appBar: AppBar(
        // TRY THIS: Try changing the color here to a specific color (to
        // Colors.amber, perhaps?) and trigger a hot reload to see the AppBar
        // change color while the other colors stay the same.
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text(widget.title),
      ),
      body: Center(
        // Center is a layout widget. It takes a single child and positions it
        // in the middle of the parent.
        child: Column(
          // Column is also a layout widget. It takes a list of children and
          // arranges them vertically. By default, it sizes itself to fit its
          // children horizontally, and tries to be as tall as its parent.
          //
          // Column has various properties to control how it sizes itself and
          // how it positions its children. Here we use mainAxisAlignment to
          // center the children vertically; the main axis here is the vertical
          // axis because Columns are vertical (the cross axis would be
          // horizontal).
          //
          // TRY THIS: Invoke "debug painting" (choose the "Toggle Debug Paint"
          // action in the IDE, or press "p" in the console), to see the
          // wireframe for each widget.
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text(
              'You have pushed the button this many times:',
            ),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _isRunning ? null : _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ), // This trailing comma makes auto-formatting nicer for build methods.
    );
  }
}
